// swift-tools-version: 6.0
// Only for `swift test`: the app itself is built by build.sh with plain swiftc.
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "UsageCore",
            path: "Sources",
            sources: ["Usage.swift"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
