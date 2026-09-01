import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Vision
import UniformTypeIdentifiers

public enum CropStrategy: String, CaseIterable {
    case auto      // several photos -> split; one document -> perspective crop; else trim
    case document  // Vision document detection only, single output
    case photos    // always split into per-photo images
    case trim      // white-border trim only
    case none
}

/// When the photo itself was taken (for scanned prints), as opposed to when
/// it was scanned. Missing month/day default to January 1st.
public struct ContentDate {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Accepts "1995", "1995-07", "1995-07-14" (also with "/" or ":").
    public init?(_ text: String) {
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

public struct ImageMetadata {
    public var title: String?
    public var description: String?
    public var author: String?
    public var keywords: [String] = []
    public var contentDate: ContentDate?
    public var scannerModel: String?
    public var dpi: Int = 300
    public var jpegQuality: Double = 0.92

    public init(title: String? = nil, description: String? = nil, author: String? = nil,
                keywords: [String] = [], contentDate: ContentDate? = nil,
                scannerModel: String? = nil, dpi: Int = 300, jpegQuality: Double = 0.92) {
        self.title = title
        self.description = description
        self.author = author
        self.keywords = keywords
        self.contentDate = contentDate
        self.scannerModel = scannerModel
        self.dpi = dpi
        self.jpegQuality = jpegQuality
    }
}

public struct CroppedImage {
    public let image: CGImage
    public let method: String  // "document", "photo", "trim" or "none"
    /// Axis-aligned rectangle this crop occupies on the scanned page (pixel
    /// coordinates), when the crop is a plain rect — lets a UI re-crop from
    /// the source page. Nil for perspective-corrected outputs.
    public let sourceRect: CGRect?
}

public enum PipelineError: Error, CustomStringConvertible {
    case decodeFailed
    case encodeFailed(String)

    public var description: String {
        switch self {
        case .decodeFailed: return "could not decode scanned JPEG"
        case .encodeFailed(let path): return "could not write \(path)"
        }
    }
}

private let ciContext = CIContext()

/// Applies the crop strategy to one scanned page. May return several images
/// (e.g. multiple photos laid out on the flatbed).
public func extractImages(from jpeg: Data, crop: CropStrategy, sam: SAMDetector?) throws -> [CroppedImage] {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw PipelineError.decodeFailed
    }

    let pageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)

    switch crop {
    case .none:
        return [CroppedImage(image: image, method: "none", sourceRect: pageRect)]

    case .document:
        if let doc = detectAndCropDocument(image) {
            return [CroppedImage(image: doc, method: "document", sourceRect: nil)]
        }
        return [CroppedImage(image: image, method: "none", sourceRect: pageRect)]

    case .photos:
        let (regions, background) = detectContentRegions(image)
        if !regions.isEmpty {
            let sam = encodedSAM(sam, image)
            return regions.compactMap { cropRegion(image, $0, background: background, sam: sam) }
        }
        return [CroppedImage(image: image, method: "none", sourceRect: pageRect)]

    case .trim:
        if let (trimmed, rect) = trimWhiteBorders(image) {
            return [CroppedImage(image: trimmed, method: "trim", sourceRect: rect)]
        }
        return [CroppedImage(image: image, method: "none", sourceRect: pageRect)]

    case .auto:
        let (regions, background) = detectContentRegions(image)
        if regions.count >= 2 {
            let sam = encodedSAM(sam, image)
            return regions.compactMap { cropRegion(image, $0, background: background, sam: sam) }
        }
        // A lone region that isn't the whole page is a single photo: give it
        // the same treatment as one photo among several. (A region covering
        // ~everything is an already-cropped image; leave it to the document
        // and trim fallbacks.)
        if let region = regions.first,
           Double(region.width * region.height) < Double(image.width * image.height) * 0.9,
           let cropped = cropRegion(image, region, background: background,
                                    sam: encodedSAM(sam, image)) {
            return [cropped]
        }
        if let doc = detectAndCropDocument(image) {
            return [CroppedImage(image: doc, method: "document", sourceRect: nil)]
        }
        if let (trimmed, rect) = trimWhiteBorders(image) {
            return [CroppedImage(image: trimmed, method: "trim", sourceRect: rect)]
        }
        return [CroppedImage(image: image, method: "none", sourceRect: pageRect)]
    }
}

/// Runs the SAM image encoder for this page, once; nil when SAM is off or
/// the encoding fails (the classical pipeline takes over).
private func encodedSAM(_ sam: SAMDetector?, _ image: CGImage) -> SAMDetector? {
    guard let sam else { return nil }
    do {
        try sam.encode(page: image)
        return sam
    } catch {
        FileHandle.standardError.write(Data("warning: SAM encoding failed (\(error)), falling back\n".utf8))
        return nil
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

/// Estimates the scan background level. White bed with the lid closed reads
/// 250+; a dark backing sheet laid over the photos reads much lower. Prints
/// often touch several edges of the scan area, so each side is measured
/// separately: the background only has to show on one of them.
private func backgroundLevel(_ pixels: UnsafeMutablePointer<UInt8>, _ sw: Int, _ sh: Int) -> Int {
    let border = max(1, min(sw, sh) / 50)
    var sides: [[UInt8]] = [[], [], [], []]
    for y in 0..<sh {
        for x in 0..<sw {
            let v = pixels[y * sw + x]
            if y < border { sides[0].append(v) }
            if y >= sh - border { sides[1].append(v) }
            if x < border { sides[2].append(v) }
            if x >= sw - border { sides[3].append(v) }
        }
    }
    var medians: [Int] = []
    var spreads: [Int] = []
    for i in sides.indices {
        sides[i].sort()
        let side = sides[i]
        guard !side.isEmpty else { continue }
        medians.append(Int(side[side.count / 2]))
        spreads.append(Int(side[side.count * 3 / 4]) - Int(side[side.count / 4]))
    }
    guard let brightest = medians.max() else { return 255 }
    // Any side that reads near-white is bare bed.
    if brightest >= 244 { return brightest }
    // No white side: a deliberate dark backing sheet shows on some side as a
    // band that is both uniform and truly dark. Anything else (e.g. photo
    // content touching every edge of an already-cropped image) is treated
    // as white bed.
    let flattest = spreads.firstIndex(of: spreads.min()!) ?? 0
    let level = medians[flattest]
    return (spreads[flattest] <= 10 && level < 160) ? level : 255
}

/// Downscaled thresholded view of the page: true where the pixel is not scan
/// background. The background level is measured from the page frame, so a
/// dark backing sheet laid over the photos works as well as the bare white
/// bed. Two signals are combined, because luminance alone cannot tell a
/// washed-out photo sky (which can scan at 246+) from a white bed:
///  - luminance: far enough from the background level is content
///    (against a white bed that means below `threshold`);
///  - gradient: the background is flat while a print's edge is always a
///    luminance step, so any local step > `gradientThreshold` is content too.
private func contentMask(_ image: CGImage, maxDim: Int, threshold: UInt8,
                         gradientThreshold: Int = 3,
                         background backgroundOverride: Int? = nil) -> (Mask, Double, Int)? {
    let scale = min(1.0, Double(maxDim) / Double(max(image.width, image.height)))
    let sw = max(1, Int(Double(image.width) * scale))
    let sh = max(1, Int(Double(image.height) * scale))

    guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                              bytesPerRow: sw, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.interpolationQuality = .low
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

    // Measured once per page and passed down to region-level calls, where
    // the crop's own frame would mostly sample photo, not background.
    let background = backgroundOverride ?? backgroundLevel(pixels, sw, sh)
    let whiteBed = background >= 244

    var bits = [Bool](repeating: false, count: sw * sh)
    for y in 0..<sh {
        for x in 0..<sw {
            let i = y * sw + x
            let v = Int(pixels[i])
            if !whiteBed {
                // Dark/colored backing: photos are far lighter than it.
                if abs(v - background) > 18 { bits[i] = true }
                continue
            }
            // The gradient spans two pixels because downscaling smears a
            // print edge's step across neighbours.
            if v < Int(threshold) {
                bits[i] = true
            } else if x + 2 < sw, abs(v - Int(pixels[i + 2])) > gradientThreshold {
                bits[i] = true
            } else if y + 2 < sh, abs(v - Int(pixels[i + 2 * sw])) > gradientThreshold {
                bits[i] = true
            }
        }
    }
    return (Mask(bits: bits, width: sw, height: sh), scale, background)
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
private func detectContentRegions(_ image: CGImage) -> (regions: [CGRect], background: Int) {
    guard let (rawMask, scale, background) = contentMask(image, maxDim: 600, threshold: 246) else {
        return ([], 255)
    }
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

    // Prints laid almost touching on the glass can merge into one region;
    // split any region crossed by a narrow all-background seam.
    rects = rects.flatMap { splitMergedPhotos(image, $0, background: background) }
        .filter { min($0.width, $0.height) >= Double(minSide) * inv }

    // Top-to-bottom, left-to-right output order.
    let sorted = rects.sorted {
        abs($0.minY - $1.minY) > 20 ? $0.minY < $1.minY : $0.minX < $1.minX
    }
    if ProcessInfo.processInfo.environment["RETROSCAN_DEBUG"] != nil {
        let rectsText = sorted.map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" }
            .joined(separator: " ")
        FileHandle.standardError.write(Data(
            "debug: background=\(background) components=\(boxes.count) regions=\(sorted.count) \(rectsText)\n".utf8))
    }
    return (sorted, background)
}

// MARK: - Seam split (photos touching on the glass)

/// Splits a region wherever a narrow band of near-bed-white runs all the way
/// across it — the gap between two prints laid too close together. A pale
/// area inside one photo never qualifies: it would have to be a full-length,
/// nearly pure-white stripe thinner than 4% of the region.
private func splitMergedPhotos(_ image: CGImage, _ rect: CGRect, background: Int,
                               depth: Int = 0) -> [CGRect] {
    guard depth < 3, rect.width > 80, rect.height > 80,
          let region = image.cropping(to: rect) else { return [rect] }

    let maxDim = 900
    let scale = min(1.0, Double(maxDim) / Double(max(region.width, region.height)))
    let sw = max(1, Int(Double(region.width) * scale))
    let sh = max(1, Int(Double(region.height) * scale))
    guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                              bytesPerRow: sw, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue),
          case _ = ctx.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh)),
          let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [rect] }

    // Fraction of background-level pixels per column/row. Pure white always
    // counts as seam material: even over a dark backing, a strip of bare bed
    // white between two prints is a gap, never photo content.
    func isBackground(_ v: UInt8) -> Bool {
        v >= 248 || abs(Int(v) - background) <= 10
    }
    func whiteFraction(column x: Int) -> Double {
        var white = 0
        for y in 0..<sh where isBackground(pixels[y * sw + x]) { white += 1 }
        return Double(white) / Double(sh)
    }
    func whiteFraction(row y: Int) -> Double {
        var white = 0
        for x in 0..<sw where isBackground(pixels[y * sw + x]) { white += 1 }
        return Double(white) / Double(sw)
    }

    let inv = 1.0 / scale
    // (span, isBlank at index, make the two sub-rects from a seam center)
    let axes: [(Int, (Int) -> Bool, (Double) -> (CGRect, CGRect))] = [
        (sw, { whiteFraction(column: $0) >= 0.99 }, { cut in
            (CGRect(x: rect.minX, y: rect.minY, width: cut, height: rect.height),
             CGRect(x: rect.minX + cut, y: rect.minY, width: rect.width - cut, height: rect.height))
        }),
        (sh, { whiteFraction(row: $0) >= 0.99 }, { cut in
            (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut),
             CGRect(x: rect.minX, y: rect.minY + cut, width: rect.width, height: rect.height - cut))
        }),
    ]

    for (span, isBlank, makeRects) in axes {
        let maxSeamWidth = max(3, span * 4 / 100)
        let minSide = span / 10
        var i = minSide
        while i < span - minSide {
            guard isBlank(i) else { i += 1; continue }
            var j = i
            while j + 1 < span && isBlank(j + 1) { j += 1 }
            let width = j - i + 1
            if width <= maxSeamWidth && j < span - minSide {
                let cut = Double(i + j + 1) / 2 * inv
                let (a, b) = makeRects(cut)
                return splitMergedPhotos(image, a, background: background, depth: depth + 1)
                    + splitMergedPhotos(image, b, background: background, depth: depth + 1)
            }
            i = j + 1
        }
    }
    return [rect]
}

// MARK: - Rectangle snap (Vision edge detection)

/// Refines a coarse content region to the photo print's true rectangle using
/// edge-based detection, which sees the print's boundary even where a pale
/// sky is indistinguishable from bed white by luminance alone. Returns the
/// perspective-corrected crop, or nil when no convincing rectangle is found.
private func snapToRectangle(_ image: CGImage, around region: CGRect) -> CGImage? {
    let w = CGFloat(image.width)
    let h = CGFloat(image.height)
    // The region can underestimate the photo (a washed-out sky band may be
    // missing from it), so search well beyond it.
    let pad = max(w, h) * 0.05
    let search = region.insetBy(dx: -pad, dy: -pad)
        .intersection(CGRect(x: 0, y: 0, width: w, height: h))

    // Vision wants a bottom-left-origin normalized ROI.
    let roi = CGRect(x: search.minX / w,
                     y: 1 - search.maxY / h,
                     width: search.width / w,
                     height: search.height / h)

    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 5
    request.minimumAspectRatio = 0.2
    request.maximumAspectRatio = 1.0
    request.quadratureTolerance = 20
    request.minimumConfidence = 0.5
    request.minimumSize = 0.3
    request.regionOfInterest = roi

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil,
          let observations = request.results, !observations.isEmpty else { return nil }

    // Observation points are normalized to the ROI, bottom-left origin.
    // Map them to top-left-origin pixels to compare against `region`.
    func pixelPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (roi.minX + p.x * roi.width) * w,
                y: (1 - (roi.minY + p.y * roi.height)) * h)
    }

    var best: (obs: VNRectangleObservation, box: CGRect, overlap: Double)?
    for obs in observations {
        let corners = [obs.topLeft, obs.topRight, obs.bottomLeft, obs.bottomRight].map(pixelPoint)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!,
                         width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        // The right rectangle mostly covers our region and stays in the same
        // ballpark of size — a neighbour photo's quad barely overlaps.
        let overlap = Double(box.intersection(region).width * box.intersection(region).height)
        let regionArea = Double(region.width * region.height)
        let boxArea = Double(box.width * box.height)
        guard overlap > regionArea * 0.5, boxArea < regionArea * 2.5 else { continue }
        if overlap > (best?.overlap ?? 0) {
            best = (obs, box, overlap)
        }
    }
    guard let best else { return nil }

    // CIPerspectiveCorrection takes bottom-left-origin pixel coordinates,
    // which is what Vision's normalized points map to directly.
    func ciPoint(_ p: CGPoint) -> CIVector {
        CIVector(cgPoint: CGPoint(x: (roi.minX + p.x * roi.width) * w,
                                  y: (roi.minY + p.y * roi.height) * h))
    }
    let corrected = CIImage(cgImage: image).applyingFilter("CIPerspectiveCorrection", parameters: [
        "inputTopLeft": ciPoint(best.obs.topLeft),
        "inputTopRight": ciPoint(best.obs.topRight),
        "inputBottomLeft": ciPoint(best.obs.bottomLeft),
        "inputBottomRight": ciPoint(best.obs.bottomRight),
    ])
    return ciContext.createCGImage(corrected, from: corrected.extent)
}

/// One photo region -> cropped image: edge-based rectangle snap when Vision
/// finds one, luminance-based tightening otherwise.
private func cropRegion(_ image: CGImage, _ region: CGRect, background: Int,
                        sam: SAMDetector?) -> CroppedImage? {
    // SAM pins the print's true extent (even edges invisible to thresholds);
    // the tighten pass then shaves the print's own white paper border. A
    // region covering nearly the whole page is an already-cropped image:
    // there is no background to separate and SAM would segment inside it.
    let pageArea = Double(image.width * image.height)
    let regionIsWholePage = Double(region.width * region.height) > pageArea * 0.9
    if let sam, !regionIsWholePage, let refined = try? sam.refine(region: region) {
        let rect = tightenRect(image, refined, background: background)
        if let cropped = image.cropping(to: rect) {
            return CroppedImage(image: cropped, method: "photo (SAM)", sourceRect: rect)
        }
    }
    if let snapped = snapToRectangle(image, around: region) {
        // Perspective-corrected: the coarse region is only a seed for re-crops.
        return CroppedImage(image: snapped, method: "photo (edges)", sourceRect: region)
    }
    let rect = tightenRect(image, region, background: background)
    return image.cropping(to: rect)
        .map { CroppedImage(image: $0, method: "photo (bbox)", sourceRect: rect) }
}

// MARK: - Edge tightening

/// Shrinks a crop rect until no near-white edge rows/columns remain (photo
/// prints have their own white paper border), then bites a few extra pixels
/// in. Losing a sliver of photo is preferred over keeping any white.
private func tightenRect(_ image: CGImage, _ rect: CGRect, background: Int) -> CGRect {
    guard rect.width > 40, rect.height > 40,
          let region = image.cropping(to: rect) else { return rect }

    // Buffer row 0 is the top of the region, matching cropping(to:) coords.
    // Only true bed rows count as blank: near-pure white AND flat. A pale
    // photo sky (learned on a Monaco skyline that lost its top) survives via
    // either its luminance or the print edge's gradient.
    guard let (mask, scale, _) = contentMask(region, maxDim: 1200, threshold: 246,
                                             background: background) else { return rect }
    let sw = mask.width, sh = mask.height

    func rowDarkFraction(_ y: Int) -> Double {
        var dark = 0
        for x in 0..<sw where mask.bits[y * sw + x] { dark += 1 }
        return Double(dark) / Double(sw)
    }
    func colDarkFraction(_ x: Int) -> Double {
        var dark = 0
        for y in 0..<sh where mask.bits[y * sw + x] { dark += 1 }
        return Double(dark) / Double(sh)
    }

    let need = 0.02           // a row/column with <2% such pixels is bed white
    // Rows with essentially nothing (≤2 mask pixels) are true background and
    // can be stripped without limit — even a featureless sky row carries the
    // print edge's gradient columns. The capped walk after that only shaves
    // the print's own paper border; a sky band must survive it, hence 3%.
    func isEmptyRow(_ y: Int) -> Bool {
        var dark = 0
        for x in 0..<sw where mask.bits[y * sw + x] { dark += 1; if dark > 2 { return false } }
        return true
    }
    func isEmptyCol(_ x: Int) -> Bool {
        var dark = 0
        for y in 0..<sh where mask.bits[y * sw + x] { dark += 1; if dark > 2 { return false } }
        return true
    }
    var top = 0
    while top < sh - 1 && isEmptyRow(top) { top += 1 }
    var bottom = 0
    while bottom < sh - 1 - top && isEmptyRow(sh - 1 - bottom) { bottom += 1 }
    var left = 0
    while left < sw - 1 && isEmptyCol(left) { left += 1 }
    var right = 0
    while right < sw - 1 - left && isEmptyCol(sw - 1 - right) { right += 1 }

    let maxShrinkY = top + sh * 3 / 100
    let maxShrinkX = left + sw * 3 / 100
    let maxShrinkY2 = bottom + sh * 3 / 100
    let maxShrinkX2 = right + sw * 3 / 100
    while top < maxShrinkY && rowDarkFraction(top) < need { top += 1 }
    while bottom < maxShrinkY2 && rowDarkFraction(sh - 1 - bottom) < need { bottom += 1 }
    while left < maxShrinkX && colDarkFraction(left) < need { left += 1 }
    while right < maxShrinkX2 && colDarkFraction(sw - 1 - right) < need { right += 1 }

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
private func trimWhiteBorders(_ image: CGImage) -> (CGImage, CGRect)? {
    guard let (mask, scale, _) = contentMask(image, maxDim: 800, threshold: 246) else { return nil }
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
    return image.cropping(to: rect).map { ($0, rect) }
}

// MARK: - Orientation

public enum RotateOption {
    case auto
    case none
    case fixed(CGImagePropertyOrientation)
}

/// Finds the rotation that puts the photo upright by running face detection
/// in all four orientations and keeping the one where faces stand straight
/// (confidence weighted by the face roll angle). Returns nil when no face
/// gives a clear answer (e.g. landscapes).
public func detectUprightOrientation(_ image: CGImage) -> CGImagePropertyOrientation? {
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

public func rotated(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage {
    guard orientation != .up else { return image }
    let oriented = CIImage(cgImage: image).oriented(orientation)
    return ciContext.createCGImage(oriented, from: oriented.extent) ?? image
}

public func degrees(_ orientation: CGImagePropertyOrientation) -> Int {
    switch orientation {
    case .right: return 90
    case .down: return 180
    case .left: return 270
    default: return 0
    }
}

// MARK: - Grayscale

/// The scanner only streams JPEG in color mode; gray output is produced here.
public func convertToGrayscale(_ image: CGImage) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ctx.makeImage()
}

// MARK: - Metadata + encode

public func writeJPEG(image: CGImage, metadata m: ImageMetadata, to url: URL) throws {
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
