import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
import UniformTypeIdentifiers

enum CropStrategy: String {
    case auto      // several photos -> split; one document -> perspective crop; else trim
    case document  // Vision document detection only, single output
    case photos    // always split into per-photo images
    case trim      // white-border trim only
    case none
}

/// When the photo itself was taken (for scanned prints), as opposed to when
/// it was scanned. Missing month/day default to January 1st.
struct ContentDate {
    let year: Int
    let month: Int
    let day: Int

    /// Accepts "1995", "1995-07", "1995-07-14" (also with "/" or ":").
    init?(_ text: String) {
        let parts = text.split(whereSeparator: { "-/:".contains($0) }).compactMap { Int($0) }
        guard (1...3).contains(parts.count) else { return nil }
        year = parts[0]
        month = parts.count > 1 ? parts[1] : 1
        day = parts.count > 2 ? parts[2] : 1
        guard (1000...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
    }

    var exifString: String {
        String(format: "%04d:%02d:%02d 00:00:00", year, month, day)
    }
    var iptcString: String {
        String(format: "%04d%02d%02d", year, month, day)
    }
}

struct ImageMetadata {
    var title: String?
    var description: String?
    var author: String?
    var keywords: [String] = []
    var contentDate: ContentDate?
    var scannerModel: String?
    var dpi: Int = 300
    var jpegQuality: Double = 0.92
}

struct CroppedImage {
    let image: CGImage
    let method: String  // "document", "photo", "trim" or "none"
}

enum PipelineError: Error, CustomStringConvertible {
    case decodeFailed
    case encodeFailed(String)

    var description: String {
        switch self {
        case .decodeFailed: return "could not decode scanned JPEG"
        case .encodeFailed(let path): return "could not write \(path)"
        }
    }
}

private let ciContext = CIContext()

/// Applies the crop strategy to one scanned page. May return several images
/// (e.g. multiple photos laid out on the flatbed).
func extractImages(from jpeg: Data, crop: CropStrategy) throws -> [CroppedImage] {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw PipelineError.decodeFailed
    }

    switch crop {
    case .none:
        return [CroppedImage(image: image, method: "none")]

    case .document:
        if let doc = detectAndCropDocument(image) {
            return [CroppedImage(image: doc, method: "document")]
        }
        return [CroppedImage(image: image, method: "none")]

    case .photos:
        let regions = detectContentRegions(image)
        if !regions.isEmpty {
            return regions.compactMap { rect in
                image.cropping(to: tightenRect(image, rect))
                    .map { CroppedImage(image: $0, method: "photo") }
            }
        }
        return [CroppedImage(image: image, method: "none")]

    case .trim:
        if let trimmed = trimWhiteBorders(image) {
            return [CroppedImage(image: trimmed, method: "trim")]
        }
        return [CroppedImage(image: image, method: "none")]

    case .auto:
        let regions = detectContentRegions(image).map { tightenRect(image, $0) }
        if regions.count >= 2 {
            return regions.compactMap { rect in
                image.cropping(to: rect).map { CroppedImage(image: $0, method: "photo") }
            }
        }
        if let doc = detectAndCropDocument(image) {
            return [CroppedImage(image: doc, method: "document")]
        }
        if let trimmed = trimWhiteBorders(image) {
            return [CroppedImage(image: trimmed, method: "trim")]
        }
        return [CroppedImage(image: image, method: "none")]
    }
}

// MARK: - Document detection (Vision)

private func detectAndCropDocument(_ image: CGImage) -> CGImage? {
    let request = VNDetectDocumentSegmentationRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil,
          let observation = request.results?.first,
          observation.confidence > 0.5 else { return nil }

    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    let box = observation.boundingBox
    // Ignore implausible detections: near-nothing or the whole bed.
    guard box.width * box.height > 0.02, box.width * box.height < 0.98 else { return nil }

    func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }

    let input = CIImage(cgImage: image)
    let corrected = input.applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": CIVector(cgPoint: scaled(observation.topLeft)),
        "inputTopRight": CIVector(cgPoint: scaled(observation.topRight)),
        "inputBottomLeft": CIVector(cgPoint: scaled(observation.bottomLeft)),
        "inputBottomRight": CIVector(cgPoint: scaled(observation.bottomRight)),
    ])
    return ciContext.createCGImage(corrected, from: corrected.extent)
}

// MARK: - Content region detection (multiple photos on the bed)

private struct Mask {
    var bits: [Bool]
    let width: Int
    let height: Int
}

/// Downscaled thresholded view of the page: true where the pixel is not
/// scanner-bed white.
private func contentMask(_ image: CGImage, maxDim: Int) -> (Mask, Double)? {
    let scale = min(1.0, Double(maxDim) / Double(max(image.width, image.height)))
    let sw = max(1, Int(Double(image.width) * scale))
    let sh = max(1, Int(Double(image.height) * scale))

    guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                              bytesPerRow: sw, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

    var bits = [Bool](repeating: false, count: sw * sh)
    for i in 0..<(sw * sh) where pixels[i] < 235 { bits[i] = true }
    return (Mask(bits: bits, width: sw, height: sh), scale)
}

/// Bridges small gaps (photo borders, faint edges) so each photo labels as
/// one connected component.
private func dilate(_ mask: Mask, radius: Int) -> Mask {
    var out = mask
    let w = mask.width, h = mask.height
    for y in 0..<h {
        for x in 0..<w where mask.bits[y * w + x] {
            for dy in -radius...radius {
                let ny = y + dy
                guard ny >= 0, ny < h else { continue }
                for dx in -radius...radius {
                    let nx = x + dx
                    guard nx >= 0, nx < w else { continue }
                    out.bits[ny * w + nx] = true
                }
            }
        }
    }
    return out
}

/// Finds bounding boxes (in full-resolution pixels) of distinct content
/// regions large enough to be photos/documents.
private func detectContentRegions(_ image: CGImage) -> [CGRect] {
    guard let (rawMask, scale) = contentMask(image, maxDim: 600) else { return [] }
    let mask = dilate(rawMask, radius: 2)
    let w = mask.width, h = mask.height

    var labels = [Int](repeating: 0, count: w * h)
    var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int, area: Int)] = []
    var next = 1
    var stack: [Int] = []

    for start in 0..<(w * h) where mask.bits[start] && labels[start] == 0 {
        var minX = Int.max, maxX = Int.min
        var minY = Int.max, maxY = Int.min
        var area = 0
        stack.append(start)
        labels[start] = next
        while let idx = stack.popLast() {
            let x = idx % w, y = idx / w
            // The flood fill walks the dilated mask so one photo stays one
            // component, but the bounding box tracks only real content
            // pixels — otherwise every crop carries a halo of bed white.
            if rawMask.bits[idx] {
                area += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let nidx = ny * w + nx
                if mask.bits[nidx] && labels[nidx] == 0 {
                    labels[nidx] = next
                    stack.append(nidx)
                }
            }
        }
        if area > 0 {
            boxes.append((minX, minY, maxX, maxY, area))
        }
        next += 1
    }

    // A real photo/document fills a meaningful part of the bed and is
    // reasonably solid (area vs. bounding box), unlike streaks or dust.
    let pageArea = Double(w * h)
    let inv = 1.0 / scale
    let margin = 2.0 // full-resolution pixels; keep crops tight

    // Nothing narrower than ~4% of the page in either direction is a photo
    // or document — that filters out glass-edge shadows and fold lines.
    let minSide = max(w, h) * 4 / 100

    var rects: [CGRect] = []
    for b in boxes {
        let bw = b.maxX - b.minX + 1
        let bh = b.maxY - b.minY + 1
        let boxArea = Double(bw * bh)
        guard bw >= minSide, bh >= minSide else { continue }
        guard boxArea > pageArea * 0.005 else { continue }
        guard Double(b.area) > boxArea * 0.5 else { continue }
        var rect = CGRect(x: Double(b.minX) * inv - margin,
                          y: Double(b.minY) * inv - margin,
                          width: Double(bw) * inv + margin * 2,
                          height: Double(bh) * inv + margin * 2)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        rects.append(rect)
    }

    // Top-to-bottom, left-to-right output order.
    return rects.sorted {
        abs($0.minY - $1.minY) > 20 ? $0.minY < $1.minY : $0.minX < $1.minX
    }
}

// MARK: - Edge tightening

/// Shrinks a crop rect until no near-white edge rows/columns remain (photo
/// prints have their own white paper border), then bites a few extra pixels
/// in. Losing a sliver of photo is preferred over keeping any white.
private func tightenRect(_ image: CGImage, _ rect: CGRect) -> CGRect {
    guard rect.width > 40, rect.height > 40,
          let region = image.cropping(to: rect) else { return rect }

    let maxDim = 1200
    let scale = min(1.0, Double(maxDim) / Double(max(region.width, region.height)))
    let sw = max(1, Int(Double(region.width) * scale))
    let sh = max(1, Int(Double(region.height) * scale))
    guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                              bytesPerRow: sw, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return rect }
    ctx.interpolationQuality = .low
    ctx.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return rect }

    // Buffer row 0 is the top of the region, matching cropping(to:) coords.
    func rowDarkFraction(_ y: Int) -> Double {
        var dark = 0
        for x in 0..<sw where pixels[y * sw + x] < 230 { dark += 1 }
        return Double(dark) / Double(sw)
    }
    func colDarkFraction(_ x: Int) -> Double {
        var dark = 0
        for y in 0..<sh where pixels[y * sw + x] < 230 { dark += 1 }
        return Double(dark) / Double(sh)
    }

    let need = 0.03           // a row/column with <3% dark pixels is "white"
    let maxShrinkY = sh * 15 / 100
    let maxShrinkX = sw * 15 / 100

    var top = 0
    while top < maxShrinkY && rowDarkFraction(top) < need { top += 1 }
    var bottom = 0
    while bottom < maxShrinkY && rowDarkFraction(sh - 1 - bottom) < need { bottom += 1 }
    var left = 0
    while left < maxShrinkX && colDarkFraction(left) < need { left += 1 }
    var right = 0
    while right < maxShrinkX && colDarkFraction(sw - 1 - right) < need { right += 1 }

    let inv = 1.0 / scale
    // The extra bite past the last white row, so edge shadows and border
    // remnants go with it.
    let bite = max(4.0, Double(min(region.width, region.height)) * 0.006)

    var tightened = CGRect(
        x: rect.minX + Double(left) * inv + bite,
        y: rect.minY + Double(top) * inv + bite,
        width: rect.width - Double(left + right) * inv - bite * 2,
        height: rect.height - Double(top + bottom) * inv - bite * 2)
    tightened = tightened.intersection(rect)
    return (tightened.width > 40 && tightened.height > 40) ? tightened : rect
}

// MARK: - White-border trim fallback

/// Crops to the bounding box of all non-white content (plus a small margin).
private func trimWhiteBorders(_ image: CGImage) -> CGImage? {
    guard let (mask, scale) = contentMask(image, maxDim: 800) else { return nil }
    let w = mask.width, h = mask.height
    // A row/column counts as content when >0.5% of its pixels are dark,
    // which keeps single specks of dust from defeating the trim.
    let rowMinDark = max(2, w / 200)
    let colMinDark = max(2, h / 200)

    var top = -1, bottom = -1, left = -1, right = -1
    for y in 0..<h {
        var dark = 0
        for x in 0..<w where mask.bits[y * w + x] { dark += 1 }
        if dark >= rowMinDark {
            if top < 0 { top = y }
            bottom = y
        }
    }
    guard top >= 0 else { return nil }
    for x in 0..<w {
        var dark = 0
        for y in 0..<h where mask.bits[y * w + x] { dark += 1 }
        if dark >= colMinDark {
            if left < 0 { left = x }
            right = x
        }
    }
    guard left >= 0 else { return nil }

    let inv = 1.0 / scale
    let margin = Double(12)
    var rect = CGRect(x: Double(left) * inv - margin,
                      y: Double(top) * inv - margin,
                      width: Double(right - left + 1) * inv + margin * 2,
                      height: Double(bottom - top + 1) * inv + margin * 2)
    rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    // Not worth cropping for less than a 2% reduction.
    let full = Double(image.width * image.height)
    guard rect.width * rect.height < full * 0.98 else { return nil }
    return image.cropping(to: rect)
}

// MARK: - Orientation

enum RotateOption {
    case auto
    case none
    case fixed(CGImagePropertyOrientation)
}

/// Finds the rotation that puts the photo upright by running face detection
/// in all four orientations and keeping the one where faces stand straight
/// (confidence weighted by the face roll angle). Returns nil when no face
/// gives a clear answer (e.g. landscapes).
func detectUprightOrientation(_ image: CGImage) -> CGImagePropertyOrientation? {
    var best: (orientation: CGImagePropertyOrientation, score: Double)?
    for orientation in [CGImagePropertyOrientation.up, .right, .down, .left] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil else { continue }
        var score = 0.0
        for face in request.results ?? [] {
            let roll = face.roll?.doubleValue ?? 0
            score += Double(face.confidence) * max(0, cos(roll))
        }
        if score > (best?.score ?? 0) {
            best = (orientation, score)
        }
    }
    guard let best, best.score >= 0.5 else { return nil }
    return best.orientation
}

func rotated(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
    guard orientation != .up else { return image }
    let oriented = CIImage(cgImage: image).oriented(orientation)
    return ciContext.createCGImage(oriented, from: oriented.extent) ?? image
}

func degrees(_ orientation: CGImagePropertyOrientation) -> Int {
    switch orientation {
    case .right: return 90
    case .down: return 180
    case .left: return 270
    default: return 0
    }
}

// MARK: - Grayscale

/// The scanner only streams JPEG in color mode; gray output is produced here.
func convertToGrayscale(_ image: CGImage) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()
}

// MARK: - Metadata + encode

func writeJPEG(image: CGImage, metadata m: ImageMetadata, to url: URL) throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let now = formatter.string(from: Date())

    // DateTimeOriginal is when the photo was taken (what Photos and friends
    // sort by); DateTimeDigitized stays the scan time.
    var exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: m.contentDate?.exifString ?? now,
        kCGImagePropertyExifDateTimeDigitized: now,
    ]
    if let d = m.description { exif[kCGImagePropertyExifUserComment] = d }

    var tiff: [CFString: Any] = [
        kCGImagePropertyTIFFDateTime: now,
        kCGImagePropertyTIFFSoftware: "retroscan",
        kCGImagePropertyTIFFXResolution: m.dpi,
        kCGImagePropertyTIFFYResolution: m.dpi,
        kCGImagePropertyTIFFResolutionUnit: 2, // inches
    ]
    if let model = m.scannerModel {
        tiff[kCGImagePropertyTIFFMake] = "Brother"
        tiff[kCGImagePropertyTIFFModel] = model
    }
    if let a = m.author { tiff[kCGImagePropertyTIFFArtist] = a }
    if let d = m.description { tiff[kCGImagePropertyTIFFImageDescription] = d }

    var iptc: [CFString: Any] = [:]
    if let date = m.contentDate { iptc[kCGImagePropertyIPTCDateCreated] = date.iptcString }
    if let t = m.title { iptc[kCGImagePropertyIPTCObjectName] = t }
    if let d = m.description { iptc[kCGImagePropertyIPTCCaptionAbstract] = d }
    if let a = m.author { iptc[kCGImagePropertyIPTCByline] = a }
    if !m.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = m.keywords }

    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
        kCGImagePropertyIPTCDictionary: iptc,
        kCGImagePropertyDPIWidth: m.dpi,
        kCGImagePropertyDPIHeight: m.dpi,
        kCGImageDestinationLossyCompressionQuality: m.jpegQuality,
    ]

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw PipelineError.encodeFailed(url.path)
    }
    CGImageDestinationAddImage(dest, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        throw PipelineError.encodeFailed(url.path)
    }
}
