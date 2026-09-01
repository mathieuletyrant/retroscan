import Foundation
import CoreML
import CoreGraphics
import CoreVideo

/// Photo detection powered by Segment Anything (SAM 2, Apple's Core ML
/// conversion) running on the Neural Engine.
///
/// The coarse luminance/gradient regions locate the prints; each one is then
/// handed to SAM as a box prompt, and SAM returns the print's true mask —
/// including edges that are invisible to thresholds, like a white tablecloth
/// against bed white. The image encoder runs once per page; the prompt
/// encoder and mask decoder run per region (a few milliseconds each).
public final class SAMDetector {
    private let imageEncoder: MLModel
    private let promptEncoder: MLModel
    private let maskDecoder: MLModel

    private var pageEmbedding: MLFeatureProvider?
    private var pageWidth = 1
    private var pageHeight = 1

    private static let inputSide = 1024
    private static let packages = [
        "SAM2TinyImageEncoderFLOAT16",
        "SAM2TinyPromptEncoderFLOAT16",
        "SAM2TinyMaskDecoderFLOAT16",
    ]
    private static let repoBase = "https://huggingface.co/apple/coreml-sam2-tiny/resolve/main"
    private static let packageFiles = [
        "Manifest.json",
        "Data/com.apple.CoreML/model.mlmodel",
        "Data/com.apple.CoreML/weights/weight.bin",
    ]

    public static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("retroscan/sam2-tiny", isDirectory: true)
    }

    public static func modelsPresent() -> Bool {
        packages.allSatisfy { name in
            FileManager.default.fileExists(
                atPath: modelsDirectory.appendingPathComponent("\(name).mlmodelc").path)
            || FileManager.default.fileExists(
                atPath: modelsDirectory.appendingPathComponent(
                    "\(name).mlpackage/Data/com.apple.CoreML/weights/weight.bin").path)
        }
    }

    /// Downloads the three Core ML packages (~78 MB) from Hugging Face.
    public static func downloadModels(progress: (String) -> Void) throws {
        let fm = FileManager.default
        for package in packages {
            progress("downloading \(package)…")
            for file in packageFiles {
                let dest = modelsDirectory.appendingPathComponent("\(package).mlpackage/\(file)")
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { continue }
                let url = URL(string: "\(repoBase)/\(package).mlpackage/\(file)")!
                let sem = DispatchSemaphore(value: 0)
                var result: Result<URL, Error> = .failure(ScanError.timeout("download"))
                let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                    if let error {
                        result = .failure(error)
                    } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        result = .failure(ScanError.protocolError("HTTP \(http.statusCode) for \(url.lastPathComponent)"))
                    } else if let tmp {
                        result = .success(tmp)
                    }
                    sem.signal()
                }
                task.resume()
                sem.wait()
                let tmp = try result.get()
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            }
        }
    }

    public init() throws {
        _ = Self.outputFilter
        let config = MLModelConfiguration()
        // Matches Apple's sam2-studio demo: one encoder op is unsupported on
        // the ANE and triggers a noisy E5RT fallback warning under .all.
        config.computeUnits = .cpuAndGPU
        var models: [MLModel] = []
        for name in Self.packages {
            let compiled = Self.modelsDirectory.appendingPathComponent("\(name).mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let package = Self.modelsDirectory.appendingPathComponent("\(name).mlpackage")
                let tmp = try MLModel.compileModel(at: package)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: tmp, to: compiled)
            }
            models.append(try MLModel(contentsOf: compiled, configuration: config))
        }
        imageEncoder = models[0]
        promptEncoder = models[1]
        maskDecoder = models[2]
    }

    /// Core ML's E5RT layer prints a harmless conv_transpose warning — to
    /// stdout, of all places, and from its own thread, so it can't be
    /// silenced around any one call. Instead stdout is routed through a
    /// filter thread that drops E5RT chatter and forwards everything else
    /// untouched. Line buffering is kept so progress output stays live.
    private static let outputFilter: Void = {
        let saved = dup(STDOUT_FILENO)
        var fds: [Int32] = [0, 0]
        guard saved >= 0, pipe(&fds) == 0 else { return }
        dup2(fds[1], STDOUT_FILENO)
        close(fds[1])
        setlinebuf(stdout)
        let readFD = fds[0]
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var pending = ""
            func emit(_ text: String) {
                let data = Data(text.utf8)
                data.withUnsafeBytes { _ = write(saved, $0.baseAddress, $0.count) }
            }
            while true {
                let n = read(readFD, &buffer, buffer.count)
                if n <= 0 { break }
                pending += String(decoding: buffer[0..<n], as: UTF8.self)
                // The E5RT message carries no newline of its own, so it sits
                // inside whatever line of ours follows it; excise just it.
                while let newline = pending.firstIndex(of: "\n") {
                    var line = String(pending[...newline])
                    pending.removeSubrange(...newline)
                    while let match = line.range(of: "E5RT.*?\\.\\.", options: .regularExpression) {
                        line.removeSubrange(match)
                    }
                    if line.contains("E5RT") { continue }
                    emit(line)
                }
            }
            if !pending.isEmpty && !pending.contains("E5RT") { emit(pending) }
        }
    }()

    /// Runs the image encoder once for this page.
    func encode(page: CGImage) throws {
        pageWidth = page.width
        pageHeight = page.height

        var pixelBuffer: CVPixelBuffer?
        let side = Self.inputSide
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                            &pixelBuffer)
        guard let buffer = pixelBuffer else {
            throw ScanError.protocolError("could not create pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw ScanError.protocolError("could not draw into pixel buffer")
        }
        ctx.draw(page, in: CGRect(x: 0, y: 0, width: side, height: side))

        let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        pageEmbedding = try imageEncoder.prediction(from: input)
    }

    /// Refines a coarse region to the print SAM sees there. Returns nil when
    /// SAM's answer is implausible (no mask, or nothing like the region).
    func refine(region: CGRect) throws -> CGRect? {
        guard let embedding = pageEmbedding else { return nil }

        // Box prompt, slightly padded, in the encoder's 1024×1024 space.
        let pad = 0.04 * Double(max(pageWidth, pageHeight))
        let search = region.insetBy(dx: -pad, dy: -pad)
            .intersection(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        let sx = Double(Self.inputSide) / Double(pageWidth)
        let sy = Double(Self.inputSide) / Double(pageHeight)

        let points = try MLMultiArray(shape: [1, 2, 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, 2], dataType: .int32)
        points[[0, 0, 0]] = NSNumber(value: search.minX * sx)
        points[[0, 0, 1]] = NSNumber(value: search.minY * sy)
        points[[0, 1, 0]] = NSNumber(value: search.maxX * sx)
        points[[0, 1, 1]] = NSNumber(value: search.maxY * sy)
        labels[[0, 0]] = 2 // box origin
        labels[[0, 1]] = 3 // box end

        let promptInput = try MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: points),
            "labels": MLFeatureValue(multiArray: labels),
        ])
        let prompt = try promptEncoder.prediction(from: promptInput)

        guard let imageEmbedding = embedding.featureValue(for: "image_embedding")?.multiArrayValue,
              let feats0 = embedding.featureValue(for: "feats_s0")?.multiArrayValue,
              let feats1 = embedding.featureValue(for: "feats_s1")?.multiArrayValue,
              let sparse = prompt.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = prompt.featureValue(for: "dense_embeddings")?.multiArrayValue else {
            return nil
        }
        let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": MLFeatureValue(multiArray: imageEmbedding),
            "sparse_embedding": MLFeatureValue(multiArray: sparse),
            "dense_embedding": MLFeatureValue(multiArray: dense),
            "feats_s0": MLFeatureValue(multiArray: feats0),
            "feats_s1": MLFeatureValue(multiArray: feats1),
        ])
        let output = try maskDecoder.prediction(from: decoderInput)

        guard let masks = output.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = output.featureValue(for: "scores")?.multiArrayValue else {
            return nil
        }

        // Best-scoring of the candidate masks.
        var best = 0
        for i in 0..<scores.count where scores[i].floatValue > scores[best].floatValue {
            best = i
        }

        // Bounding box of positive mask logits, mapped back to page pixels.
        let maskH = masks.shape[2].intValue
        let maskW = masks.shape[3].intValue
        var minX = maskW, maxX = -1, minY = maskH, maxY = -1
        let plane = best * maskH * maskW
        func scan<T: BinaryFloatingPoint & MLShapedArrayScalar>(_ type: T.Type) {
            masks.withUnsafeBufferPointer(ofType: T.self) { ptr in
                for y in 0..<maskH {
                    for x in 0..<maskW where ptr[plane + y * maskW + x] > 0 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        switch masks.dataType {
        case .float16:
            if #available(macOS 15.0, *) {
                scan(Float16.self)
            } else {
                for y in 0..<maskH {
                    for x in 0..<maskW where masks[[0, best, y, x] as [NSNumber]].floatValue > 0 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        case .double: scan(Double.self)
        default: scan(Float.self)
        }
        guard maxX >= 0 else { return nil }

        var rect = CGRect(x: Double(minX) / Double(maskW) * Double(pageWidth),
                          y: Double(minY) / Double(maskH) * Double(pageHeight),
                          width: Double(maxX - minX + 1) / Double(maskW) * Double(pageWidth),
                          height: Double(maxY - minY + 1) / Double(maskH) * Double(pageHeight))
        rect = rect.intersection(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        // Sanity: SAM must broadly agree with the coarse region — otherwise
        // it latched onto something inside or around the print.
        let overlap = rect.intersection(region)
        let regionArea = region.width * region.height
        guard overlap.width * overlap.height > regionArea * 0.5,
              rect.width * rect.height < regionArea * 3.0 else { return nil }
        return rect
    }
}
