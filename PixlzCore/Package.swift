// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixlzCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PixlzCore", targets: ["PixlzCore"]),
        // Trips between devices (Mac and iPhone): Bonjour discovery + the trip protocol over TCP.
        .library(name: "PixlTravel", targets: ["PixlTravel"]),
    ],
    targets: [
        .target(name: "PixlzCore"),
        .target(name: "PixlTravel", dependencies: ["PixlzCore"]),
        .testTarget(name: "PixlzCoreTests", dependencies: ["PixlzCore"]),
        .testTarget(name: "PixlTravelTests", dependencies: ["PixlTravel", "PixlzCore"]),
    ]
)
