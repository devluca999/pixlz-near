// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixlzCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PixlzCore", targets: ["PixlzCore"]),
    ],
    targets: [
        .target(name: "PixlzCore"),
        .testTarget(name: "PixlzCoreTests", dependencies: ["PixlzCore"]),
    ]
)
