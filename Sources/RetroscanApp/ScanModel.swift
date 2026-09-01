import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Network
import RetroscanKit
import SwiftUI
import UniformTypeIdentifiers

struct PendingPhoto: Identifiable {
    let id = UUID()
    let batch: UUID
    /// Small image for the grid; the full-resolution original is spilled to
    /// `fullResURL` (lossless PNG in the session temp dir) so a long session
    /// doesn't hold gigabytes of decoded bitmaps in memory.
    var thumbnail: CGImage
    let fullResURL: URL
    /// Manual rotation (90° clockwise steps), applied to the full-resolution
    /// image only at save time.
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
    var savedURL: URL?
}

/// UI state and orchestration. The kit's calls are all blocking, so scanner
/// and pipeline work runs on `workQueue` (or the watch thread); @Published
/// state is only touched on the main thread. A scan, a save and the watch
/// loop are mutually exclusive via `busy`/`watching`.
///
/// Settings persist in two places: app-level preferences (scan settings,
/// author, last output folder) in UserDefaults, and per-album metadata
/// (title, description, keywords, date) in a `.retroscan.json` file inside
/// the output folder — written on save, loaded back when the folder is
/// chosen again, so an album session resumes where it left off.
final class ScanModel: ObservableObject {
    // Scanner
    @Published var scanners: [DiscoveredScanner] = []
    @Published var selectedScanner: String?
    @Published var discovering = false

    // Scan settings
    @Published var resolution = 300 { didSet { persistDefaults() } }
    @Published var grayscale = false { didSet { persistDefaults() } }
    @Published var crop: CropStrategy = .auto { didSet { persistDefaults() } }
    @Published var useSAM = false { didSet { persistDefaults() } }
    @Published var autoRotate = true { didSet { persistDefaults() } }
    @Published var quality = 0.92 { didSet { persistDefaults() } }

    // Metadata (album-level, saved to the folder's .retroscan.json)
    @Published var title = ""
    @Published var caption = ""
    @Published var author = "" { didSet { persistDefaults() } }
    @Published var keywords = ""
    @Published var dateTaken = ""

    // Output
    @Published var outputDirectory: URL {
        didSet {
            persistDefaults()
            loadAlbumInfo(from: outputDirectory)
        }
    }
    @Published var autoSave = false { didSet { persistDefaults() } }

    // Session
    @Published var photos: [PendingPhoto] = []
    @Published var busy = false
    @Published var watching = false
    @Published var status = "Ready"
    @Published var errorMessage: String?

    var dateTakenValid: Bool { dateTaken.isEmpty || ContentDate(dateTaken) != nil }
    var unsavedCount: Int { photos.filter { $0.savedURL == nil }.count }

    /// didSet observers on wrapped properties fire even for the assignments
    /// inside init — keep them from writing half-loaded values back to
    /// UserDefaults until every preference has been read.
    private var restored = false
    private let workQueue = DispatchQueue(label: "retroscan.work", qos: .userInitiated)
    private var listener: PushScanListener?
    private var sam: SAMDetector?
    private var lastBatch: (id: UUID, pages: [Data], dpi: Int, model: String?)?
    /// Holds the spilled full-resolution PNGs for this session.
    private let sessionDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("retroscan-\(UUID().uuidString)", isDirectory: true)

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
        useSAM = d.bool(forKey: "useSAM")
        if d.object(forKey: "autoRotate") != nil { autoRotate = d.bool(forKey: "autoRotate") }
        if d.object(forKey: "quality") != nil { quality = d.double(forKey: "quality") }
        autoSave = d.bool(forKey: "autoSave")
        author = d.string(forKey: "author") ?? ""

        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        loadAlbumInfo(from: outputDirectory)
        restored = true
        refreshScanners()
    }

    deinit {
        try? FileManager.default.removeItem(at: sessionDir)
    }

    // MARK: - Persistence

    private func persistDefaults() {
        guard restored else { return }
        let d = UserDefaults.standard
        d.set(outputDirectory.path, forKey: "outputDirectory")
        d.set(resolution, forKey: "resolution")
        d.set(grayscale, forKey: "grayscale")
        d.set(crop.rawValue, forKey: "crop")
        d.set(useSAM, forKey: "useSAM")
        d.set(autoRotate, forKey: "autoRotate")
        d.set(quality, forKey: "quality")
        d.set(autoSave, forKey: "autoSave")
        d.set(author, forKey: "author")
    }

    private struct AlbumInfo: Codable {
        var title: String?
        var description: String?
        var author: String?
        var keywords: String?
        var dateTaken: String?
        /// Per-file record of the overrides actually embedded at save time,
        /// keyed by filename — a readable catalog of where a photo differs
        /// from the album. Write-only: the JPEG's own EXIF/IPTC stays the
        /// source of truth.
        var files: [String: FileOverride]?
    }

    private struct FileOverride: Codable {
        var dateTaken: String?
        var description: String?
    }

    private static let albumFileName = ".retroscan.json"

    /// Fills the metadata fields from the folder's album file; a folder
    /// without one starts a fresh album (author, an app-level preference,
    /// is kept).
    private func loadAlbumInfo(from dir: URL) {
        let url = dir.appendingPathComponent(Self.albumFileName)
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(AlbumInfo.self, from: data) else {
            title = ""; caption = ""; keywords = ""; dateTaken = ""
            return
        }
        title = info.title ?? ""
        caption = info.description ?? ""
        keywords = info.keywords ?? ""
        dateTaken = info.dateTaken ?? ""
        if let a = info.author, !a.isEmpty { author = a }
    }

    // MARK: - Discovery

    func refreshScanners() {
        guard !discovering else { return }
        discovering = true
        workQueue.async {
            let found = discoverScanners()
            DispatchQueue.main.async {
                self.scanners = found
                if self.selectedScanner == nil { self.selectedScanner = found.first?.name }
                self.discovering = false
            }
        }
    }

    private func selectedEndpoint() -> (NWEndpoint, String?)? {
        let scanner = scanners.first(where: { $0.name == selectedScanner }) ?? scanners.first
        return scanner.map { ($0.endpoint, $0.name) }
    }

    // MARK: - One-shot scan

    func scanOnce() {
        guard !busy, !watching else { return }
        guard let (endpoint, modelName) = selectedEndpoint() else {
            errorMessage = "No scanner found — check the printer is on, then refresh."
            return
        }
        busy = true
        let settings = snapshotSettings()
        workQueue.async {
            do {
                let sam = try self.prepareSAM(settings)
                let (pages, dpi) = try self.scan(endpoint: endpoint, settings: settings)
                try self.process(pages: pages, dpi: dpi, model: modelName, sam: sam, settings: settings)
                DispatchQueue.main.async { self.busy = false; self.status = "Ready" }
            } catch {
                self.finish(with: error)
            }
        }
    }

    /// Runs the crop/rotate pipeline on an existing scan JPEG (the CLI's
    /// --input): open a file with the app, or drop one on the grid, to
    /// replay a scan without touching the scanner.
    func processFile(_ url: URL) {
        guard !busy else { return }
        busy = true
        status = "Processing \(url.lastPathComponent)…"
        let settings = snapshotSettings()
        workQueue.async {
            do {
                guard let data = try? Data(contentsOf: url) else {
                    throw PipelineError.decodeFailed
                }
                let sam = try self.prepareSAM(settings)
                try self.process(pages: [data], dpi: settings.resolution, model: nil,
                                 sam: sam, settings: settings)
                DispatchQueue.main.async { self.busy = false; self.status = "Ready" }
            } catch {
                self.finish(with: error)
            }
        }
    }

    // MARK: - Watch mode (printer's Scan button)

    func toggleWatch() {
        if watching {
            status = "Stopping…"
            listener?.stop()
        } else {
            startWatch()
        }
    }

    private func startWatch() {
        guard !busy, !watching else { return }
        guard let (endpoint, modelName) = selectedEndpoint() else {
            errorMessage = "No scanner found — check the printer is on, then refresh."
            return
        }
        watching = true
        status = "Registering on the printer…"
        let settings = snapshotSettings()
        let thread = Thread {
            do {
                let sam = try self.prepareSAM(settings)
                let (printerIP, localIP) = try resolveAddresses(endpoint: endpoint)
                let listener = PushScanListener(printerHost: printerIP, localIP: localIP,
                                                displayName: "retroscan")
                try listener.start()
                DispatchQueue.main.async {
                    self.listener = listener
                    self.status = "Watching — press the printer's Scan button (Scan to PC > Image)"
                }
                while true {
                    do {
                        try listener.waitForButton()
                    } catch let error as ScanError {
                        if case .cancelled = error { break }
                        throw error
                    }
                    // A failed scan (jam, cover open, busy) shouldn't end the
                    // session: report it and keep listening, like the CLI.
                    do {
                        self.setStatus("Scan button pressed…")
                        let (pages, dpi) = try self.scan(endpoint: endpoint, settings: settings)
                        try self.process(pages: pages, dpi: dpi, model: modelName, sam: sam,
                                         settings: settings)
                        self.setStatus("Watching — ready for the next press")
                    } catch {
                        self.setStatus("\(error) — still watching")
                        Thread.sleep(forTimeInterval: 3)
                    }
                }
                DispatchQueue.main.async {
                    self.listener = nil
                    self.watching = false
                    self.status = "Ready"
                }
            } catch {
                DispatchQueue.main.async {
                    self.listener = nil
                    self.watching = false
                    self.status = "Ready"
                    self.errorMessage = "\(error)"
                }
            }
        }
        thread.name = "retroscan.watch"
        thread.start()
    }

    // MARK: - Per-photo actions

    func remove(_ photo: PendingPhoto) {
        photos.removeAll { $0.id == photo.id }
        try? FileManager.default.removeItem(at: photo.fullResURL)
    }

    /// 90° clockwise; only offered before saving, so preview and file agree.
    /// The thumbnail turns immediately, the full-resolution image at save.
    func rotate(_ photo: PendingPhoto) {
        guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos[i].quarterTurns = (photos[i].quarterTurns + 1) % 4
        photos[i].thumbnail = rotated(photos[i].thumbnail, .right)
        (photos[i].pixelWidth, photos[i].pixelHeight) = (photos[i].pixelHeight, photos[i].pixelWidth)
    }

    /// Bindings into a photo's override fields for the per-photo popover.
    func dateOverride(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.photos.first(where: { $0.id == id })?.dateOverride ?? "" },
            set: { value in
                if let i = self.photos.firstIndex(where: { $0.id == id }) {
                    self.photos[i].dateOverride = value
                }
            })
    }

    func captionOverride(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.photos.first(where: { $0.id == id })?.captionOverride ?? "" },
            set: { value in
                if let i = self.photos.firstIndex(where: { $0.id == id }) {
                    self.photos[i].captionOverride = value
                }
            })
    }

    func clearAll() {
        for photo in photos {
            try? FileManager.default.removeItem(at: photo.fullResURL)
        }
        photos.removeAll()
        lastBatch = nil
    }

    /// Re-runs crop/rotate with the current settings on the last scan's raw
    /// pages — no need to rescan to try another strategy or toggle SAM.
    /// Photos from that scan already saved to disk are left alone.
    func reprocessLastScan() {
        guard !busy, !watching, let last = lastBatch else { return }
        busy = true
        let settings = snapshotSettings()
        workQueue.async {
            do {
                let sam = try self.prepareSAM(settings)
                DispatchQueue.main.async {
                    let dropped = self.photos.filter { $0.batch == last.id && $0.savedURL == nil }
                    self.photos.removeAll { $0.batch == last.id && $0.savedURL == nil }
                    for photo in dropped {
                        try? FileManager.default.removeItem(at: photo.fullResURL)
                    }
                }
                try self.process(pages: last.pages, dpi: last.dpi, model: last.model,
                                 sam: sam, settings: settings)
                DispatchQueue.main.async { self.busy = false; self.status = "Ready" }
            } catch {
                self.finish(with: error)
            }
        }
    }

    var canReprocess: Bool { lastBatch != nil && !busy && !watching }

    // MARK: - Saving

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    func saveAll() {
        guard !busy, unsavedCount > 0 else { return }
        busy = true
        status = "Saving…"
        let settings = snapshotSettings()
        var copy = photos
        workQueue.async {
            do {
                try self.save(&copy, settings: settings)
                DispatchQueue.main.async {
                    for saved in copy {
                        if let i = self.photos.firstIndex(where: { $0.id == saved.id }) {
                            self.photos[i].savedURL = saved.savedURL
                        }
                    }
                    self.busy = false
                    self.status = "Saved to \(settings.outDir.path)"
                }
            } catch {
                self.finish(with: error)
            }
        }
    }

    // MARK: - Background helpers (workQueue / watch thread only)

    private struct Settings {
        var resolution: Int
        var grayscale: Bool
        var crop: CropStrategy
        var useSAM: Bool
        var autoRotate: Bool
        var metadata: ImageMetadata
        var outDir: URL
        var autoSave: Bool
        var baseName: String
        var album: AlbumInfo
    }

    private func snapshotSettings() -> Settings {
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
                        useSAM: useSAM, autoRotate: autoRotate, metadata: metadata,
                        outDir: outputDirectory, autoSave: autoSave,
                        baseName: base.isEmpty ? "scan" : base,
                        album: album)
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }

    private func finish(with error: Error) {
        DispatchQueue.main.async {
            self.busy = false
            self.status = "Ready"
            self.errorMessage = "\(error)"
        }
    }

    private func prepareSAM(_ settings: Settings) throws -> SAMDetector? {
        guard settings.useSAM, settings.crop == .auto || settings.crop == .photos else { return nil }
        if let sam { return sam }
        if !SAMDetector.modelsPresent() {
            try SAMDetector.downloadModels { self.setStatus($0) }
        }
        let sam = try SAMDetector()
        self.sam = sam
        return sam
    }

    private func scan(endpoint: NWEndpoint, settings: Settings) throws -> ([Data], Int) {
        let client = BrotherScanClient(endpoint: endpoint)
        defer { client.close() }
        try client.connect()
        let caps = try client.queryCapabilities(resolution: settings.resolution, mode: .color)
        setStatus("Scanning \(caps.widthMM)×\(caps.heightMM) mm at \(caps.resolutionX) dpi…")
        var lastReported = 0
        let pages = try client.scan(capabilities: caps, mode: .color) { page, bytes in
            if bytes - lastReported > 512 * 1024 {
                lastReported = bytes
                self.setStatus("Scanning… page \(page): \(bytes / 1024) KB")
            }
        }
        guard !pages.isEmpty else { throw ScanError.deviceError("scanner returned no data") }
        return (pages, caps.resolutionX)
    }

    private func process(pages: [Data], dpi: Int, model: String?, sam: SAMDetector?,
                         settings: Settings) throws {
        setStatus("Processing…")
        let batchID = UUID()
        var newPhotos: [PendingPhoto] = []
        for page in pages {
            for cropped in try extractImages(from: page, crop: settings.crop, sam: sam) {
                var image = cropped.image
                var method = cropped.method
                if settings.autoRotate, let o = detectUprightOrientation(image), o != .up {
                    image = rotated(image, o)
                    method += ", rotated \(degrees(o))°"
                }
                if settings.grayscale, let gray = convertToGrayscale(image) {
                    image = gray
                }
                let fullURL = sessionDir.appendingPathComponent("\(UUID().uuidString).png")
                try writePNG(image, to: fullURL)
                let thumbnail = downscaled(image, maxDim: 640) ?? image
                newPhotos.append(PendingPhoto(batch: batchID, thumbnail: thumbnail,
                                              fullResURL: fullURL,
                                              pixelWidth: image.width, pixelHeight: image.height,
                                              method: method, dpi: dpi, scannerModel: model))
            }
        }
        if settings.autoSave {
            try save(&newPhotos, settings: settings)
        }
        DispatchQueue.main.async {
            self.lastBatch = (batchID, pages, dpi, model)
            self.photos.append(contentsOf: newPhotos)
        }
    }

    /// Writes every unsaved photo as "<base>-N.jpg", numbering continuing
    /// from whatever already exists in the folder (same rule as the CLI),
    /// then records the album metadata alongside them.
    private func save(_ toSave: inout [PendingPhoto], settings: Settings) throws {
        try FileManager.default.createDirectory(at: settings.outDir,
                                                withIntermediateDirectories: true)
        var next = nextFreeIndex(in: settings.outDir, base: settings.baseName)
        var recorded: [String: FileOverride] = [:]
        for i in toSave.indices where toSave[i].savedURL == nil {
            guard var image = loadImage(toSave[i].fullResURL) else {
                throw PipelineError.decodeFailed
            }
            switch toSave[i].quarterTurns {
            case 1: image = rotated(image, .right)
            case 2: image = rotated(image, .down)
            case 3: image = rotated(image, .left)
            default: break
            }
            let url = settings.outDir.appendingPathComponent("\(settings.baseName)-\(next).jpg")
            var metadata = settings.metadata
            metadata.scannerModel = toSave[i].scannerModel
            metadata.dpi = toSave[i].dpi
            // Per-photo overrides win over the album values.
            var applied = FileOverride()
            if let date = ContentDate(toSave[i].dateOverride) {
                metadata.contentDate = date
                applied.dateTaken = toSave[i].dateOverride
            }
            if !toSave[i].captionOverride.isEmpty {
                metadata.description = toSave[i].captionOverride
                applied.description = toSave[i].captionOverride
            }
            try writeJPEG(image: image, metadata: metadata, to: url)
            if applied.dateTaken != nil || applied.description != nil {
                recorded[url.lastPathComponent] = applied
            }
            toSave[i].savedURL = url
            try? FileManager.default.removeItem(at: toSave[i].fullResURL)
            next += 1
        }

        // The album file: current album values, plus the per-file override
        // records accumulated across saves (earlier entries are kept).
        var album = settings.album
        let albumURL = settings.outDir.appendingPathComponent(Self.albumFileName)
        if let data = try? Data(contentsOf: albumURL),
           let existing = try? JSONDecoder().decode(AlbumInfo.self, from: data) {
            album.files = existing.files
        }
        if !recorded.isEmpty {
            album.files = (album.files ?? [:]).merging(recorded) { _, new in new }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(album) {
            try? data.write(to: albumURL)
        }
    }

    // MARK: - Image spill helpers

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PipelineError.encodeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PipelineError.encodeFailed(url.path)
        }
    }

    private func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func downscaled(_ image: CGImage, maxDim: Int) -> CGImage? {
        let scale = min(1.0, Double(maxDim) / Double(max(image.width, image.height)))
        guard scale < 1.0 else { return image }
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
