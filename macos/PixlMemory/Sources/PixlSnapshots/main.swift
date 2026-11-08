// Renders Pixl Memory's real views offscreen to PNG (for the README and the demo).
// Needs no screen-recording permission: nothing is captured from the screen.
//
//   swift run pixl-snapshots <polish_response.json> <out-dir>
import AppKit
import PixlMemoryKit

@MainActor
func png(_ view: NSView, _ path: String, scale: CGFloat = 2) throws {
    let size = view.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  \(Int(size.width))×\(Int(size.height)) pt")
}

/// Plain background view (flipped so layout reads top-down).
final class Canvas: NSView {
    let fill: NSColor
    let draws: ((NSRect) -> Void)?
    init(_ size: NSSize, fill: NSColor, draws: ((NSRect) -> Void)? = nil) {
        self.fill = fill; self.draws = draws
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ r: NSRect) { fill.setFill(); bounds.fill(); draws?(bounds) }
}

@MainActor
func label(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint) {
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

@MainActor
func run() throws {
    let args = CommandLine.arguments
    guard args.count == 3 else { print("usage: pixl-snapshots <polish_response.json> <out-dir>"); exit(2) }
    let result = try JSONDecoder().decode(PolishResult.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let out = args[2]
    try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let art = FroggArt.shared

    // 1. Every frame Frogg has, at 3×, labelled.
    let names = ["idle_0", "idle_1", "idle_2", "move_0", "move_1", "move_2", "poke_0", "poke_1", "poke_2",
                 "grab_0", "grab_1", "grab_2", "signature_0", "signature_1", "signature_2", "rest_0", "rest_1", "rest_2",
                 "perch_2", "emotion_happy", "emotion_annoyed", "emotion_sleepy", "emotion_startled", "emotion_curious", "emotion_proud"]
    let cell = NSSize(width: art.canvas.width * 3 + 24, height: art.canvas.height * 3 + 40)
    let cols = 5
    let rows = (names.count + cols - 1) / cols
    let sheet = Canvas(NSSize(width: cell.width * CGFloat(cols) + 24, height: cell.height * CGFloat(rows) + 70), fill: Theme.paper) { _ in
        label("Frogg · rendered from the Claude Design C7 engine · 3×", Theme.mono(18, .bold), Theme.ink, at: NSPoint(x: 24, y: 20))
    }
    for (i, n) in names.enumerated() {
        let v = FroggView(scale: 3, frameName: n)
        v.frame.origin = NSPoint(x: 24 + CGFloat(i % cols) * cell.width, y: 60 + CGFloat(i / cols) * cell.height)
        sheet.addSubview(v)
        let l = NSTextField(labelWithString: n.replacingOccurrences(of: "_", with: " "))
        l.font = Theme.mono(12, .bold); l.textColor = Theme.muted
        l.frame = NSRect(x: v.frame.minX, y: v.frame.maxY + 4, width: cell.width, height: 18)
        sheet.addSubview(l)
    }
    try png(sheet, "\(out)/frogg-frames.png")

    // 2. Frogg perched on a (drawn) window's title bar, with its thought bubble.
    let scene = NSSize(width: 980, height: 560)
    let win = NSRect(x: 120, y: 190, width: 740, height: 330)
    let selected = "hey team, i think we should of shipped the frog feature last week but their was alot of bugs."
    let desk = Canvas(scene, fill: NSColor(srgbRed: 0.42, green: 0.55, blue: 0.70, alpha: 1)) { _ in
        // a plain macOS-style window: title bar, traffic lights, a text body with a selection
        NSColor(white: 0, alpha: 0.25).setFill(); NSBezierPath(roundedRect: win.offsetBy(dx: 0, dy: 10), xRadius: 12, yRadius: 12).fill()
        NSColor.white.setFill(); NSBezierPath(roundedRect: win, xRadius: 12, yRadius: 12).fill()
        NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: win.minX, y: win.minY + 12, width: win.width, height: 26).fill()
        NSBezierPath(roundedRect: NSRect(x: win.minX, y: win.minY, width: win.width, height: 38), xRadius: 12, yRadius: 12).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: win.minX + 16 + CGFloat(i) * 20, y: win.minY + 13, width: 12, height: 12)).fill()
        }
        label("Mail — Re: frog feature", .systemFont(ofSize: 13, weight: .semibold), .darkGray, at: NSPoint(x: win.midX - 75, y: win.minY + 11))
        let body = NSRect(x: win.minX + 40, y: win.minY + 70, width: win.width - 80, height: 200)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 6
        let text = NSMutableAttributedString(string: selected + "\n\ncan we talk tmrw?",
                                             attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.black, .paragraphStyle: para])
        text.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: NSRange(location: 0, length: (selected as NSString).length))
        text.draw(with: body, options: [.usesLineFragmentOrigin])
    }
    let frogg = FroggView(scale: 2, frameName: "emotion_proud")
    // feet on the title bar, 140 pt from the window's right edge (Perch.rightOffset)
    frogg.frame.origin = NSPoint(x: win.maxX - 140 - frogg.frame.width / 2, y: win.minY + 2 - frogg.frame.height)
    desk.addSubview(frogg)
    let bubble = BubbleView(text: "✔ Verified in TEE · \(result.verification.passed)/\(result.verification.checks.count)")
    let headTop = frogg.frame.maxY - art.size("emotion_proud").height * 2
    bubble.frame.origin = NSPoint(x: frogg.frame.midX - bubble.frame.width / 2, y: headTop - bubble.frame.height - 2)
    // BubbleView draws its tail at the bottom in unflipped coordinates; wrap it so it isn't mirrored.
    let holder = NSView(frame: bubble.frame)
    bubble.frame.origin = .zero
    holder.addSubview(bubble)
    desk.addSubview(holder)
    try png(desk, "\(out)/frogg-perched.png")

    // 3. The result panel, with and without the checks.
    for (name, details) in [("polish-panel", false), ("polish-panel-checks", true)] {
        let panel = PolishView(.result(result, instruction: "Polish this", app: "Mail"), showDetails: details)
        panel.fit()
        let bg = Canvas(NSSize(width: panel.frame.width + 48, height: panel.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
        panel.frame.origin = NSPoint(x: 24, y: 24)
        bg.addSubview(panel)
        try png(bg, "\(out)/\(name).png")
    }

    // 3b. Right-click: the radial menu around Frogg, and the ⌃⌥P mini menu.
    let radialScene = Canvas(NSSize(width: RadialMenuView.size.width + 40, height: RadialMenuView.size.height + 40),
                             fill: NSColor(srgbRed: 0.42, green: 0.55, blue: 0.70, alpha: 1))
    let rf = FroggView(scale: 2, frameName: "poke_1")
    rf.frame.origin = NSPoint(x: radialScene.bounds.midX - rf.frame.width / 2,
                              y: radialScene.bounds.midY + art.size("idle_0").height - rf.frame.height)
    radialScene.addSubview(rf)
    let radial = RadialMenuView(items: [
        .init(id: "polish", title: "Polish", glyph: "✎"), .init(id: "focus", title: "Focus", glyph: "◷"),
        .init(id: "chat", title: "Chat", glyph: "💬", enabled: false), .init(id: "mic", title: "Mic", glyph: "🎙", enabled: false),
        .init(id: "hide", title: "Hide", glyph: "◌"), .init(id: "settings", title: "Settings", glyph: "⚙")])
    radial.frame.origin = NSPoint(x: 20, y: 20)
    radialScene.addSubview(radial)
    try png(radialScene, "\(out)/radial-menu.png")

    let mini = MiniMenuView(settings: PixlSettings(), status: ServiceStatus(
        service: "running", model: "z-ai/glm-5.3-flash", wallet: "frogg.sylversurferr.testnet doesn't exist yet: open /wallet/setup and approve in Meteor",
        lastVerdict: "Verified in TEE · 17/17"))
    mini.fit()
    let miniBG = Canvas(NSSize(width: mini.frame.width + 48, height: mini.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
    mini.frame.origin = NSPoint(x: 24, y: 24)
    miniBG.addSubview(mini)
    try png(miniBG, "\(out)/mini-menu.png")

    // 4. What the user sees if the enclave fails verification.
    let failed = PolishView(.error(.attestationFailed("Not verified: model fresh for this request failed. Treat this result as untrusted.", nil), app: "Mail"))
    failed.fit()
    let bg = Canvas(NSSize(width: failed.frame.width + 48, height: failed.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
    failed.frame.origin = NSPoint(x: 24, y: 24)
    bg.addSubview(failed)
    try png(bg, "\(out)/polish-refused.png")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    do { try run() } catch { print("error: \(error)"); exit(1) }
}
