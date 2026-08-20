// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RPPGCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "RPPGCore", targets: ["RPPGCore"]),
        // Offline runner: re-computes POS from a recording's cR/cG/cB columns, so a
        // capture can be replayed and cross-checked without a device.
        .executable(name: "rppg-replay", targets: ["rppg-replay"])
    ],
    targets: [
        // Pure-Swift signal core: no AVFoundation / Vision / Accelerate, so it can be
        // unit tested on any platform.
        .target(name: "RPPGCore"),
        .executableTarget(name: "rppg-replay", dependencies: ["RPPGCore"]),
        .testTarget(
            name: "RPPGCoreTests",
            dependencies: ["RPPGCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
