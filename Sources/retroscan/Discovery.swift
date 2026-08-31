import Foundation
import Network

struct DiscoveredScanner {
    let name: String
    let endpoint: NWEndpoint
}

/// Browses Bonjour for `_scanner._tcp` devices (Brother network scan protocol).
func discoverScanners(timeout: TimeInterval = 5.0) -> [DiscoveredScanner] {
    let browser = NWBrowser(for: .bonjour(type: "_scanner._tcp", domain: nil), using: .tcp)
    let lock = NSLock()
    var found: [String: NWEndpoint] = [:]
    let firstResult = DispatchSemaphore(value: 0)

    browser.browseResultsChangedHandler = { results, _ in
        lock.lock()
        for result in results {
            if case let .service(name, _, _, _) = result.endpoint {
                if found[name] == nil { found[name] = result.endpoint }
            }
        }
        let any = !found.isEmpty
        lock.unlock()
        if any { firstResult.signal() }
    }
    browser.start(queue: .global())

    // Wait for the first hit, then give stragglers a short grace period.
    if firstResult.wait(timeout: .now() + timeout) == .success {
        Thread.sleep(forTimeInterval: 0.5)
    }
    browser.cancel()

    lock.lock()
    defer { lock.unlock() }
    return found.map { DiscoveredScanner(name: $0.key, endpoint: $0.value) }
        .sorted { $0.name < $1.name }
}
