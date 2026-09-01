import AppKit
import CoreGraphics
import Foundation
import RetroscanKit

// MARK: - Writing JPEGs and the album file

extension ScanModel {
    /// One cropped image out of the pipeline, ready to be written.
    struct ProcessedImage {
        var image: CGImage      // page orientation, grayscale applied
        var thumbnail: CGImage  // display orientation
        var quarterTurns: Int
        var method: String
        var pageIndex: Int
        var sourceRect: CGRect?
    }

    /// Opens the album folder in the Finder (creating it if needed, so the
    /// button works before the first scan).
    func revealOutputFolder() {
        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputDirectory)
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    /// Writes each processed image as "<base>-N.jpg" — numbering continuing
    /// from whatever already exists in the folder (same rule as the CLI) —
    /// records it in the album file, and returns the grid entries.
    /// Runs on workQueue.
    func save(_ items: [ProcessedImage], batch: UUID, dpi: Int, model: String?,
              settings: Settings) throws -> [AlbumPhoto] {
        try FileManager.default.createDirectory(at: settings.outDir,
                                                withIntermediateDirectories: true)
        var next = nextFreeIndex(in: settings.outDir, base: settings.baseName)
        var recorded: [String: FileRecord] = [:]
        var saved: [AlbumPhoto] = []
        for item in items {
            let image = rotated(item.image, quarterTurns: item.quarterTurns)
            let url = settings.outDir.appendingPathComponent("\(settings.baseName)-\(next).jpg")
            var metadata = settings.metadata
            metadata.scannerModel = model
            metadata.dpi = dpi
            try writeJPEG(image: image, metadata: metadata, to: url)
            recorded[url.lastPathComponent] = FileRecord(
                batch: batch, pageIndex: item.pageIndex,
                sourceRect: Self.array(from: item.sourceRect),
                quarterTurns: item.quarterTurns,
                dpi: dpi, scannerModel: model, method: item.method)
            saved.append(AlbumPhoto(
                batch: batch, thumbnail: item.thumbnail,
                quarterTurns: item.quarterTurns,
                pixelWidth: image.width, pixelHeight: image.height,
                method: item.method, dpi: dpi, scannerModel: model,
                savedURL: url,
                pageIndex: item.pageIndex, sourceRect: item.sourceRect))
            next += 1
        }

        // The album file: current album values, plus the per-file records
        // accumulated across saves (earlier entries are kept).
        mutateAlbumInfo(settings.outDir.appendingPathComponent(Self.albumFileName)) { info in
            let files = (info.files ?? [:]).merging(recorded) { _, new in new }
            info = settings.album
            info.files = files
        }
        return saved
    }
}
