// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "claude-watch",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "claude-watch", targets: ["claude-watch"]),
        .executable(name: "ClaudeWatch", targets: ["ClaudeWatch"]),
        // Shared with the iPhone app (iOS/ClaudeRemote.xcodeproj).
        .library(name: "WatchProtocol", targets: ["WatchProtocol"]),
    ],
    targets: [
        .target(name: "WatchProtocol"),
        .target(name: "WatchCore", dependencies: ["WatchProtocol"]),
        .executableTarget(name: "claude-watch", dependencies: ["WatchCore"]),
        .executableTarget(name: "ClaudeWatch", dependencies: ["WatchCore"]),
        .testTarget(name: "WatchProtocolTests", dependencies: ["WatchProtocol"]),
        .testTarget(name: "WatchCoreTests", dependencies: ["WatchCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
