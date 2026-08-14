// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokenomics",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tokenomics",
            path: "Sources/Tokenomics"
        ),
        .testTarget(
            name: "CodexSessionWatcherTests",
            dependencies: ["Tokenomics"],
            path: "Tests/CodexSessionWatcherTests"
        )
    ]
)
