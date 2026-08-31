import Foundation
import Network

enum ScanError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case timeout(String)
    case protocolError(String)
    case deviceError(String)

    var description: String {
        switch self {
        case .connectionFailed(let s): return "connection failed: \(s)"
        case .timeout(let s): return "timed out: \(s)"
        case .protocolError(let s): return "protocol error: \(s)"
        case .deviceError(let s): return "device error: \(s)"
        }
    }
}

/// Synchronous wrapper around NWConnection so the protocol code reads top-to-bottom.
final class SyncConnection {
    private let connection: NWConnection
    private var buffer = Data()

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    func connect(timeout: TimeInterval) throws {
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: Error?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sem.signal()
            case .failed(let error):
                lock.lock(); failure = error; lock.unlock()
                sem.signal()
            default:
                break
            }
        }
        connection.start(queue: .global())
        guard sem.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            throw ScanError.timeout("connecting to scanner")
        }
        lock.lock(); defer { lock.unlock() }
        if let failure { throw ScanError.connectionFailed("\(failure)") }
    }

    func send(_ data: Data) throws {
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        connection.send(content: data, completion: .contentProcessed { error in
            failure = error
            sem.signal()
        })
        sem.wait()
        if let failure { throw ScanError.connectionFailed("send: \(failure)") }
    }

    /// Returns exactly `count` bytes, waiting up to `timeout` for each network read.
    func read(exactly count: Int, timeout: TimeInterval) throws -> Data {
        while buffer.count < count {
            try fill(timeout: timeout)
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    /// Returns the next `count` bytes without consuming them.
    func peek(count: Int, timeout: TimeInterval) throws -> Data {
        while buffer.count < count {
            try fill(timeout: timeout)
        }
        return Data(buffer.prefix(count))
    }

    /// Returns whatever is buffered, reading from the network once if empty.
    func readSome(timeout: TimeInterval) throws -> Data {
        if buffer.isEmpty {
            try fill(timeout: timeout)
        }
        let out = buffer
        buffer.removeAll()
        return out
    }

    private func fill(timeout: TimeInterval) throws {
        let sem = DispatchSemaphore(value: 0)
        var received: Data?
        var failure: Error?
        var closed = false
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            received = data
            failure = error
            closed = isComplete
            sem.signal()
        }
        guard sem.wait(timeout: .now() + timeout) == .success else {
            throw ScanError.timeout("waiting for scanner data")
        }
        if let failure { throw ScanError.connectionFailed("receive: \(failure)") }
        if let received { buffer.append(received) }
        if closed && received == nil {
            throw ScanError.protocolError("connection closed by scanner")
        }
    }

    func close() {
        connection.cancel()
    }
}

/// Wire scan modes for Brother protocol families 2/3/4.
/// "CGRAY" is, counter-intuitively, the 24-bit COLOR JPEG mode on these
/// devices (grayscale output is produced by converting locally — the
/// hardware gray modes use a run-length encoding we don't need).
enum ScanMode: String {
    case color = "CGRAY"
}

struct ScannerCapabilities {
    let resolutionX: Int
    let resolutionY: Int
    let widthMM: Int
    let widthPixels: Int
    let heightMM: Int
    let heightPixels: Int
}

/// Client for the Brother proprietary network scan protocol (TCP 54921,
/// the protocol behind the SANE `brscan` backends).
///
/// Wire format observed on an MFC-1910W:
///  - banner `+OK 200\r\n` on connect
///  - query  `ESC I \n R=x,y \n M=mode \n 0x80` -> `0x00 <len:2 LE> <csv> 0x00`
///  - scan   `ESC X \n R=.. M=.. C=JPEG .. A=l,t,r,b \n 0x80` -> stream of blocks:
///      0x64 <07 00 01 00 84> <counter:4> <len:2 LE> <jpeg payload>
///      0x82 <07 00 01 00 84> <00 00 00 00>            end of page
///      0x80                                            end of session
final class BrotherScanClient {
    private let endpoint: NWEndpoint
    private var conn: SyncConnection!
    private let readTimeout: TimeInterval = 120

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    /// Connects, retrying while the device answers "-NG" (busy: another scan
    /// app holds it, or it is still releasing the previous session).
    func connect(attempts: Int = 5) throws {
        for attempt in 1...attempts {
            conn = SyncConnection(endpoint: endpoint)
            try conn.connect(timeout: 10)
            let banner = try conn.readSome(timeout: 10)
            if banner.starts(with: Data("+OK".utf8)) {
                return
            }
            conn.close()
            guard banner.starts(with: Data("-NG".utf8)) else {
                throw ScanError.protocolError("unexpected banner: \(banner.hexPreview)")
            }
            if attempt == attempts {
                let reply = String(decoding: banner, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ScanError.deviceError("scanner is busy (\(reply)) — close any scan app and retry")
            }
            FileHandle.standardError.write(Data("scanner busy, retrying…\n".utf8))
            Thread.sleep(forTimeInterval: 3)
        }
    }

    func queryCapabilities(resolution: Int, mode: ScanMode) throws -> ScannerCapabilities {
        let cmd = "\u{1b}I\nR=\(resolution),\(resolution)\nM=\(mode.rawValue)\n\u{80}"
        try conn.send(Data(cmd.utf8))
        let header = try conn.read(exactly: 3, timeout: 30)
        guard header[0] == 0x00 else {
            throw ScanError.deviceError("query rejected: \(header.hexPreview)")
        }
        let length = Int(header[1]) | (Int(header[2]) << 8)
        let payload = try conn.read(exactly: length, timeout: 30)
        let csv = String(decoding: payload.prefix(while: { $0 != 0 }), as: UTF8.self)
        let parts = csv.split(separator: ",").compactMap { Int($0) }
        guard parts.count >= 7 else {
            throw ScanError.protocolError("bad capability reply: \(csv)")
        }
        return ScannerCapabilities(
            resolutionX: parts[0], resolutionY: parts[1],
            widthMM: parts[3], widthPixels: parts[4],
            heightMM: parts[5], heightPixels: parts[6])
    }

    /// Runs the scan and returns one JPEG per page (multiple pages when the ADF is loaded).
    func scan(capabilities caps: ScannerCapabilities, mode: ScanMode,
              onProgress: (Int, Int) -> Void) throws -> [Data] {
        let cmd = "\u{1b}X\nR=\(caps.resolutionX),\(caps.resolutionY)\nM=\(mode.rawValue)\n"
            + "C=JPEG\nJ=MID\nB=50\nN=50\n"
            + "A=0,0,\(caps.widthPixels),\(caps.heightPixels)\nD=SIN\n\u{80}"
        try conn.send(Data(cmd.utf8))

        var pages: [Data] = []
        var current = Data()
        var received = 0
        var pageJustEnded = false

        func finishPage() {
            if !current.isEmpty {
                pages.append(current)
                current = Data()
            }
        }

        while true {
            let type: UInt8
            if pageJustEnded {
                // After a page the device waits ~30 s for the host to either
                // request another page or cancel before it closes the session
                // on its own. Give an immediate follow-up a moment, then tell
                // it we are done (ESC R) — like the SANE backend does.
                pageJustEnded = false
                do {
                    type = try conn.read(exactly: 1, timeout: 2.5)[0]
                } catch let error as ScanError {
                    guard case .timeout = error else { throw error }
                    try? conn.send(Data([0x1b, 0x52])) // ESC R: cancel/finish
                    _ = try? conn.readSome(timeout: 1)
                    return pages
                }
            } else {
                type = try conn.read(exactly: 1, timeout: readTimeout)[0]
            }
            switch type {
            case 0x80: // end of session
                finishPage()
                return pages
            case 0x81, 0x82: // end of page (0x81: more pages follow, e.g. from the ADF)
                // On the MFC-1910W these carry a 9-byte tail starting 07 00;
                // consume it only when actually present.
                if (try? conn.peek(count: 2, timeout: 2.5)) == Data([0x07, 0x00]) {
                    _ = try conn.read(exactly: 9, timeout: readTimeout)
                }
                finishPage()
                pageJustEnded = true
            case 0x64: // JPEG data block
                let header = try conn.read(exactly: 11, timeout: readTimeout)
                let length = Int(header[9]) | (Int(header[10]) << 8)
                current.append(try conn.read(exactly: length, timeout: readTimeout))
                received += length
                onProgress(pages.count + 1, received)
            case 0x83, 0x86:
                throw ScanError.deviceError("scan was cancelled on the device")
            case 0xc2:
                throw ScanError.deviceError("no document in the feeder")
            case 0xc3:
                throw ScanError.deviceError("paper jam")
            case 0xc4:
                throw ScanError.deviceError("cover is open")
            case 0xc5, 0xc6:
                throw ScanError.deviceError("scanner reports a device error (0x\(String(type, radix: 16)))")
            case 0x2d: // '-' as in "-NG ..."
                let rest = try conn.readSome(timeout: 5)
                throw ScanError.deviceError("scanner refused: -\(String(decoding: rest, as: UTF8.self))")
            default:
                let rest = (try? conn.readSome(timeout: 2)) ?? Data()
                throw ScanError.protocolError(
                    "unknown block type 0x\(String(type, radix: 16)) followed by \(rest.hexPreview)")
            }
        }
    }

    func close() {
        conn.close()
    }
}

private extension Data {
    var hexPreview: String {
        prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
