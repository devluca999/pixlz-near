// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixlMemory",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PixlMemory", targets: ["PixlMemory"]),
        .executable(name: "pixl-snapshots", targets: ["PixlSnapshots"]),
        .executable(name: "pixl-native-host", targets: ["PixlNativeHost"]),
    ],
    dependencies: [
        .package(path: "../../PixlzCore"),
    ],
    targets: [
        // Everything testable without a screen: art, geometry, API models, views.
        .target(name: "PixlMemoryKit", dependencies: ["PixlzCore"]),
        // The Chrome extension bridge: protocol, routing, host manifest (no UI, fully testable).
        .target(name: "PixlBridge"),
        // Trips between devices: Bonjour discovery + PixlzCore's trip protocol over TCP.
        .target(name: "PixlTravel", dependencies: ["PixlzCore"]),
        // Chrome starts this for the extension (native messaging); it relays to the service and the app.
        .executableTarget(name: "PixlNativeHost", dependencies: ["PixlBridge"]),
        // The overlay app: panels, Accessibility, motion, menus.
        .executableTarget(name: "PixlMemory", dependencies: ["PixlMemoryKit", "PixlzCore", "PixlBridge", "PixlTravel"]),
        // Renders the app's views offscreen to PNGs for docs (no screen recording needed).
        .executableTarget(name: "PixlSnapshots", dependencies: ["PixlMemoryKit"]),
        .testTarget(name: "PixlMemoryKitTests", dependencies: ["PixlMemoryKit"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "PixlBridgeTests", dependencies: ["PixlBridge"]),
        .testTarget(name: "PixlTravelTests", dependencies: ["PixlTravel", "PixlzCore"]),
    ]
)
