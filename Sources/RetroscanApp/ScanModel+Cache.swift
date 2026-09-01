import CoreGraphics
import Foundation
import RetroscanKit

// MARK: - The original-scans cache (raw pages, kept across launches)

extension ScanModel {
    /// What survives a relaunch: which raw pages belong to which batch.
    /// (Old manifests carried the unsaved session's photos too; that extra
    /// key is simply ignored now that every photo saves immediately.)
    struct CacheManifest: Codable {
        struct Batch: Codable {
            var id: UUID
            var pageNames: [String]
            var dpi: Int
            var model: String?
        }
        var batches: [Batch]?
        var lastBatchID: UUID?
    }

    private var manifestURL: URL { pendingDir.appendingPathComponent("manifest.json") }

    /// Rewrites the manifest after any mutation of the batch set. The page
    /// files themselves are already on disk (written at process time).
    func persistCache() {
        let manifest = CacheManifest(batches: Array(batches.values),
                                     lastBatchID: lastBatch?.id)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
        updateCacheSize()
    }

    /// Reloads the batch set from the manifest, revives the last batch for
    /// Re-process, and sweeps anything the manifest doesn't reference
    /// (leftovers of older versions or interrupted runs).
    func restoreCache() {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CacheManifest.self, from: data) else {
            return
        }
        var referenced: Set<String> = ["manifest.json"]
        for batch in manifest.batches ?? [] {
            let present = batch.pageNames.allSatisfy {
                FileManager.default.fileExists(atPath: pendingDir.appendingPathComponent($0).path)
            }
            guard present, !batch.pageNames.isEmpty else { continue }
            batches[batch.id] = batch
            batch.pageNames.forEach { referenced.insert($0) }
        }
        if let lastID = manifest.lastBatchID, let batch = batches[lastID] {
            let urls = batch.pageNames.map { pendingDir.appendingPathComponent($0) }
            let pages = urls.compactMap { try? Data(contentsOf: $0) }
            if pages.count == urls.count {
                lastBatch = (batch.id, pages, urls, batch.dpi, batch.model)
            }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: pendingDir.path)) ?? []
        for entry in entries where !referenced.contains(entry) {
            try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent(entry))
        }
        updateCacheSize()
    }

    static func array(from rect: CGRect?) -> [Double]? {
        rect.map { [$0.minX, $0.minY, $0.width, $0.height] }
    }

    static func rect(from array: [Double]?) -> CGRect? {
        guard let a = array, a.count == 4 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    // MARK: Size and cleanup

    var cacheSizeText: String {
        ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func updateCacheSize() {
        cacheBytes = batches.values.flatMap(\.pageNames).reduce(Int64(0)) { total, name in
            total + (fileSize(pendingDir.appendingPathComponent(name)) ?? 0)
        }
    }

    /// Deletes every cached original page. Photos keep their current pixels
    /// and files — but no crop can be re-adjusted (and Re-process is gone)
    /// until the next scan.
    func deleteOriginalScans() {
        for batch in batches.values {
            for name in batch.pageNames {
                try? FileManager.default.removeItem(at: pendingDir.appendingPathComponent(name))
            }
        }
        batches.removeAll()
        lastBatch = nil
        persistCache()
        status = "Original scans deleted"
    }
}
