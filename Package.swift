// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RPPGCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "RPPGCore", targets: ["RPPGCore"])
    ],
    targets: [
        // Pure-Swift signal processing core: no AVFoundation / Vision / Accelerate,
        // so it can be unit tested on any platform (including Linux CI).
        .target(name: "RPPGCore"),
        .testTarget(name: "RPPGCoreTests", dependencies: ["RPPGCore"])
    ]
)
