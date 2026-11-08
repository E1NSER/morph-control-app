// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MorphKit",
    defaultLocalization: "de",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MorphCore", targets: ["MorphCore"]),
        .library(name: "MorphServices", targets: ["MorphServices"]),
    ],
    targets: [
        .target(name: "MorphCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "MorphServices", dependencies: ["MorphCore"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MorphCoreTests", dependencies: ["MorphCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MorphServicesTests", dependencies: ["MorphServices", "MorphCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
