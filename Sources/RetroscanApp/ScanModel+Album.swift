import CoreGraphics
import Foundation
import RetroscanKit

// MARK: - The album file (the output folder as a reopenable project)

extension ScanModel {
    struct AlbumInfo: Codable {
        var title: String?
        var description: String?
        var author: String?
        var keywords: String?
        var dateTaken: String?
        /// Per-file record of every photo saved to this folder, keyed by
        /// filename: the overrides embedded at save time (the JPEG's own
        /// EXIF/IPTC stays the source of truth) plus a reference to the
        /// cached source page — what turns the folder into a reopenable
        /// project with adjustable crops.
        var files: [String: FileRecord]?
    }

    struct FileRecord: Codable {
        var dateTaken: String?
        var description: String?
        // Where the photo came from — enough to reopen the crop editor for
        // as long as the batch's raw pages are still in the cache.
        var batch: UUID?
        var pageIndex: Int?
        var sourceRect: [Double]?
        var quarterTurns: Int?
        var dpi: Int?
        var scannerModel: String?
        var method: String?
    }

    static let albumFileName = ".retroscan.json"

    /// Fills the metadata fields from the folder's album file and reloads
    /// its saved photos into the grid; a folder without one starts a fresh
    /// album (author, an app-level preference, is kept).
    func loadAlbumInfo(from dir: URL) {
        // The grid always mirrors the current folder.
        photos.removeAll()
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
        restoreAlbumPhotos(from: dir, files: info.files ?? [:])
    }

    /// Rebuilds grid entries for the album's saved files (thumbnails decode
    /// off the main thread). Whether a restored photo's crop is editable is
    /// decided at render time by `canEditCrop`, from whatever source pages
    /// the cache still holds.
    private func restoreAlbumPhotos(from dir: URL, files: [String: FileRecord]) {
        guard !files.isEmpty else { return }
        let names = files.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        workQueue.async {
            var restored: [AlbumPhoto] = []
            for name in names {
                guard let record = files[name] else { continue }
                let url = dir.appendingPathComponent(name)
                guard let thumbnail = loadThumbnail(url, maxDim: 640),
                      let (width, height) = imageDimensions(url) else { continue }
                restored.append(AlbumPhoto(
                    batch: record.batch ?? UUID(),
                    thumbnail: thumbnail,
                    quarterTurns: record.quarterTurns ?? 0,
                    dateOverride: record.dateTaken ?? "",
                    captionOverride: record.description ?? "",
                    pixelWidth: width, pixelHeight: height,
                    method: record.method ?? "saved",
                    dpi: record.dpi ?? 300,
                    scannerModel: record.scannerModel,
                    savedURL: url,
                    pageIndex: record.pageIndex,
                    sourceRect: Self.rect(from: record.sourceRect)))
            }
            DispatchQueue.main.async {
                // The folder may have changed again while thumbnails loaded.
                guard self.outputDirectory == dir, !restored.isEmpty else { return }
                self.photos.removeAll { photo in
                    restored.contains { $0.savedURL == photo.savedURL }
                }
                self.photos.insert(contentsOf: restored, at: 0)
                self.status = "Album “\(dir.lastPathComponent)”: loaded \(restored.count) photo\(restored.count > 1 ? "s" : "")"
            }
        }
    }

    /// Updates one file's record in its folder's album JSON after an
    /// in-place rewrite (crop, rotation, or metadata overrides). Runs on
    /// workQueue, serialized with save().
    func updateAlbumRecord(for savedURL: URL, photo: AlbumPhoto, rect: CGRect?,
                           turns: Int, method: String) {
        mutateAlbumInfo(next(to: savedURL)) { info in
            var record = info.files?[savedURL.lastPathComponent] ?? FileRecord()
            record.dateTaken = ContentDate(photo.dateOverride) != nil ? photo.dateOverride : nil
            record.description = photo.captionOverride.isEmpty ? nil : photo.captionOverride
            if let rect { record.sourceRect = Self.array(from: rect) }
            record.quarterTurns = turns
            record.method = method
            var files = info.files ?? [:]
            files[savedURL.lastPathComponent] = record
            info.files = files
        }
    }

    /// Drops one file's record after its file left the album (workQueue).
    func removeAlbumRecord(for savedURL: URL) {
        mutateAlbumInfo(next(to: savedURL)) { info in
            info.files?.removeValue(forKey: savedURL.lastPathComponent)
        }
    }

    private func next(to savedURL: URL) -> URL {
        savedURL.deletingLastPathComponent().appendingPathComponent(Self.albumFileName)
    }

    private func mutateAlbumInfo(_ albumURL: URL, _ mutate: (inout AlbumInfo) -> Void) {
        guard let data = try? Data(contentsOf: albumURL),
              var info = try? JSONDecoder().decode(AlbumInfo.self, from: data) else { return }
        mutate(&info)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let out = try? encoder.encode(info) {
            try? out.write(to: albumURL)
        }
    }
}
