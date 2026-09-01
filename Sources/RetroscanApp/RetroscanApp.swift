import AppKit
import SwiftUI

/// Receives "open with" JPEGs (Finder, `open -a Retroscan scan.jpg`) and
/// replays the pipeline on them. Files opened at launch arrive before the
/// first view's onAppear wires up the model, so they are held until then.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: ScanModel? { didSet { flush() } }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        flush()
    }

    private func flush() {
        guard let model else { return }
        let urls = pending
        pending.removeAll()
        for url in urls { model.processFile(url) }
    }
}

@main
struct RetroscanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScanModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model
                    // Also runs as a bare executable (swift run RetroscanApp):
                    // claim a Dock presence and come to the front.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}
