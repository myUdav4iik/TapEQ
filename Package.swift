// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TapEQ",
    // Core Audio process taps need macOS 14.2; the lock-free parameter
    // hand-off uses the Synchronization module, which needs macOS 15.
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "TapEQCore"),
        .executableTarget(name: "TapEQ", dependencies: ["TapEQCore"]),
        .testTarget(name: "TapEQCoreTests", dependencies: ["TapEQCore"]),
    ]
)
