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
        rewriteSaved(photo: photos[i], addTurn: true)
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
        rewriteSaved(photo: photos[i], crop: (image, bounded))
    }

    /// Metadata for rewriting a photo: what save() would embed today, with
    /// the photo's own overrides on top.
    func metadataForSaved(photo: AlbumPhoto, settings: Settings) -> ImageMetadata {
        var metadata = settings.metadata
        metadata.scannerModel = photo.scannerModel
        metadata.dpi = photo.dpi
        if let date = ContentDate(photo.dateOverride) { metadata.contentDate = date }
        if !photo.captionOverride.isEmpty { metadata.description = photo.captionOverride }
        return metadata
    }

    /// Rewrites a photo's JPEG in place: a fresh crop from the source page
    /// (crop editor), or the file's own pixels re-encoded with one more
    /// quarter turn (rotate) or new metadata (overrides, album edits).
    /// Reusing the saved pixels keeps a grayscale photo grayscale and costs
    /// one re-encode generation, invisible at our quality; the album record
    /// keeps quarterTurns relative to the source page so a later crop edit
    /// still composes correctly.
    private func rewriteSaved(photo: AlbumPhoto, crop: (image: CGImage, rect: CGRect)? = nil,
                              addTurn: Bool = false) {
        busy = true
        status = "Rewriting \(photo.savedURL.lastPathComponent)…"
        let settings = snapshotSettings()
        let turns = photo.quarterTurns + (addTurn ? 1 : 0)
        workQueue.async {
            do {
                let image: CGImage
                if let crop {
                    image = rotated(crop.image, quarterTurns: photo.quarterTurns)
                } else {
                    guard let saved = loadImage(photo.savedURL) else {
                        throw PipelineError.decodeFailed
                    }
                    image = addTurn ? rotated(saved, .right) : saved
                }
                try writeJPEG(image: image,
                              metadata: self.metadataForSaved(photo: photo, settings: settings),
                              to: photo.savedURL)
                self.updateAlbumRecord(for: photo.savedURL, photo: photo,
                                       rect: crop?.rect ?? photo.sourceRect, turns: turns,
                                       method: crop == nil ? photo.method : "manual")
                let thumbnail = downscaled(image, maxDim: 640) ?? image
                DispatchQueue.main.async {
                    if let i = self.photos.firstIndex(where: { $0.id == photo.id }) {
                        self.photos[i].thumbnail = thumbnail
                        self.photos[i].pixelWidth = image.width
                        self.photos[i].pixelHeight = image.height
                        self.photos[i].quarterTurns = turns
                        if let crop {
                            self.photos[i].method = "manual"
                            self.photos[i].sourceRect = crop.rect
                        }
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
        rewriteSaved(photo: photos[i])
    }

    /// Empties the grid. Files on disk and cached pages are untouched —
    /// open the album again to bring its photos back.
    func clearAll() {
        photos.removeAll()
        lastBatch = nil
        persistCache()
    }
}
