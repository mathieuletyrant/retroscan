import CoreGraphics
import Foundation
import RetroscanKit
import SwiftUI

/// One photo of the album, as shown in the grid. Every photo is on disk —
/// scans are saved the moment they are processed — and stays editable:
/// crop, rotation and metadata edits rewrite the JPEG in place.
struct AlbumPhoto: Identifiable {
    var id = UUID()
    let batch: UUID
    /// Small image for the grid; the saved JPEG is the full-resolution one.
    var thumbnail: CGImage
    /// Rotation (90° clockwise steps) baked into the saved JPEG, kept
    /// relative to the source page so a later re-crop composes with it.
    var quarterTurns = 0
    /// Per-photo metadata overrides; empty means "inherit the album value".
    var dateOverride = ""
    var captionOverride = ""
    var hasOverrides: Bool { !dateOverride.isEmpty || !captionOverride.isEmpty }
    var pixelWidth: Int
    var pixelHeight: Int
    var method: String
    let dpi: Int
    let scannerModel: String?
    let savedURL: URL
    /// Where this crop sits on its scanned page — lets the crop be adjusted
    /// by hand while that page's raw data is still in the cache.
    var pageIndex: Int?
    var sourceRect: CGRect?
}

/// Everything the crop editor sheet needs: the full-resolution page and the
/// photo's current rectangle on it.
struct CropEditingContext: Identifiable {
    let id: UUID  // the photo's id
    let page: CGImage
    let rect: CGRect
}

/// UI state and orchestration, split across files by concern:
///  - ScanModel+Scanner — talking to the printer (discovery, scan, watch,
///    the crop pipeline, re-process)
///  - ScanModel+Photos — per-photo actions and the crop editor
///  - ScanModel+Saving — writing JPEGs and the album file
///  - ScanModel+Album — the output folder as a reopenable project
///  - ScanModel+Cache — the original scanned pages kept on disk
///
/// The kit's calls are all blocking, so scanner and pipeline work runs on
/// `workQueue` (or the watch thread); @Published state is only touched on
/// the main thread. A scan, a rewrite and the watch loop are mutually
/// exclusive via `busy`/`watching`.
///
/// Every scan is written to the album folder as soon as it is processed —
/// there is no unsaved state, and every edit rewrites the file in place.
/// Settings persist in two places: app-level preferences (scan settings,
/// author, last output folder) in UserDefaults, and per-album metadata
/// (title, description, keywords, date, plus a record of every saved file
/// and where it came from) in a `.retroscan.json` file inside the output
/// folder. That file makes the folder a reopenable project: choosing it
/// again reloads the metadata and the saved photos, whose crops stay
/// adjustable for as long as their raw pages are in the cache — pages are
/// only ever dropped by Delete Original Scans.
final class ScanModel: ObservableObject {
    // Scanner
    @Published var scanners: [DiscoveredScanner] = []
    @Published var selectedScanner: String?
    @Published var discovering = false

    // Scan settings
    @Published var resolution = 300 { didSet { persistDefaults() } }
    @Published var grayscale = false { didSet { persistDefaults() } }
    @Published var crop: CropStrategy = .auto { didSet { persistDefaults() } }
    @Published var autoRotate = true { didSet { persistDefaults() } }
    @Published var quality = 0.92 { didSet { persistDefaults() } }

    // Metadata (album-level, written to the folder's .retroscan.json as
    // soon as a field changes — nothing else would persist an edit made
    // after the last scan)
    @Published var title = "" { didSet { persistAlbumInfo() } }
    @Published var caption = "" { didSet { persistAlbumInfo() } }
    @Published var author = "" { didSet { persistDefaults(); persistAlbumInfo() } }
    @Published var keywords = "" { didSet { persistAlbumInfo() } }
    @Published var dateTaken = "" { didSet { persistAlbumInfo() } }

    // Output
    @Published var outputDirectory: URL {
        didSet {
            persistDefaults()
            loadAlbumInfo(from: outputDirectory)
        }
    }

    // Session
    @Published var photos: [AlbumPhoto] = []
    @Published var busy = false
    @Published var watching = false
    @Published var status = "Ready"
    @Published var errorMessage: String?
    /// Total size of the cached raw pages — the disk cost of keeping every
    /// crop adjustable. Recomputed alongside the cache manifest.
    @Published var cacheBytes: Int64 = 0

    var dateTakenValid: Bool { dateTaken.isEmpty || ContentDate(dateTaken) != nil }

    /// didSet observers on wrapped properties fire even for the assignments
    /// inside init — keep them from writing half-loaded values back to
    /// UserDefaults until every preference has been read.
    var restored = false
    /// True while loadAlbumInfo fills the metadata fields, so their didSet
    /// observers don't write half-loaded values back to the album file.
    var loadingAlbum = false
    /// Debounces re-embedding the album metadata into every photo's JPEG
    /// after sidebar edits (main thread only).
    var albumMetadataPropagation: DispatchWorkItem?
    let workQueue = DispatchQueue(label: "retroscan.work", qos: .userInitiated)
    var listener: PushScanListener?
    var lastBatch: (id: UUID, pages: [Data], pageURLs: [URL], dpi: Int, model: String?)?
    /// Raw pages kept on disk per batch — for as long as the cache lives,
    /// so any photo can have its crop re-adjusted from its source page.
    /// Only Delete Original Scans drops them.
    var batches: [UUID: CacheManifest.Batch] = [:]
    /// Holds the cached raw pages and their manifest — a stable location
    /// shared across launches.
    let pendingDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("retroscan/pending", isDirectory: true)

    init() {
        let d = UserDefaults.standard
        let defaultDir = (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Retroscan", isDirectory: true)
        outputDirectory = d.string(forKey: "outputDirectory")
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDir
        if d.object(forKey: "resolution") != nil { resolution = d.integer(forKey: "resolution") }
        grayscale = d.bool(forKey: "grayscale")
        if let raw = d.string(forKey: "crop"), let strategy = CropStrategy(rawValue: raw) {
            crop = strategy
        }
        if d.object(forKey: "autoRotate") != nil { autoRotate = d.bool(forKey: "autoRotate") }
        if d.object(forKey: "quality") != nil { quality = d.double(forKey: "quality") }
        author = d.string(forKey: "author") ?? ""

        try? FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        loadAlbumInfo(from: outputDirectory)
        restoreCache()
        restored = true
        refreshScanners()
    }

    // MARK: - App-level preferences

    private func persistDefaults() {
        guard restored else { return }
        let d = UserDefaults.standard
        d.set(outputDirectory.path, forKey: "outputDirectory")
        d.set(resolution, forKey: "resolution")
        d.set(grayscale, forKey: "grayscale")
        d.set(crop.rawValue, forKey: "crop")
        d.set(autoRotate, forKey: "autoRotate")
        d.set(quality, forKey: "quality")
        d.set(author, forKey: "author")
    }

    // MARK: - Shared helpers

    /// An immutable copy of everything the background work needs, taken on
    /// the main thread before hopping to workQueue.
    struct Settings {
        var resolution: Int
        var grayscale: Bool
        var crop: CropStrategy
        var autoRotate: Bool
        var metadata: ImageMetadata
        var outDir: URL
        var baseName: String
        var album: AlbumInfo
    }

    func snapshotSettings() -> Settings {
        let keywordList = keywords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let metadata = ImageMetadata(
            title: title.isEmpty ? nil : title,
            description: caption.isEmpty ? nil : caption,
            author: author.isEmpty ? nil : author,
            keywords: keywordList,
            contentDate: ContentDate(dateTaken),
            dpi: resolution,
            jpegQuality: quality)
        let base = sanitizeForFilename(title)
        let album = AlbumInfo(
            title: title.isEmpty ? nil : title,
            description: caption.isEmpty ? nil : caption,
            author: author.isEmpty ? nil : author,
            keywords: keywords.isEmpty ? nil : keywords,
            dateTaken: dateTaken.isEmpty ? nil : dateTaken)
        return Settings(resolution: resolution, grayscale: grayscale, crop: crop,
                        autoRotate: autoRotate, metadata: metadata,
                        outDir: outputDirectory,
                        baseName: base.isEmpty ? "scan" : base,
                        album: album)
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    func finish(with error: Error) {
        DispatchQueue.main.async {
            self.busy = false
            self.status = "Ready"
            self.errorMessage = "\(error)"
        }
    }
}
