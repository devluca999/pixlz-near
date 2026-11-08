import AppKit

// Menu-bar-only app (LSUIElement behaviour): no Dock icon, never steals focus.
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
