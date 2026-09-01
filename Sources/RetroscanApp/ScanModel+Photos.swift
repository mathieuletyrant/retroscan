import CoreGraphics
import Foundation
import ImageIO
import RetroscanKit
import SwiftUI

// MARK: - Per-photo actions and the crop editor

extension ScanModel {
    /// Moves the photo's file to the Trash (the undo for a bad scan) and
    /// drops it from the grid and the album file.
    func delete(_ photo: AlbumPhoto) {
        photos.removeAll { $0.id == photo.id }
        try? FileManager.default.trashItem(at: photo.savedURL, resultingItemURL: nil)
        workQueue.async { self.removeAlbumRecord(for: photo.savedURL) }
        status = "Moved \(photo.savedURL.lastPathComponent) to the Trash"
    }

    /// 90° clockwise: the JPEG's own pixels are rotated and the file
    /// rewritten in place.
    func rotate(_ photo: AlbumPhoto) {
        guard !busy, let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        rewriteSavedInPlace(photo: photos[i], addTurn: true, settings: snapshotSettings())
    }

    /// Bindings into a photo's override fields for the per-photo popover.
    /// The values are committed to the JPEG when the popover closes.
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

    /// A crop is adjustable while the photo's source page is still in the
    /// cache; only Delete Original Scans drops pages.
    func canEditCrop(_ photo: AlbumPhoto) -> Bool {
        photo.sourceRect != nil && photo.pageIndex != nil && batches[photo.batch] != nil
    }

    /// Decodes the photo's source page for the crop editor sheet.
    func beginCropEdit(_ photo: AlbumPhoto) -> CropEditingContext? {
        guard canEditCrop(photo),
              let index = photo.pageIndex, let rect = photo.sourceRect else { return nil }
        let pageData: Data
        if let last = lastBatch, last.id == photo.batch, index < last.pages.count {
            pageData = last.pages[index]
        } else if let batch = batches[photo.batch], index < batch.pageNames.count,
                  let data = try? Data(contentsOf:
                      pendingDir.appendingPathComponent(batch.pageNames[index])) {
            pageData = data
        } else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(pageData as CFData, nil),
              let page = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CropEditingContext(id: photo.id, page: page, rect: rect)
    }

    /// Re-crops the photo from its source page with the adjusted rectangle,
    /// taken literally (no tightening); the photo's rotation is re-applied
    /// on top. The JPEG is rewritten in place and its album record updated.
    func applyCropEdit(photoID: UUID, page: CGImage, rect: CGRect) {
        guard let i = photos.firstIndex(where: { $0.id == photoID }) else { return }
        let bounded = rect.integral.intersection(
            CGRect(x: 0, y: 0, width: page.width, height: page.height))
        guard bounded.width >= 20, bounded.height >= 20,
              let image = page.cropping(to: bounded) else { return }
        rewriteSavedCrop(photo: photos[i], image: image, bounded: bounded,
                         settings: snapshotSettings())
    }

    /// Metadata for rewriting a photo: what save() would embed today, with
    /// the photo's own overrides on top.
    private func metadataForSaved(photo: AlbumPhoto, settings: Settings) -> ImageMetadata {
        var metadata = settings.metadata
        metadata.scannerModel = photo.scannerModel
        metadata.dpi = photo.dpi
        if let date = ContentDate(photo.dateOverride) { metadata.contentDate = date }
        if !photo.captionOverride.isEmpty { metadata.description = photo.captionOverride }
        return metadata
    }

    /// Crop edit: apply the photo's rotation to the fresh crop, re-embed
    /// the metadata, overwrite the JPEG, and record the new rectangle.
    private func rewriteSavedCrop(photo: AlbumPhoto, image: CGImage, bounded: CGRect,
                                  settings: Settings) {
        busy = true
        status = "Rewriting \(photo.savedURL.lastPathComponent)…"
        workQueue.async {
            do {
                var final = image
                switch photo.quarterTurns % 4 {
                case 1: final = rotated(final, .right)
                case 2: final = rotated(final, .down)
                case 3: final = rotated(final, .left)
                default: break
                }
                try writeJPEG(image: final,
                              metadata: self.metadataForSaved(photo: photo, settings: settings),
                              to: photo.savedURL)
                self.updateAlbumRecord(for: photo.savedURL, photo: photo, rect: bounded,
                                       turns: photo.quarterTurns, method: "manual")
                let thumbnail = downscaled(final, maxDim: 640) ?? final
                DispatchQueue.main.async {
                    if let i = self.photos.firstIndex(where: { $0.id == photo.id }) {
                        self.photos[i].thumbnail = thumbnail
                        self.photos[i].pixelWidth = final.width
                        self.photos[i].pixelHeight = final.height
                        self.photos[i].method = "manual"
                        self.photos[i].sourceRect = bounded
                    }
                    self.busy = false
                    self.status = "Rewrote \(photo.savedURL.lastPathComponent)"
                }
            } catch {
                self.finish(with: error)
            }
        }
    }

    /// Rewrites a photo from its own JPEG pixels — used by rotate and by
    /// metadata-override edits, so neither needs the source page (and a
    /// grayscale photo stays grayscale). One re-encode generation, invisible
    /// at our quality; the record keeps quarterTurns relative to the source
    /// page so a later crop edit still composes correctly.
    private func rewriteSavedInPlace(photo: AlbumPhoto, addTurn: Bool, settings: Settings) {
        busy = true
        status = "Rewriting \(photo.savedURL.lastPathComponent)…"
        let turns = photo.quarterTurns + (addTurn ? 1 : 0)
        workQueue.async {
            do {
                guard var image = loadImage(photo.savedURL) else {
                    throw PipelineError.decodeFailed
                }
                if addTurn { image = rotated(image, .right) }
                try writeJPEG(image: image,
                              metadata: self.metadataForSaved(photo: photo, settings: settings),
                              to: photo.savedURL)
                self.updateAlbumRecord(for: photo.savedURL, photo: photo, rect: photo.sourceRect,
                                       turns: turns, method: photo.method)
                let thumbnail = downscaled(image, maxDim: 640) ?? image
                DispatchQueue.main.async {
                    if let i = self.photos.firstIndex(where: { $0.id == photo.id }) {
                        self.photos[i].thumbnail = thumbnail
                        self.photos[i].pixelWidth = image.width
                        self.photos[i].pixelHeight = image.height
                        self.photos[i].quarterTurns = turns
                    }
                    self.busy = false
                    self.status = "Rewrote \(photo.savedURL.lastPathComponent)"
                }
            } catch {
                self.finish(with: error)
            }
        }
    }

    /// Called when the override popover closes with changed values:
    /// re-embeds the metadata into the JPEG right away.
    func commitOverrides(_ id: UUID) {
        guard !busy, let i = photos.firstIndex(where: { $0.id == id }) else { return }
        rewriteSavedInPlace(photo: photos[i], addTurn: false, settings: snapshotSettings())
    }

    /// Empties the grid. Files on disk and cached pages are untouched —
    /// open the album again to bring its photos back.
    func clearAll() {
        photos.removeAll()
        lastBatch = nil
        persistCache()
    }
}
