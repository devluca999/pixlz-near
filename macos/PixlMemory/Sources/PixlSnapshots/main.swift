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
    var art: FroggArt { FroggArt.shared }

    // 1. Every frame of every Pixl, at 2×, labelled: one sheet per Pixl.
    let names = PixlSkins.requiredFrames
    for skin in PixlSkins.all {
        PixlSkins.currentID = skin.id
        let a = skin.art
        let cell = NSSize(width: a.canvas.width * 2 + 16, height: a.canvas.height * 2 + 30)
        let cols = 9
        let rows = (names.count + cols - 1) / cols
        let sheet = Canvas(NSSize(width: cell.width * CGFloat(cols) + 24, height: cell.height * CGFloat(rows) + 64), fill: Theme.paper) { _ in
            label("\(skin.manifest.name) · \(skin.manifest.species) · \(names.count) frames from the Claude Design engine · 2×",
                  Theme.mono(16, .bold), Theme.ink, at: NSPoint(x: 24, y: 18))
        }
        for (i, n) in names.enumerated() {
            let v = FroggView(scale: 2, frameName: n)
            v.frame.origin = NSPoint(x: 24 + CGFloat(i % cols) * cell.width, y: 54 + CGFloat(i / cols) * cell.height)
            sheet.addSubview(v)
            let l = NSTextField(labelWithString: n.replacingOccurrences(of: "_", with: " "))
            l.font = Theme.mono(10, .bold); l.textColor = Theme.muted
            l.frame = NSRect(x: v.frame.minX, y: v.frame.maxY + 2, width: cell.width, height: 14)
            sheet.addSubview(l)
        }
        try png(sheet, "\(out)/\(skin.id)-frames.png")
    }
    PixlSkins.currentID = "frogg"

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
        let card = SurfaceView.card(panel, look: SurfaceView.Look(glass: false, variant: .light, dim: 1))
        let bg = Canvas(NSSize(width: card.frame.width + 48, height: card.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
        card.frame.origin = NSPoint(x: 24, y: 24)
        bg.addSubview(card)
        try png(bg, "\(out)/\(name).png")
    }

    // 3b. C8 option bubbles over three backgrounds (paper fallback: glass needs the live compositor).
    let paper = SurfaceView.Look(glass: false, variant: .light, dim: 1)
    let backdrops: [(String, NSColor, ((NSRect) -> Void)?)] = [
        ("white-doc", NSColor(white: 0.99, alpha: 1), { r in
            NSColor(white: 0.82, alpha: 1).setFill()
            for k in stride(from: 30.0, to: r.height - 20, by: 22) { NSRect(x: 30, y: k, width: r.width - 60 - CGFloat(Int(k) % 90), height: 6).fill() }
        }),
        ("dark-editor", NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1), { r in
            let cols: [NSColor] = [.systemPink, .systemTeal, .systemYellow, NSColor(white: 0.6, alpha: 1)]
            for (n, k) in stride(from: 24.0, to: r.height - 20, by: 18).enumerated() {
                cols[n % 4].withAlphaComponent(0.8).setFill()
                NSRect(x: 30 + CGFloat(n % 3) * 20, y: k, width: CGFloat(80 + (n * 37) % 200), height: 7).fill()
            }
        }),
        ("busy-photo", .black, { r in
            for x in stride(from: 0.0, to: r.width, by: 12) { for y in stride(from: 0.0, to: r.height, by: 12) {
                let h = (sin(x * 0.031) + cos(y * 0.047) + sin((x + y) * 0.013)) / 6 + 0.5
                NSColor(hue: h, saturation: 0.7, brightness: 0.35 + 0.6 * abs(sin(x * y * 0.0007)), alpha: 1).setFill()
                NSRect(x: x, y: y, width: 12, height: 12).fill()
            } }
        }),
    ]
    let slots = BubbleMenuModel.slots(selection: true, peer: nil, walletSub: "0.48 Ⓝ")
    for (name, fill, draws) in backdrops {
        let scene = Canvas(NSSize(width: 420, height: 300), fill: fill, draws: draws)
        let head = CGPoint(x: 210, y: 190)  // the canvas and the bubbles view are both flipped
        let centers = BubbleMenuModel.arc(count: slots.count, head: head, radius: BubbleMenuModel.radius(scale: 2), direction: .up)
        let f = FroggView(scale: 2, frameName: "emotion_curious")
        let feet = head.y + art.size("emotion_curious").height * 2 - 10  // the app puts the head 5 art px below the top
        f.frame.origin = NSPoint(x: 210 - f.frame.width / 2, y: feet - f.frame.height)
        scene.addSubview(f)
        let v = OptionBubblesView(frame: scene.bounds, slots: slots, head: head, centers: centers, look: paper, labelLook: paper)
        v.open(at: 0)
        v.advance(to: 2)
        v.setFocus(0)
        for k in 1...60 { v.advance(to: 2 + Double(k) / 60) }  // the focused bubble's label fades in
        scene.addSubview(v)
        try png(scene, "\(out)/bubbles-\(name).png")
    }

    // The More list and the Ask card on the same surface.
    let more = ListMenuView(rows: [
        .init(id: "ask", title: "Ask", icon: "ask", trailing: "⌘K"), .init(id: "memory", title: "Memory", icon: "memory"),
        .init(id: "wallet", title: "Wallet", icon: "wallet", trailing: "0.48 Ⓝ"),
        .init(id: "send", title: "Send to device", icon: "send", enabled: false),
        .init(id: "signature", title: "Do your thing", icon: nil, trailing: "Tongue snap"),
        .init(id: "settings", title: "Pixl settings", icon: "settings", trailing: "⌃⌥P"),
        .init(id: "hide", title: "Hide for now", icon: "hide", trailing: "⌃⌥H")], look: paper)
    more.setFocus(2)
    let moreBG = Canvas(NSSize(width: more.frame.width + 48, height: more.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
    more.frame.origin = NSPoint(x: 24, y: 24)
    moreBG.addSubview(more)
    try png(moreBG, "\(out)/more-list.png")

    let mini = MiniMenuView(settings: PixlSettings(), status: ServiceStatus(
        service: "running", model: "z-ai/glm-5.3-flash", wallet: "frogg.sylversurferr.testnet doesn't exist yet: open /wallet/setup and approve in Meteor",
        lastVerdict: "Verified in TEE · 17/17"), look: paper)
    mini.fit()
    let miniCard = SurfaceView.card(mini, look: paper)
    let miniBG = Canvas(NSSize(width: miniCard.frame.width + 48, height: miniCard.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
    miniCard.frame.origin = NSPoint(x: 24, y: 24)
    miniBG.addSubview(miniCard)
    try png(miniBG, "\(out)/mini-menu.png")

    // 3c. The C10 cards (Solid material), light and dark, over a desktop-ish backdrop.
    let sampleHighlights = [
        HighlightItem(id: "1", text: "While a glass frog sleeps, it hides almost all of its red blood cells inside its liver, which makes its body nearly transparent.",
                      url: "https://example.org/glass-frogs", title: "Glass frogs", fragmentUrl: "https://example.org/glass-frogs#:~:text=While%20a%20glass"),
        HighlightItem(id: "2", text: "Text fragments let a link point at an exact passage, which the browser scrolls to and highlights.",
                      url: "https://wicg.github.io/scroll-to-text-fragment/", title: "Scroll to Text Fragment", fragmentUrl: nil),
    ]
    let walletJSON = #"{"network":"testnet","account":"frogg.sylversurferr.testnet","balance_near":"0.4821","spent_today_near":"0.0042","caps":{"per_request_near":"0.01","per_day_near":"0.1","per_week_near":"0.25","reserve_near":"0.05"},"ceilings":{"per_day_near":"0.1","per_week_near":"0.5"},"spent_week_near":"0.0631","week_resets":"2026-11-15","paused":false,"ready":true,"explorer":"https://testnet.nearblocks.io/address/frogg.sylversurferr.testnet"}"#
    let wallet = try? JSONDecoder().decode(WalletInfo.self, from: Data(walletJSON.utf8))
    let receipts = [Receipt(status: "paid", amountNear: "0.0021", to: "sylversurferr.testnet", txHash: "x", explorer: "https://testnet.nearblocks.io", balanceAfterNear: nil, reason: nil),
                    Receipt(status: "paid", amountNear: "0.0021", to: "sylversurferr.testnet", txHash: "y", explorer: "https://testnet.nearblocks.io", balanceAfterNear: nil, reason: nil)]
    for dark in [false, true] {
        let look = SurfaceView.Look.text(designFill: 0.26, prefersDark: dark, glass: false)
        let ask = AskCard(placeholder: PixlData.ui.askPlaceholder, look: look); ask.fit()
        let mem = MemoryCard(highlights: sampleHighlights, look: look); mem.fit()
        let empty = MemoryCard(highlights: [], look: look); empty.fit()
        let wal = WalletCard(info: wallet, payments: receipts, look: look); wal.fit()
        let skins = SkinCard(selected: "frogg", look: look); skins.fit()
        let cards = [ask, mem, empty, wal, skins].map { SurfaceView.card($0, look: look) }
        let width = cards.map(\.frame.width).reduce(0, +) + CGFloat(cards.count + 1) * 24
        let height = (cards.map(\.frame.height).max() ?? 0) + 48
        let bg = Canvas(NSSize(width: width, height: height), fill: dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1))
        var x: CGFloat = 24
        for c in cards { c.frame.origin = NSPoint(x: x, y: 24); bg.addSubview(c); x += c.frame.width + 24 }
        try png(bg, "\(out)/cards-\(dark ? "dark" : "light").png")
        let say = BubbleView(text: "Hi, I'm \(PixlData.manifest.name)! Double-click me.", look: SurfaceView.Look.text(designFill: 0.62, prefersDark: dark, glass: false))
        let sbg = Canvas(NSSize(width: say.frame.width + 48, height: say.frame.height + 48), fill: dark ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1))
        let holder = NSView(frame: NSRect(x: 24, y: 24, width: say.frame.width, height: say.frame.height)); holder.addSubview(say); sbg.addSubview(holder)
        try png(sbg, "\(out)/speech-\(dark ? "dark" : "light").png")
    }

    // 3d. The lineup: every Pixl on a window edge with its bubbles open and a word in its own
    // speech bubble (its accent, its decal), on the Solid material.
    do {
        let look = SurfaceView.Look.text(designFill: 0.62, prefersDark: false, glass: false)
        let icon = SurfaceView.Look.icon(prefersDark: false, glass: false)
        let w: CGFloat = 330, h: CGFloat = 330
        let lineup = Canvas(NSSize(width: w * CGFloat(PixlSkins.all.count) + 24, height: h + 24), fill: NSColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1))
        for (i, skin) in PixlSkins.all.enumerated() {
            PixlSkins.currentID = skin.id
            let scene = Canvas(NSSize(width: w - 12, height: h), fill: NSColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1)) { r in
                NSColor(white: 1, alpha: 1).setFill(); NSRect(x: 18, y: 250, width: r.width - 36, height: r.height - 250).fill()   // a window below
                NSColor(white: 0.85, alpha: 1).setFill(); NSRect(x: 18, y: 250, width: r.width - 36, height: 2).fill()
            }
            scene.frame.origin = NSPoint(x: 12 + CGFloat(i) * w, y: 12)
            let f = FroggView(scale: 2, frameName: skin.ui.menuFace)
            let feet: CGFloat = 251
            f.frame.origin = NSPoint(x: scene.bounds.midX - f.frame.width / 2, y: feet - f.frame.height)
            scene.addSubview(f)
            let art = skin.art.size(skin.ui.menuFace)
            let head = CGPoint(x: scene.bounds.midX, y: feet - art.height * 2 + 10)
            let slots = BubbleMenuModel.slots(selection: i % 2 == 0, peer: nil, walletSub: "0.48 Ⓝ")
            let centers = BubbleMenuModel.arc(count: slots.count, head: head, radius: BubbleMenuModel.radius(scale: 2), direction: .up)
            let v = OptionBubblesView(frame: scene.bounds, slots: slots, head: head, centers: centers, look: icon, labelLook: look)
            v.accent = { let c = RGB(hex: skin.ui.accent); return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }()
            v.open(at: 0); v.advance(to: 2); v.setFocus(0)
            for k in 1...60 { v.advance(to: 2 + Double(k) / 60) }
            scene.addSubview(v)
            let say = BubbleView(text: "Hi, I'm \(skin.manifest.name)!", look: look)
            let holder = NSView(frame: NSRect(x: 14, y: 168, width: say.frame.width, height: say.frame.height)); holder.addSubview(say)
            scene.addSubview(holder)
            let cap = NSTextField(labelWithString: "\(skin.manifest.name) · \(skin.manifest.species) · \(skin.ui.signature)")
            cap.font = Theme.mono(11, .bold); cap.textColor = Theme.ink
            cap.frame = NSRect(x: 18, y: 262, width: w - 48, height: 16)
            scene.addSubview(cap)
            let detail = NSTextField(labelWithString: skin.ui.detail ?? "")
            detail.font = Theme.mono(9); detail.textColor = Theme.muted
            detail.frame = NSRect(x: 18, y: 282, width: w - 48, height: 14)
            scene.addSubview(detail)
            lineup.addSubview(scene)
        }
        try png(lineup, "\(out)/pixlz-lineup.png")
        PixlSkins.currentID = "frogg"
    }

    // 4. What the user sees if the enclave fails verification.
    let failed = PolishView(.error(.attestationFailed("Not verified: model fresh for this request failed. Treat this result as untrusted.", nil), app: "Mail"))
    failed.fit()
    let failedCard = SurfaceView.card(failed, look: paper)
    let bg = Canvas(NSSize(width: failedCard.frame.width + 48, height: failedCard.frame.height + 48), fill: NSColor(white: 0.93, alpha: 1))
    failedCard.frame.origin = NSPoint(x: 24, y: 24)
    bg.addSubview(failedCard)
    try png(bg, "\(out)/polish-refused.png")
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    do { try run() } catch { print("error: \(error)"); exit(1) }
}
