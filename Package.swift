// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "UsageBar",
            path: "Sources/UsageBar"
        )
    ]
)
