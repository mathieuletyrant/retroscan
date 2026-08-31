import Foundation

/// "Scan to PC" button support (Brother's brscan-skey protocol).
///
/// The host registers itself with the device via an SNMPv1 SET (community
/// "internal", Brother enterprise OID) carrying a text record; the device
/// then lists the host in its Scan > Scan to PC menu, and when the user
/// picks it, sends a UDP datagram to the advertised host:port. Registration
/// expires (DURATION) and is refreshed every minute.
final class PushScanListener {
    private let printerHost: String
    private let localIP: String
    private let displayName: String
    private let listenPort: UInt16
    private var socketFD: Int32 = -1
    private var lastTrigger = ""
    private var lastTriggerTime = Date.distantPast

    init(printerHost: String, localIP: String, displayName: String,
         listenPort: UInt16 = 54926) {
        self.printerHost = printerHost
        self.localIP = localIP
        self.displayName = displayName
        self.listenPort = listenPort
    }

    deinit {
        if socketFD >= 0 { close(socketFD) }
    }

    func start() throws {
        socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            throw ScanError.connectionFailed("cannot create UDP socket")
        }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw ScanError.connectionFailed("cannot bind UDP port \(listenPort)")
        }
        // recvfrom wakes up regularly so the registration can be refreshed.
        var tv = timeval(tv_sec: 50, tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try register()
    }

    /// Blocks until the device reports our Scan-button entry was chosen.
    /// Re-registers whenever the wait times out.
    func waitForButton() throws {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = recv(socketFD, &buffer, buffer.count, 0)
            if n <= 0 {
                try register()
                continue
            }
            // Datagram: 0x02 0x00 <len> 0x30 + "TYPE=BR;BUTTON="SCAN";USER="…";…"
            guard n > 4, buffer[0] == 2 else { continue }
            let text = String(decoding: buffer[4..<n], as: UTF8.self)
            var fields: [String: String] = [:]
            for item in text.split(separator: ";") {
                let parts = item.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1]).trimmingCharacters(
                    in: CharacterSet(charactersIn: "\""))
            }
            guard fields["USER"] == displayName else { continue }

            // The device retransmits each press several times (same SEQ).
            let trigger = "\(fields["REGID"] ?? "")/\(fields["SEQ"] ?? "")"
            if trigger == lastTrigger && Date().timeIntervalSince(lastTriggerTime) < 15 {
                continue
            }
            lastTrigger = trigger
            lastTriggerTime = Date()
            return
        }
    }

    /// SNMPv1 SET of the Brother scan-key OID, refreshed by the wait loop.
    func register() throws {
        let record = "TYPE=BR;BUTTON=SCAN;USER=\"\(displayName)\";FUNC=IMAGE;"
            + "HOST=\(localIP):\(listenPort);APPNUM=1;DURATION=360;BRID=;"
        let packet = snmpV1Set(
            community: "internal",
            oid: [1, 3, 6, 1, 4, 1, 2435, 2, 3, 9, 2, 11, 1, 1, 0],
            value: record)

        let sendFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard sendFD >= 0 else {
            throw ScanError.connectionFailed("cannot create SNMP socket")
        }
        defer { close(sendFD) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(161).bigEndian
        guard inet_pton(AF_INET, printerHost, &addr.sin_addr) == 1 else {
            throw ScanError.connectionFailed("printer address \(printerHost) is not IPv4")
        }
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sendFD, bytes.baseAddress, bytes.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            throw ScanError.connectionFailed("SNMP registration send failed")
        }
    }
}

// MARK: - Minimal SNMPv1 BER encoding

private func berLength(_ n: Int) -> [UInt8] {
    if n < 0x80 { return [UInt8(n)] }
    if n < 0x100 { return [0x81, UInt8(n)] }
    return [0x82, UInt8(n >> 8), UInt8(n & 0xff)]
}

private func berWrap(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
    [tag] + berLength(content.count) + content
}

private func berInt(_ value: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    var v = value
    repeat {
        bytes.insert(UInt8(v & 0xff), at: 0)
        v >>= 8
    } while v > 0
    if bytes.isEmpty || bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
    return berWrap(0x02, bytes)
}

private func berOID(_ oid: [Int]) -> [UInt8] {
    var content: [UInt8] = [UInt8(oid[0] * 40 + oid[1])]
    for id in oid.dropFirst(2) {
        var chunk: [UInt8] = [UInt8(id & 0x7f)]
        var v = id >> 7
        while v > 0 {
            chunk.insert(UInt8(0x80 | (v & 0x7f)), at: 0)
            v >>= 7
        }
        content += chunk
    }
    return berWrap(0x06, content)
}

private func snmpV1Set(community: String, oid: [Int], value: String) -> Data {
    let varBind = berWrap(0x30, berOID(oid) + berWrap(0x04, Array(value.utf8)))
    let pdu = berWrap(0xA3, // SetRequest-PDU
        berInt(Int.random(in: 1...0x7fffffff)) // request-id
        + berInt(0) + berInt(0)                // error-status, error-index
        + berWrap(0x30, varBind))
    let message = berWrap(0x30, berInt(0) // version: SNMPv1
        + berWrap(0x04, Array(community.utf8))
        + pdu)
    return Data(message)
}
