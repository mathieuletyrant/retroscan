// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "retroscan",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "retroscan", path: "Sources/retroscan")
    ]
)
