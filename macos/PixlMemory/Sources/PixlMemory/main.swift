import AppKit

// `PixlMemory showcase run F1` (and next | prev | restart | reset): tell the running app's
// Showcase mode what to do, then exit. Only a copy started with --showcase / PIXL_SHOWCASE=1
// listens.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "showcase" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    DistributedNotificationCenter.default().postNotificationName(ShowcaseCommand.name, object: nil,
                                                                 userInfo: ["do": args[0], "scene": args.count > 1 ? args[1] : ""],
                                                                 deliverImmediately: true)
    print("showcase: \(args.joined(separator: " ")) sent")
    exit(0)
}

// Menu-bar-only app (LSUIElement behaviour): no Dock icon, never steals focus.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
