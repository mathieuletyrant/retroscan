import CoreGraphics
import Foundation
import ImageIO
import Network
import RetroscanKit

// MARK: - Talking to the scanner: discovery, scan, watch, crop pipeline

extension ScanModel {
    // MARK: Discovery

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

    // MARK: One-shot scan

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
                let (pages, dpi) = try self.scan(endpoint: endpoint, settings: settings)
                try self.process(pages: pages, dpi: dpi, model: modelName, settings: settings)
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
                try self.process(pages: [data], dpi: settings.resolution, model: nil,
                                 settings: settings)
                DispatchQueue.main.async { self.busy = false; self.status = "Ready" }
            } catch {
                self.finish(with: error)
            }
        }
    }

    // MARK: Watch mode (printer's Scan button)

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
                        // Hop to workQueue so file writes (JPEGs, album
                        // JSON) never race a rewrite running there.
                        try self.workQueue.sync {
                            try self.process(pages: pages, dpi: dpi, model: modelName,
                                             settings: settings)
                        }
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

    // MARK: Re-process

    /// Re-runs crop/rotate with the current settings on the last scan's raw
    /// pages — no need to rescan to try other settings. The batch's existing
    /// files move to the Trash and fresh ones are written.
    func reprocessLastScan() {
        guard !busy, !watching, let last = lastBatch else { return }
        busy = true
        let settings = snapshotSettings()
        let dropped = photos.filter { $0.batch == last.id }
        photos.removeAll { $0.batch == last.id }
        workQueue.async {
            do {
                for photo in dropped {
                    try? FileManager.default.trashItem(at: photo.savedURL,
                                                       resultingItemURL: nil)
                    self.removeAlbumRecord(for: photo.savedURL)
                }
                try self.process(pages: last.pages, dpi: last.dpi, model: last.model,
                                 settings: settings,
                                 existingBatch: (last.id, last.pageURLs))
                DispatchQueue.main.async { self.busy = false; self.status = "Ready" }
            } catch {
                self.finish(with: error)
            }
        }
    }

    var canReprocess: Bool { lastBatch != nil && !busy && !watching }

    // MARK: Pipeline (workQueue / watch thread only)

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

    private func process(pages: [Data], dpi: Int, model: String?,
                         settings: Settings,
                         existingBatch: (id: UUID, pageURLs: [URL])? = nil) throws {
        setStatus("Processing…")
        let batchID = existingBatch?.id ?? UUID()
        var items: [ProcessedImage] = []
        for (pageIndex, page) in pages.enumerated() {
            for cropped in try extractImages(from: page, splitPhotos: settings.splitPhotos) {
                var image = cropped.image
                var method = cropped.method
                // Rotation is baked into the saved JPEG at write time;
                // quarterTurns is recorded relative to the source page so a
                // later re-crop from that page composes with it.
                var turns = 0
                if settings.autoRotate, let o = detectUprightOrientation(image), o != .up {
                    turns = degrees(o) / 90
                    method += ", rotated \(degrees(o))°"
                }
                if settings.grayscale, let gray = convertToGrayscale(image) {
                    image = gray
                }
                let thumbnail = rotated(downscaled(image, maxDim: 640) ?? image,
                                        quarterTurns: turns)
                items.append(ProcessedImage(image: image, thumbnail: thumbnail,
                                            quarterTurns: turns, method: method,
                                            pageIndex: pageIndex,
                                            sourceRect: cropped.sourceRect))
            }
        }
        // Straight to disk: every photo is saved (and recorded in the album
        // file) the moment it exists.
        let newPhotos = try save(items, batch: batchID, dpi: dpi, model: model,
                                 settings: settings)
        // The raw pages go to the cache too (once per batch — Re-process
        // reuses the existing files), so crops stay editable.
        var pageURLs: [URL] = existingBatch?.pageURLs ?? []
        if pageURLs.isEmpty {
            for (n, page) in pages.enumerated() {
                let url = pendingDir.appendingPathComponent("\(batchID.uuidString)-p\(n).jpg")
                try? page.write(to: url)
                pageURLs.append(url)
            }
        }
        DispatchQueue.main.async {
            self.lastBatch = (batchID, pages, pageURLs, dpi, model)
            self.batches[batchID] = CacheManifest.Batch(
                id: batchID, pageNames: pageURLs.map(\.lastPathComponent),
                dpi: dpi, model: model)
            self.photos.append(contentsOf: newPhotos)
            self.persistCache()
        }
    }
}
