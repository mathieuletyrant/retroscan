import Foundation

public func sanitizeForFilename(_ text: String) -> String {
    String(text.map { "/:\\".contains($0) ? "-" : $0 })
        .trimmingCharacters(in: .whitespaces)
}

/// Size on disk, or nil if the file is unreachable.
public func fileSize(_ url: URL) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
}

/// First index N such that no "<base>-N.jpg" (or higher) exists yet, so a new
/// batch continues the numbering of previous runs.
public func nextFreeIndex(in dir: URL, base: String) -> Int {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    var highest = 0
    for entry in entries {
        guard entry.hasPrefix("\(base)-"), entry.lowercased().hasSuffix(".jpg") else { continue }
        let middle = entry.dropFirst(base.count + 1).dropLast(4)
        if let n = Int(middle) { highest = max(highest, n) }
    }
    return highest + 1
}
