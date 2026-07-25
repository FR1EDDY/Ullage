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
            path: "Sources/UsageBar",
            // The pricing table ships as data rather than code so it can be
            // corrected without a rebuild. `ModelPricing` locates it by
            // searching known paths rather than through `Bundle.module`, which
            // traps when the resource bundle isn't found — see that file.
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "UsageBarTests",
            dependencies: ["UsageBar"],
            path: "Tests/UsageBarTests"
        )
    ]
)
