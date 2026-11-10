// swift-tools-version: 6.0
import PackageDescription

// The Mac half of the Mosaico spike: sends Frogg to a Mosaico and docks to catch him back.
// Uses PixlzCore's TravelNode and Framing as-is.
let package = Package(
    name: "PixlzSend",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../../../PixlzCore")],
    targets: [
        .executableTarget(
            name: "PixlzSend",
            dependencies: [.product(name: "PixlzCore", package: "PixlzCore")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
