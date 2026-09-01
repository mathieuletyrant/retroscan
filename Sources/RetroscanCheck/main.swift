import CoreGraphics
import Foundation
import RetroscanKit

// Self-check for the pixel-analysis path: background estimation, region
// flood fill, quarter-turn rotation, filename helpers. Synthetic pages, so
// a broken threshold or visited-set shows up as a wrong region count.
// Run with: make check   (or: swift run retroscan-check)

var failures = 0

func check(_ what: String, _ ok: Bool) {
    print("\(ok ? "✓" : "✗") \(what)")
    if !ok { failures += 1 }
}

/// A page of `background` grey with two `foreground` rectangles on it,
/// as JPEG bytes — what extractImages consumes.
func page(background: UInt8, foreground: UInt8) -> Data {
    let (w, h) = (1200, 800)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func fill(_ level: UInt8, _ rect: CGRect) {
        let v = CGFloat(level) / 255
        ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
        ctx.fill(rect)
    }
    fill(background, CGRect(x: 0, y: 0, width: w, height: h))
    fill(foreground, CGRect(x: 80, y: 80, width: 380, height: 620))
    fill(foreground, CGRect(x: 700, y: 80, width: 380, height: 620))

    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("retroscan-check-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    try! writeJPEG(image: ctx.makeImage()!, metadata: ImageMetadata(), to: url)
    return try! Data(contentsOf: url)
}

func regionCount(background: UInt8, foreground: UInt8) -> Int {
    (try? extractImages(from: page(background: background, foreground: foreground),
                        splitPhotos: true))?.count ?? 0
}

// Bare white bed, then a dark backing sheet: both must yield two photos.
// The dark case only works if the background estimate follows the backing.
check("two photos on a white bed", regionCount(background: 255, foreground: 90) == 2)
check("two photos on dark backing", regionCount(background: 40, foreground: 200) == 2)
check("no-crop keeps the page whole",
      (try? extractImages(from: page(background: 255, foreground: 90),
                          splitPhotos: false))?.count == 1)

let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let landscape = ctx.makeImage()!
check("odd quarter turns swap the sides", [0, 1, 2, 3, 4, 5].allSatisfy { turns in
    let out = rotated(landscape, quarterTurns: turns)
    return turns % 2 == 0 ? (out.width, out.height) == (40, 20)
                          : (out.width, out.height) == (20, 40)
})

check("filename sanitising", sanitizeForFilename("  Holidays 7/95: Nice  ") == "Holidays 7-95- Nice")
func ymd(_ text: String) -> [Int]? {
    ContentDate(text).map { [$0.year, $0.month, $0.day] }
}
check("date parsing", ymd("nope") == nil && ymd("1995-13") == nil
    && ymd("1995") == [1995, 1, 1] && ymd("1995/07/14") == [1995, 7, 14])

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let firstFree = nextFreeIndex(in: dir, base: "scan")
for n in [1, 2, 7] { try! Data().write(to: dir.appendingPathComponent("scan-\(n).jpg")) }
check("numbering continues past existing files",
      firstFree == 1 && nextFreeIndex(in: dir, base: "scan") == 8)

if failures > 0 {
    FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
    exit(1)
}
print("all checks passed")
