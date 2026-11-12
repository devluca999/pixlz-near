// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixlMemory",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "PixlMemory", targets: ["PixlMemory"]),
        .executable(name: "pixl-snapshots", targets: ["PixlSnapshots"]),
        .executable(name: "pixl-native-host", targets: ["PixlNativeHost"]),
        .executable(name: "pixl-agent-hook", targets: ["PixlAgentHook"]),
    ],
    dependencies: [
        .package(path: "../../PixlzCore"),
    ],
    targets: [
        // Everything testable without a screen: art, geometry, API models, views.
        .target(name: "PixlMemoryKit", dependencies: ["PixlzCore"]),
        // The Chrome extension bridge: protocol, routing, host manifest (no UI, fully testable).
        .target(name: "PixlBridge"),
        // Chrome starts this for the extension (native messaging); it relays to the service and the app.
        .executableTarget(name: "PixlNativeHost", dependencies: ["PixlBridge"]),
        // Agent mode: Claude Code sessions from its hooks, the hooks' settings, the outbox and the
        // transcript reader (testable), and the chat panel's text field (the only source of messages).
        .target(name: "PixlAgents"),
        // Claude Code runs this for each hook; it relays the event to the app and prints the answer.
        .executableTarget(name: "PixlAgentHook"),
        // The overlay app: panels, Accessibility, motion, menus.
        .executableTarget(name: "PixlMemory", dependencies: ["PixlMemoryKit", "PixlzCore", "PixlBridge", "PixlAgents",
                                                         .product(name: "PixlTravel", package: "PixlzCore")]),
        // Renders the app's views offscreen to PNGs for docs (no screen recording needed).
        .executableTarget(name: "PixlSnapshots", dependencies: ["PixlMemoryKit"]),
        .testTarget(name: "PixlMemoryKitTests", dependencies: ["PixlMemoryKit"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "PixlBridgeTests", dependencies: ["PixlBridge"]),
        .testTarget(name: "PixlAgentsTests", dependencies: ["PixlAgents"]),
    ]
)
