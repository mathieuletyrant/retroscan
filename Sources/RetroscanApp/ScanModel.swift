import AppKit
import CoreGraphics
import Foundation
import Network
import RetroscanKit
import SwiftUI

struct PendingPhoto: Identifiable {
    let id = UUID()
    let batch: UUID
    var image: CGImage
    var method: String
    let dpi: Int
    let scannerModel: String?
    var savedURL: URL?
}

/// UI state and orchestration. The kit's calls are all blocking, so scanner
/// and pipeline work runs on `workQueue` (or the watch thread); @Published
/// state is only touched on the main thread. A scan, a save and the watch
/// loop are mutually exclusive via `busy`/`watching`.
final class ScanModel: ObservableObject {
    // Scanner
    @Published var scanners: [DiscoveredScanner] = []
    @Published var selectedScanner: String?
    @Published var discovering = false

    // Scan settings
    @Published var resolution = 300
    @Published var grayscale = false
    @Published var crop: CropStrategy = .auto
    @Published var useSAM = false
    @Published var autoRotate = true
    @Published var quality = 0.92

    // Metadata
    @Published var title = ""
    @Published var caption = ""
    @Published var author = ""
    @Published var keywords = ""
    @Published var dateTaken = ""

    // Output
    @Published var outputDirectory: URL
    @Published var autoSave = false

    // Session
    @Published var photos: [PendingPhoto] = []
    @Published var busy = false
    @Published var watching = false
    @Published var status = "Ready"
    @Published var errorMessage: String?

    var dateTakenValid: Bool { dateTaken.isEmpty || ContentDate(dateTaken) != nil }
    var unsavedCount: Int { photos.filter { $0.savedURL == nil }.count }

    private let workQueue = DispatchQueue(label: "retroscan.work", qos: .userInitiated)
    private var listener: PushScanListener?
    private var sam: SAMDetector?
    private var lastBatch: (id: UUID, pages: [Data], dpi: Int, model: String?)?

    init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        outputDirectory = pictures.appendingPathComponent("Retroscan", isDirectory: true)
        refreshScanners()
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
    }

    /// 90° clockwise; only offered before saving, so preview and file agree.
    func rotate(_ photo: PendingPhoto) {
        guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        photos[i].image = rotated(photos[i].image, .right)
    }

    func clearAll() {
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
                    self.photos.removeAll { $0.batch == last.id && $0.savedURL == nil }
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
        return Settings(resolution: resolution, grayscale: grayscale, crop: crop,
                        useSAM: useSAM, autoRotate: autoRotate, metadata: metadata,
                        outDir: outputDirectory, autoSave: autoSave,
                        baseName: base.isEmpty ? "scan" : base)
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
                newPhotos.append(PendingPhoto(batch: batchID, image: image, method: method,
                                              dpi: dpi, scannerModel: model))
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
    /// from whatever already exists in the folder (same rule as the CLI).
    private func save(_ toSave: inout [PendingPhoto], settings: Settings) throws {
        try FileManager.default.createDirectory(at: settings.outDir,
                                                withIntermediateDirectories: true)
        var next = nextFreeIndex(in: settings.outDir, base: settings.baseName)
        for i in toSave.indices where toSave[i].savedURL == nil {
            let url = settings.outDir.appendingPathComponent("\(settings.baseName)-\(next).jpg")
            var metadata = settings.metadata
            metadata.scannerModel = toSave[i].scannerModel
            metadata.dpi = toSave[i].dpi
            try writeJPEG(image: toSave[i].image, metadata: metadata, to: url)
            toSave[i].savedURL = url
            next += 1
        }
    }
}
