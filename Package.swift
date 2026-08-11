// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeSessionMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSessionMonitor",
            path: "Sources/ClaudeSessionMonitor"
        )
    ]
)
