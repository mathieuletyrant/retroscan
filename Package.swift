// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "retroscan",
    platforms: [.macOS(.v13)],
    targets: [
        // Scanner protocol, discovery, crop/rotate/metadata pipeline.
        .target(name: "RetroscanKit", path: "Sources/RetroscanKit"),
        // Command-line interface.
        .executableTarget(
            name: "retroscan",
            dependencies: ["RetroscanKit"],
            path: "Sources/retroscan"),
        // SwiftUI app ("make app" wraps it into Retroscan.app).
        .executableTarget(
            name: "RetroscanApp",
            dependencies: ["RetroscanKit"],
            path: "Sources/RetroscanApp",
            exclude: ["Info.plist", "AppIcon.icns"]),
    ]
)
