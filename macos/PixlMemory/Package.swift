// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixlMemory",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PixlMemory", targets: ["PixlMemory"]),
        .executable(name: "pixl-snapshots", targets: ["PixlSnapshots"]),
    ],
    dependencies: [
        .package(path: "../../PixlzCore"),
    ],
    targets: [
        // Everything testable without a screen: art, geometry, API models, views.
        .target(name: "PixlMemoryKit", dependencies: ["PixlzCore"]),
        // The overlay app: panels, Accessibility, motion, menus.
        .executableTarget(name: "PixlMemory", dependencies: ["PixlMemoryKit", "PixlzCore"]),
        // Renders the app's views offscreen to PNGs for docs (no screen recording needed).
        .executableTarget(name: "PixlSnapshots", dependencies: ["PixlMemoryKit"]),
        .testTarget(name: "PixlMemoryKitTests", dependencies: ["PixlMemoryKit"],
                    resources: [.copy("Fixtures")]),
    ]
)
