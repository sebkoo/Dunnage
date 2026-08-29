// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dunnage",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DunnageCore", targets: ["DunnageCore"]),
        .library(name: "DunnageLedger", targets: ["DunnageLedger"]),
    ],
    targets: [
        // Pure. No networking, no disk, no clock, no randomness.
        .target(name: "DunnageCore"),

        // The durable ledger. Core is pure, so the disk lives here and nowhere else.
        .target(name: "DunnageLedger", dependencies: ["DunnageCore"]),

        .testTarget(name: "DunnageTests", dependencies: ["DunnageCore", "DunnageLedger"]),
    ]
)
