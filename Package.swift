// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "claude-watch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-watch", targets: ["claude-watch"]),
        .executable(name: "ClaudeWatch", targets: ["ClaudeWatch"]),
    ],
    targets: [
        .target(name: "WatchCore"),
        .executableTarget(name: "claude-watch", dependencies: ["WatchCore"]),
        .executableTarget(name: "ClaudeWatch", dependencies: ["WatchCore"]),
        .testTarget(name: "WatchCoreTests", dependencies: ["WatchCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
