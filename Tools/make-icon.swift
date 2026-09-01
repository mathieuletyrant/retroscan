// Draws the app icon (a retro photo print under the scanner's light bar)
// and emits the AppIcon.iconset PNGs. Regenerate the icns with:
//
//   swift Tools/make-icon.swift <iconset dir>
//   iconutil -c icns <iconset dir> -o Sources/RetroscanApp/AppIcon.icns

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: colors as CFArray, locations: nil)!
}

func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    // Big Sur-style canvas: the plate fills ~80% of the square, the rest is
    // transparent margin so the Dock renders it at the same optical size as
    // every other icon.
    let margin = 0.098 * s
    let plate = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = 0.225 * plate.width
    let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Plate: deep blue-gray vertical gradient (scanner-lid dark).
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([rgb(0.23, 0.37, 0.51), rgb(0.08, 0.15, 0.24)]),
        start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // The photo print, slightly askew like a print dropped on the glass.
    ctx.saveGState()
    ctx.translateBy(x: 0.5 * s, y: 0.485 * s)
    ctx.rotate(by: -7 * .pi / 180)
    let pw = 0.56 * s, ph = 0.43 * s
    let photo = CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph)

    ctx.setShadow(offset: CGSize(width: 0, height: -0.012 * s), blur: 0.035 * s,
                  color: rgb(0, 0, 0, 0.45))
    ctx.setFillColor(rgb(0.98, 0.97, 0.94))
    ctx.fill(photo)
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Inside the paper border: a sunset — sky, sun, sea, a headland.
    let border = 0.032 * s
    let inner = photo.insetBy(dx: border, dy: border)
    ctx.saveGState()
    ctx.clip(to: inner)
    ctx.drawLinearGradient(
        gradient([rgb(0.99, 0.83, 0.49), rgb(0.93, 0.49, 0.30)]),
        start: CGPoint(x: 0, y: inner.maxY), end: CGPoint(x: 0, y: inner.minY), options: [])

    let seaTop = inner.minY + 0.32 * inner.height
    let sun = CGPoint(x: inner.minX + 0.38 * inner.width, y: seaTop + 0.38 * inner.height)
    let sunR = 0.085 * inner.width
    ctx.setFillColor(rgb(1.0, 0.95, 0.78))
    ctx.fillEllipse(in: CGRect(x: sun.x - sunR, y: sun.y - sunR, width: 2 * sunR, height: 2 * sunR))

    ctx.setFillColor(rgb(0.16, 0.34, 0.44))
    ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: seaTop - inner.minY))
    // Sun glint on the water: a few fading ripples under the sun.
    let seaHeight = seaTop - inner.minY
    for (i, alpha) in [0.5, 0.35, 0.2].enumerated() {
        let rippleW = (0.9 - 0.2 * CGFloat(i)) * sunR
        ctx.setFillColor(rgb(1.0, 0.85, 0.60, alpha))
        ctx.fill(CGRect(x: sun.x - rippleW / 2,
                        y: seaTop - (0.28 + 0.24 * CGFloat(i)) * seaHeight,
                        width: rippleW, height: 0.10 * seaHeight))
    }

    // Headland silhouette on the right.
    ctx.setFillColor(rgb(0.30, 0.20, 0.28))
    ctx.move(to: CGPoint(x: inner.maxX, y: seaTop))
    ctx.addLine(to: CGPoint(x: inner.maxX, y: seaTop + 0.30 * inner.height))
    ctx.addLine(to: CGPoint(x: inner.maxX - 0.38 * inner.width, y: seaTop))
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState() // inner clip
    ctx.restoreGState() // photo rotation

    // The scanner's light bar sweeping across the plate (and the print).
    let beamY = 0.53 * s
    let glows: [(height: CGFloat, alpha: CGFloat)] = [(0.085, 0.16), (0.036, 0.32), (0.010, 0.90)]
    for glow in glows {
        ctx.setFillColor(rgb(0.55, 1.0, 0.80, glow.alpha))
        ctx.fill(CGRect(x: plate.minX, y: beamY - glow.height * s / 2,
                        width: plate.width, height: glow.height * s))
    }
    ctx.restoreGState() // plate clip
}

func render(_ pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(ctx, CGFloat(pixels))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    render(points, to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    render(points * 2, to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("iconset written to \(out.path)")
