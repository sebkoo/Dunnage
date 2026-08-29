// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dunnage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DunnageCore", targets: ["DunnageCore"])
    ],
    targets: [
        // Pure. No networking, no disk, no clock, no randomness.
        .target(name: "DunnageCore"),
        .testTarget(name: "DunnageCoreTests", dependencies: ["DunnageCore"]),
    ]
)
