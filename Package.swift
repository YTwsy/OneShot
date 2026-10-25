// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneShot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OneShotCore", targets: ["OneShotCore"]),
        .executable(name: "oneshot", targets: ["OneShotCLI"]),
        .executable(name: "oneshot-editor", targets: ["OneShotEditor"]),
    ],
    targets: [
        .target(name: "OneShotCore"),
        .executableTarget(name: "OneShotCLI", dependencies: ["OneShotCore"]),
        .executableTarget(name: "OneShotEditor", dependencies: ["OneShotCore"]),
        .testTarget(name: "OneShotCoreTests", dependencies: ["OneShotCore"]),
    ],
    swiftLanguageModes: [.v5]
)
