import Foundation
import Network
import RetroscanKit

let usage = """
retroscan — scan from a Brother network scanner, auto-crop, tag metadata.

USAGE: retroscan [watch] [options]

WATCH MODE
  retroscan watch …      Register on the device's "Scan to PC" menu and wait:
                         each press of the printer's Scan button triggers a
                         scan with the given options. Numbering with --title
                         continues across presses — ideal for whole albums.

SCANNER
  --list                 List scanners found on the network and exit
  --device <substring>   Pick the scanner whose Bonjour name contains this
  --host <host[:port]>   Skip discovery, connect directly (default port 54921)

SCAN
  -r, --resolution <dpi> 100 | 150 | 200 | 300 | 600      (default: 300)
  -m, --mode <mode>      color | gray                     (default: color)
  -i, --input <file>     Skip the scanner: run the crop/rotate/metadata
                         pipeline on an existing scan JPEG instead

OUTPUT
  -o, --out <dir>        Output directory                 (default: current dir)
  -n, --name <base>      Base filename; files come out as <base>-1.jpg,
                         <base>-2.jpg, … and numbering continues across runs.
                         Defaults to the --title if given, else scan-<timestamp>
  -q, --quality <0-1>    JPEG quality                     (default: 0.92)

CROP
  -c, --crop <strategy>  auto | document | photos | trim | none   (default: auto)
                         auto: several photos on the bed -> one file each;
                         single document -> perspective crop; else trim borders
                         photos: always split into per-photo files

ROTATION
  -R, --rotate <mode>    auto | none | 90 | 180 | 270     (default: auto)
                         auto: face detection puts photos upright (photos
                         without faces are left as scanned); 90/180/270
                         rotate everything clockwise by that amount

METADATA (always embeds scan date, scanner model, DPI)
  -t, --title <text>
  -d, --description <text>
  -a, --author <text>
  -k, --keywords <a,b,c>
  -D, --date <when>      When the photo was taken: 1995, 1995-07 or 1995-07-14
                         (EXIF DateTimeOriginal — what photo apps sort by)

EXAMPLES
  retroscan
  retroscan -r 600 -m gray -t "Facture EDF" -k facture,edf,2026 -o ~/Documents/Scans
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("retroscan: \(message)\n".utf8))
    exit(1)
}

// MARK: - Argument parsing

struct Options {
    var watch = false
    var list = false
    var device: String?
    var host: String?
    var input: String?
    var resolution = 300
    var grayscale = false
    var outDir = FileManager.default.currentDirectoryPath
    var baseName: String?
    var crop = CropStrategy.auto
    var rotate = RotateOption.auto
    var quality = 0.92
    var title: String?
    var description: String?
    var author: String?
    var keywords: [String] = []
    var contentDate: ContentDate?
}

func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    func value(for flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) requires a value") }
        return args.removeFirst()
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-h", "--help": print(usage); exit(0)
        case "watch", "--watch": opts.watch = true
        case "--list": opts.list = true
        case "--device": opts.device = value(for: arg)
        case "--host": opts.host = value(for: arg)
        case "-i", "--input": opts.input = (value(for: arg) as NSString).expandingTildeInPath
        case "-r", "--resolution":
            guard let r = Int(value(for: arg)), [100, 150, 200, 300, 600].contains(r) else {
                fail("resolution must be one of 100, 150, 200, 300, 600")
            }
            opts.resolution = r
        case "-m", "--mode":
            switch value(for: arg) {
            case "color", "colour": opts.grayscale = false
            case "gray", "grey": opts.grayscale = true
            default: fail("mode must be color or gray")
            }
        case "-o", "--out": opts.outDir = (value(for: arg) as NSString).expandingTildeInPath
        case "-n", "--name": opts.baseName = value(for: arg)
        case "-q", "--quality":
            guard let q = Double(value(for: arg)), q > 0, q <= 1 else {
                fail("quality must be in (0, 1]")
            }
            opts.quality = q
        case "-c", "--crop":
            guard let c = CropStrategy(rawValue: value(for: arg)) else {
                fail("crop must be auto, document, photos, trim or none")
            }
            opts.crop = c
        case "-R", "--rotate":
            switch value(for: arg) {
            case "auto": opts.rotate = .auto
            case "none": opts.rotate = .none
            case "90": opts.rotate = .fixed(.right)
            case "180": opts.rotate = .fixed(.down)
            case "270": opts.rotate = .fixed(.left)
            default: fail("rotate must be auto, none, 90, 180 or 270")
            }
        case "-t", "--title": opts.title = value(for: arg)
        case "-d", "--description": opts.description = value(for: arg)
        case "-a", "--author": opts.author = value(for: arg)
        case "-D", "--date":
            let text = value(for: arg)
            guard let date = ContentDate(text) else {
                fail("date must look like 1995, 1995-07 or 1995-07-14 (got \"\(text)\")")
            }
            opts.contentDate = date
        case "-k", "--keywords":
            opts.keywords = value(for: arg).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        default:
            fail("unknown option \(arg) (see --help)")
        }
    }
    return opts
}

// MARK: - Main

let opts = parseOptions()

/// Reads the pages either from an existing file (--input) or from the scanner.
func acquirePages() -> (pages: [Data], dpi: Int, modelName: String?) {
    if let input = opts.input {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: input)) else {
            fail("cannot read \(input)")
        }
        print("Processing \(input)…")
        return ([data], opts.resolution, nil)
    }
    let (endpoint, modelName) = resolveScanner()
    do {
        return try scanFromScanner(endpoint: endpoint, modelName: modelName)
    } catch {
        fail("\(error)")
    }
}

func scanFromScanner(endpoint: NWEndpoint, modelName: String?) throws
    -> (pages: [Data], dpi: Int, modelName: String?) {
    let client = BrotherScanClient(endpoint: endpoint)
    defer { client.close() }
    try client.connect()
    let caps = try client.queryCapabilities(resolution: opts.resolution, mode: .color)
    print("Scanning \(caps.widthMM)×\(caps.heightMM) mm at \(caps.resolutionX) dpi (\(opts.grayscale ? "gray" : "color"))…")

    var lastReported = 0
    let pages = try client.scan(capabilities: caps, mode: .color) { page, bytes in
        if bytes - lastReported > 512 * 1024 {
            lastReported = bytes
            print("  page \(page): \(bytes / 1024) KB…")
        }
    }
    guard !pages.isEmpty else {
        throw ScanError.deviceError("scanner returned no data")
    }
    return (pages, caps.resolutionX, modelName)
}

func resolveScanner() -> (NWEndpoint, String?) {
    if let host = opts.host {
        let parts = host.split(separator: ":")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 54921 : 54921
        return (.hostPort(host: NWEndpoint.Host(String(parts[0])),
                          port: NWEndpoint.Port(rawValue: port)!), nil)
    }
    print("Searching for scanners…")
    let scanners = discoverScanners()
    if opts.list {
        if scanners.isEmpty { print("No scanner found.") }
        for s in scanners { print("  \(s.name)") }
        exit(0)
    }
    guard !scanners.isEmpty else {
        fail("no scanner found on the network (try --host)")
    }
    let chosen: DiscoveredScanner
    if let filter = opts.device {
        guard let match = scanners.first(where: { $0.name.localizedCaseInsensitiveContains(filter) }) else {
            fail("no scanner matching \"\(filter)\" (found: \(scanners.map(\.name).joined(separator: ", ")))")
        }
        chosen = match
    } else {
        chosen = scanners[0]
    }
    print("Using \(chosen.name)")
    return (chosen.endpoint, chosen.name)
}

func processAndSave(pages: [Data], dpi: Int, modelName: String?) throws {
    let dirURL = URL(fileURLWithPath: opts.outDir, isDirectory: true)
    try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

    let metadata = ImageMetadata(
        title: opts.title, description: opts.description, author: opts.author,
        keywords: opts.keywords, contentDate: opts.contentDate, scannerModel: modelName,
        dpi: dpi, jpegQuality: opts.quality)

    var images: [CroppedImage] = []
    for jpeg in pages {
        images.append(contentsOf: try extractImages(from: jpeg, crop: opts.crop))
    }

    // With --name or --title the files are "<base>-1.jpg", "<base>-2.jpg", …
    // and the numbering continues where a previous run left off, so batch
    // sessions (scan, swap photos on the glass, scan again) never collide.
    // Without either, each run gets a unique timestamped base.
    let urls: [URL]
    if let stable = opts.baseName ?? opts.title.map(sanitizeForFilename), !stable.isEmpty {
        var next = nextFreeIndex(in: dirURL, base: stable)
        urls = images.map { _ in
            defer { next += 1 }
            return dirURL.appendingPathComponent("\(stable)-\(next).jpg")
        }
    } else {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let base = "scan-\(f.string(from: Date()))"
        urls = images.indices.map { i in
            let suffix = images.count > 1 ? "-\(i + 1)" : ""
            return dirURL.appendingPathComponent("\(base)\(suffix).jpg")
        }
    }

    for (cropped, url) in zip(images, urls) {
        var final = cropped.image
        var rotationNote = ""
        switch opts.rotate {
        case .auto:
            if let orientation = detectUprightOrientation(final), orientation != .up {
                final = rotated(final, orientation)
                rotationNote = ", rotated \(degrees(orientation))°"
            }
        case .fixed(let orientation):
            final = rotated(final, orientation)
            rotationNote = ", rotated \(degrees(orientation))°"
        case .none:
            break
        }
        if opts.grayscale, let gray = convertToGrayscale(final) {
            final = gray
        }
        try writeJPEG(image: final, metadata: metadata, to: url)

        let sizeText = fileSize(url).map { "\($0 / 1024) KB" } ?? "?"
        print("✓ \(url.path)  \(final.width)×\(final.height) px, \(sizeText), crop: \(cropped.method)\(rotationNote)")
    }
}

// MARK: - Entry point

setlinebuf(stdout) // keep progress lines live when output is piped or logged

if opts.watch {
    guard opts.input == nil else { fail("--input cannot be combined with watch") }
    let (endpoint, modelName) = resolveScanner()
    let printerIP: String, localIP: String
    do {
        (printerIP, localIP) = try resolveAddresses(endpoint: endpoint)
    } catch {
        fail("\(error)")
    }
    let listener = PushScanListener(printerHost: printerIP, localIP: localIP,
                                    displayName: "retroscan")
    do {
        try listener.start()
    } catch {
        fail("\(error)")
    }
    print("Registered on \(modelName ?? printerIP) as \"retroscan\".")
    print("Press the device's Scan button > Scan to PC > Image and confirm. Ctrl+C to quit.")
    while true {
        do {
            try listener.waitForButton()
            print("Scan button pressed…")
            let (pages, dpi, model) = try scanFromScanner(endpoint: endpoint, modelName: modelName)
            try processAndSave(pages: pages, dpi: dpi, modelName: model)
            print("Ready for the next press.")
        } catch {
            FileHandle.standardError.write(Data("retroscan: \(error) — still watching\n".utf8))
            Thread.sleep(forTimeInterval: 3)
        }
    }
} else {
    let (pages, dpi, modelName) = acquirePages()
    do {
        try processAndSave(pages: pages, dpi: dpi, modelName: modelName)
    } catch {
        fail("\(error)")
    }
}
