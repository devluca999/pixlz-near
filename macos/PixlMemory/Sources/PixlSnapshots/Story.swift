import AppKit
import PixlMemoryKit
import PixlzCore

// `pixl-snapshots --story <polish_response.json> <out-dir>`: the demo storyboard. Every Pixl,
// card, bubble and list is the app's real view; desktops, windows and devices are drawn
// backdrops (the app never records the screen).

@MainActor
enum Story {
    static let ink = NSColor(srgbRed: 27 / 255, green: 42 / 255, blue: 26 / 255, alpha: 1)
    static let paper = NSColor(srgbRed: 1, green: 251 / 255, blue: 242 / 255, alpha: 1)
    static let size = NSSize(width: 960, height: 560)
    static let solid = SurfaceView.Look(glass: false, variant: .light, dim: 0.94)

    /// A soft desktop with a dotted wallpaper.
    static func desktop(_ draws: ((NSRect) -> Void)? = nil) -> Canvas {
        Canvas(size, fill: NSColor(srgbRed: 0.83, green: 0.87, blue: 0.92, alpha: 1)) { r in
            NSColor(srgbRed: 0.76, green: 0.80, blue: 0.87, alpha: 1).setFill()
            for y in stride(from: 8.0, to: r.height, by: 18) { for x in stride(from: 8.0, to: r.width, by: 18) { NSRect(x: x, y: y, width: 2, height: 2).fill() } }
            // menu bar
            NSColor(white: 1, alpha: 0.7).setFill(); NSRect(x: 0, y: 0, width: r.width, height: 24).fill()
            label("  File   Edit   View   Window", .systemFont(ofSize: 12, weight: .medium), NSColor(white: 0.2, alpha: 1), at: NSPoint(x: 14, y: 4))
            draws?(r)
        }
    }

    /// A plain app window: title bar, traffic lights, lines of text.
    static func window(_ r: NSRect, title: String, lines: [String] = [], dark: Bool = false, highlight: Int? = nil) {
        NSColor(white: 0, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 6), xRadius: 10, yRadius: 10).fill()
        (dark ? NSColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        (dark ? NSColor(srgbRed: 0.17, green: 0.18, blue: 0.22, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        let bar = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width, height: 30), xRadius: 10, yRadius: 10)
        bar.fill(); NSRect(x: r.minX, y: r.minY + 20, width: r.width, height: 10).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: NSRect(x: r.minX + 12 + CGFloat(i) * 18, y: r.minY + 10, width: 11, height: 11)).fill()
        }
        label(title, .systemFont(ofSize: 12, weight: .semibold), dark ? NSColor(white: 0.8, alpha: 1) : NSColor(white: 0.35, alpha: 1),
              at: NSPoint(x: r.midX - CGFloat(title.count) * 3.3, y: r.minY + 8))
        for (i, line) in lines.enumerated() {
            let y = r.minY + 48 + CGFloat(i) * 26
            if i == highlight {
                NSColor(srgbRed: 0.70, green: 0.84, blue: 1, alpha: 1).setFill()
                let w = (line as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15)]).width
                NSRect(x: r.minX + 22, y: y - 2, width: w + 2, height: 22).fill()
            }
            label(line, .systemFont(ofSize: 15), dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.15, alpha: 1), at: NSPoint(x: r.minX + 23, y: y))
        }
    }

    /// The Pixl `skin` in `frame`, feet at `feet` (flipped canvas coordinates).
    @discardableResult
    static func pet(_ skin: String, _ frame: String, feet: CGPoint, in v: NSView, scale: CGFloat = 2, mirrored: Bool = false) -> FroggView {
        PixlSkins.currentID = skin
        let f = FroggView(scale: scale, frameName: frame)
        f.mirrored = mirrored
        f.frame.origin = NSPoint(x: feet.x - f.frame.width / 2, y: feet.y - f.frame.height)
        v.addSubview(f)
        return f
    }

    static func put(_ view: NSView, at p: NSPoint, in v: NSView) { view.frame.origin = p; v.addSubview(view) }

    static func card(_ content: NSView, at p: NSPoint, in v: NSView) {
        if let c = content as? PixlCard { c.fit() }
        let s = SurfaceView.card(content, look: solid)
        put(s, at: p, in: v)
    }

    static func say(_ text: String, near p: NSPoint, in v: NSView) {
        let b = BubbleView(text: text, look: solid)
        let holder = NSView(frame: NSRect(x: p.x, y: p.y, width: b.frame.width, height: b.frame.height))
        holder.addSubview(b)
        v.addSubview(holder)
    }

    static func dust(at p: CGPoint) {
        NSColor(white: 0.55, alpha: 0.8).setFill()
        for (dx, dy) in [(-22, 0), (-14, -6), (-6, -2), (8, -5), (16, -1), (24, -4), (-18, -11), (12, -10)] {
            NSRect(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy), width: 3, height: 3).fill()
        }
    }

    static func pill(_ text: String, at p: NSPoint, accent: String) {
        let font = Theme.mono(12, .bold)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 18
        let r = NSRect(x: p.x, y: p.y, width: w, height: 24)
        ink.setFill(); NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 2), xRadius: 12, yRadius: 12).fill()
        let c = RGB(hex: accent); NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
        let face = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12); face.fill()
        face.lineWidth = 1.5; ink.setStroke(); face.stroke()
        label(text, font, ink, at: NSPoint(x: r.minX + 9, y: r.minY + 4))
    }

    static func folderIcon(_ r: NSRect, name: String) {
        NSColor(srgbRed: 0.40, green: 0.68, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: r.width * 0.45, height: 14), xRadius: 4, yRadius: 4).fill()
        NSColor(srgbRed: 0.33, green: 0.62, blue: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 8, width: r.width, height: r.height - 8), xRadius: 6, yRadius: 6).fill()
        label(name, .systemFont(ofSize: 12, weight: .medium), NSColor(white: 0.15, alpha: 1),
              at: NSPoint(x: r.midX - CGFloat(name.count) * 3.4, y: r.maxY + 6))
    }

    static func render(_ result: PolishResult, fixture: URL, out: String) throws {
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let fixtureJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any] ?? [:]
        let verificationData = try JSONSerialization.data(withJSONObject: fixtureJSON["verification"] ?? [:])

        // 1. Polish anywhere: Frogg on the document, bubbles open with Polish first, the result card
        do {
            let v = desktop { _ in
                window(NSRect(x: 30, y: 230, width: 450, height: 300), title: "Notes — Team update",
                       lines: ["hey team, i think we should of shipped", "the frog feature last week but their was", "alot of bugs. can we talk tmrw?", "", "— Luca"], highlight: 0)
            }
            PixlSkins.currentID = "frogg"
            let feet = CGPoint(x: 330, y: 231)
            pet("frogg", "emotion_curious", feet: feet, in: v)
            let head = CGPoint(x: 330, y: 178)
            let slots = BubbleMenuModel.slots(selection: true, peer: nil, walletSub: "0.48 Ⓝ")
            let centers = BubbleMenuModel.arc(count: slots.count, head: head, radius: BubbleMenuModel.radius(scale: 2), direction: .up)
            let b = OptionBubblesView(frame: v.bounds, slots: slots, head: head, centers: centers, look: solid, labelLook: solid)
            b.accent = Accent.color
            b.open(at: 0); b.advance(to: 2); b.setFocus(0); for k in 1...60 { b.advance(to: 2 + Double(k) / 60) }
            v.addSubview(b)
            let panel = PolishView(.result(result, instruction: "Polish this", app: "Notes"), look: solid)
            panel.fit()
            let pc = SurfaceView.card(panel, look: solid)
            pc.frame.origin = NSPoint(x: 500, y: 36)
            let scale = min(1, 490 / pc.frame.height, 440 / pc.frame.width)
            pc.frame.size = NSSize(width: pc.frame.width * scale, height: pc.frame.height * scale)
            pc.bounds.size = NSSize(width: pc.frame.width / scale, height: pc.frame.height / scale)
            v.addSubview(pc)
            try png(v, "\(out)/01-polish.png")
        }

        // 2. Memory with folders: Mochi rides the Research folder; the Memory card filters by folder
        do {
            let v = desktop { _ in
                folderIcon(NSRect(x: 120, y: 380, width: 120, height: 92), name: "Research")
                folderIcon(NSRect(x: 40, y: 90, width: 90, height: 70), name: "To-dos")
                folderIcon(NSRect(x: 180, y: 90, width: 90, height: 70), name: "Answers")
            }
            pet("shiba", "file_ride_2", feet: CGPoint(x: 182, y: 390), in: v)
            let hs = [
                HighlightItem(id: "1", text: "While a glass frog sleeps, it hides almost all of its red blood cells inside its liver, which makes its body nearly transparent.",
                              url: "https://example.org/glass-frogs", title: "Glass frogs", fragmentUrl: "https://example.org/glass-frogs#:~:text=While", folder: "Research/Glass frogs"),
                HighlightItem(id: "2", text: "Text fragments let a link point at an exact passage, which the browser scrolls to and highlights.",
                              url: "https://wicg.github.io/scroll-to-text-fragment/", title: "Scroll to Text Fragment", fragmentUrl: nil, folder: "Research"),
                HighlightItem(id: "3", text: "Book the demo room for Friday · send the deck to Jordi", url: nil, title: nil, fragmentUrl: nil, folder: "To-dos"),
            ]
            PixlSkins.currentID = "shiba"
            let mem = MemoryCard(highlights: hs, look: solid)
            mem.choose(folder: "Research")
            card(mem, at: NSPoint(x: 340, y: 60), in: v)
            try png(v, "\(out)/02-memory.png")
        }

        // 3. Ask with your memory: Boo answers, citing the highlight it used, with backlinks
        do {
            let v = desktop { _ in window(NSRect(x: 40, y: 260, width: 330, height: 230), title: "Safari — Glass frogs", lines: ["Glass frogs live in cloud forests…", "While a glass frog sleeps, it hides", "almost all of its red blood cells…"], highlight: 1) }
            pet("ghost", "emotion_happy", feet: CGPoint(x: 300, y: 261), in: v)
            PixlSkins.currentID = "ghost"
            let ask = AskCard(placeholder: "Ask Boo anything…", look: solid)
            ask.input.stringValue = "What did I save about glass frogs?"
            let resJSON: [String: Any] = [
                "answer": "You saved that a sleeping glass frog hides almost all of its red blood cells in its liver, which makes it nearly transparent.",
                "verification": try JSONSerialization.jsonObject(with: verificationData),
                "highlights": [["id": "1", "text": "While a glass frog sleeps, it hides almost all of its red blood cells inside its liver, which makes its body nearly transparent.",
                                "url": "https://example.org/glass-frogs", "title": "Glass frogs", "fragment_url": "https://example.org/glass-frogs#:~:text=While"]],
            ]
            let r = try JSONDecoder().decode(AskResult.self, from: JSONSerialization.data(withJSONObject: resJSON))
            ask.show(r)
            card(ask, at: NSPoint(x: 420, y: 50), in: v)
            try png(v, "\(out)/03-ask.png")
        }

        // 4. A wallet of its own: the coin pops as Frogg pays; the weekly limit
        do {
            let v = desktop { _ in window(NSRect(x: 40, y: 250, width: 400, height: 240), title: "Mail — Draft", lines: ["Hi Sam,", "Thanks for the call today. Here's the", "summary we agreed on…"]) }
            pet("frogg", "emotion_proud", feet: CGPoint(x: 330, y: 251), in: v)
            v.addSubview(Painting(frame: v.bounds) { _ in pill("−0.0021 Ⓝ", at: NSPoint(x: 330, y: 150), accent: "#7CD93A") })
            let walletJSON = #"{"network":"testnet","account":"frogg.pixlz-petz.testnet","balance_near":"0.4821","spent_today_near":"0.0042","caps":{"per_request_near":"0.01","per_day_near":"0.1","per_week_near":"0.25","reserve_near":"0.05"},"ceilings":{"per_day_near":"0.1","per_week_near":"0.5"},"spent_week_near":"0.0631","week_resets":"2026-11-15","paused":false,"ready":true,"explorer":"https://testnet.nearblocks.io/address/frogg.pixlz-petz.testnet"}"#
            PixlSkins.currentID = "frogg"
            let info = try JSONDecoder().decode(WalletInfo.self, from: Data(walletJSON.utf8))
            let paid = Receipt(status: "paid", amountNear: "0.0021", to: "pixlz-petz.testnet", txHash: "x", explorer: "https://testnet.nearblocks.io", balanceAfterNear: nil, reason: nil)
            card(WalletCard(info: info, payments: [paid, paid], look: solid), at: NSPoint(x: 520, y: 40), in: v)
            try png(v, "\(out)/04-wallet.png")
        }

        // 5. Hand-off: Silky puts the drafted prompt into Claude's message box; you press send
        do {
            let v = desktop { _ in
                window(NSRect(x: 260, y: 120, width: 620, height: 380), title: "Claude", dark: true)
                NSColor(srgbRed: 0.20, green: 0.21, blue: 0.26, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: 290, y: 380, width: 560, height: 92), xRadius: 14, yRadius: 14).fill()
                label("Summarize my notes on glass frogs for a 1-minute", .systemFont(ofSize: 15), NSColor(white: 0.92, alpha: 1), at: NSPoint(x: 310, y: 396))
                label("talk, with the two sources I saved.", .systemFont(ofSize: 15), NSColor(white: 0.92, alpha: 1), at: NSPoint(x: 310, y: 420))
                NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: 806, y: 436, width: 30, height: 30)).fill()
                label("↑", .systemFont(ofSize: 16, weight: .bold), .white, at: NSPoint(x: 815, y: 440))
            }
            pet("widow", "idle_0", feet: CGPoint(x: 780, y: 121), in: v)
            PixlSkins.currentID = "widow"
            say("It's in Claude. Read it, then send it yourself.", near: NSPoint(x: 270, y: 40), in: v)
            try png(v, "\(out)/05-handoff.png")
        }

        // 6. Travel: Kiti leaves the Mac for the Laptop; the Laptop asks before catching
        do {
            let v = Canvas(size, fill: NSColor(srgbRed: 0.83, green: 0.87, blue: 0.92, alpha: 1)) { r in
                for (x, name) in [(30.0, "Studio Mac"), (500.0, "Laptop")] {
                    let screen = NSRect(x: x, y: 60, width: 430, height: 300)
                    NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1).setFill()
                    NSBezierPath(roundedRect: screen.insetBy(dx: -10, dy: -10), xRadius: 14, yRadius: 14).fill()
                    NSColor(srgbRed: 0.88, green: 0.91, blue: 0.95, alpha: 1).setFill()
                    NSBezierPath(rect: screen).fill()
                    NSColor(white: 1, alpha: 0.8).setFill(); NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: 18).fill()
                    label(name, .systemFont(ofSize: 13, weight: .semibold), NSColor(white: 0.3, alpha: 1), at: NSPoint(x: screen.midX - CGFloat(name.count) * 3.5, y: 385))
                }
                // the arc between the two screens
                let p = NSBezierPath(); p.move(to: NSPoint(x: 330, y: 240)); p.curve(to: NSPoint(x: 640, y: 240), controlPoint1: NSPoint(x: 400, y: 70), controlPoint2: NSPoint(x: 570, y: 70))
                p.setLineDash([5, 6], count: 2, phase: 0); p.lineWidth = 2; NSColor(srgbRed: 0.68, green: 0.56, blue: 0.93, alpha: 1).setStroke(); p.stroke()
                dust(at: CGPoint(x: 330, y: 346))
            }
            pet("cat", "move_1", feet: CGPoint(x: 360, y: 230), in: v)
            PixlSkins.currentID = "cat"
            let rows = [ListMenuView.Row(id: "yes", title: "Catch Kiti from Studio Mac", icon: nil, trailing: "↵"),
                        ListMenuView.Row(id: "no", title: "Not now", icon: nil, trailing: "esc")]
            let list = ListMenuView(rows: rows, look: solid)
            list.setFocus(0)
            put(list, at: NSPoint(x: 640, y: 130), in: v)
            pill("Send to Laptop", at: NSPoint(x: 120, y: 120), accent: "#AE90EC")
            v.addSubview(Painting(frame: v.bounds) { _ in
                label("Bonjour finds the Laptop · only Kiti's name, mood and stats travel · the Mac keeps a note until Kiti is called back",
                      Theme.mono(10), NSColor(white: 0.3, alpha: 1), at: NSPoint(x: 40, y: 410))
            })
            try png(v, "\(out)/06-travel.png")
        }

        // 7. Mischief: Fly snap (Frogg) and Sock hunt (Boo): 20 seconds, best score kept
        do {
            let v = desktop { _ in
                for (x, y) in [(170.0, 160.0), (330.0, 120.0), (620.0, 200.0), (760.0, 140.0)] {
                    GameArt.image("fly", scale: 3)?.draw(in: NSRect(x: x, y: y, width: 30, height: 30))
                }
                GameArt.image("sock", scale: 3)?.draw(in: NSRect(x: 690, y: 330, width: 30, height: 30))
            }
            pet("frogg", "signature_1", feet: CGPoint(x: 260, y: 470), in: v)
            pet("ghost", "poke_1", feet: CGPoint(x: 720, y: 480), in: v)
            PixlSkins.currentID = "frogg"
            say("7 flies! New best.", near: NSPoint(x: 150, y: 300), in: v)
            try png(v, "\(out)/07-mischief.png")
        }

        // 8. Lives with you: called from the menu bar; napping while you're away
        do {
            let v = desktop { r in
                // the frog icon in the menu bar
                if let icon = PixlSkins.skin("frogg")?.art.nsImage("idle_0", scale: 1) { icon.draw(in: NSRect(x: 768, y: 3, width: 25, height: 18)) }
                window(NSRect(x: 420, y: 260, width: 480, height: 240), title: "Pages — Essay", lines: ["The cloud forest at night is…"])
            }
            pet("frogg", "grab_0", feet: CGPoint(x: 780, y: 150), in: v)
            pet("cat", "rest_1", feet: CGPoint(x: 560, y: 261), in: v)
            PixlSkins.currentID = "frogg"
            say("Hi! I'm here.", near: NSPoint(x: 830, y: 70), in: v)
            v.addSubview(Painting(frame: v.bounds) { _ in label("z z", Theme.mono(14, .bold), NSColor(white: 0.35, alpha: 1), at: NSPoint(x: 600, y: 200)) })
            try png(v, "\(out)/08-presence.png")
        }

        // Each Pixl's own bubble detail: lily pad, tuna, bone, ectoplasm, web
        do {
            let v = desktop()
            let lines = [("frogg", "Polished. Want it?"), ("cat", "Found 2 notes."), ("shiba", "Saved to Research!"),
                         ("ghost", "Checked: private."), ("widow", "Sent to Claude.")]
            for (i, (skin, line)) in lines.enumerated() {
                let x = 40 + CGFloat(i) * 182
                pet(skin, "idle_0", feet: CGPoint(x: x + 80, y: 440), in: v)
                PixlSkins.currentID = skin
                let look = skin == "ghost" ? SurfaceView.Look(glass: true, variant: .light, dim: 1) : solid
                let bubble = BubbleView(text: line, look: look)
                put(bubble, at: NSPoint(x: x, y: 200), in: v)
            }
            PixlSkins.currentID = "frogg"
            try png(v, "\(out)/09-decals.png")
        }

        // Menus with a highlighted row in every theme (hover legibility)
        do {
            let v = desktop()
            let rows = [ListMenuView.Row(id: "skins", title: "Change Pixl", icon: "settings"),
                        ListMenuView.Row(id: "game", title: "Mischief: Fly snap", icon: "polish", trailing: "best 7"),
                        ListMenuView.Row(id: "hide", title: "Hide for now", icon: nil, trailing: "⌃⌥H")]
            let looks: [(String, SurfaceView.Look)] = [
                ("frogg", .init(glass: false, variant: .light, dim: 0.94)), ("frogg", .init(glass: false, variant: .dark, dim: 0.94)),
                ("cat", .init(glass: false, variant: .dark, dim: 0.94)), ("ghost", .init(glass: true, variant: .dark, dim: 0.66))]
            for (i, (skin, look)) in looks.enumerated() {
                PixlSkins.currentID = skin
                let list = ListMenuView(rows: rows, look: look)
                list.setFocus(1)
                put(list, at: NSPoint(x: 30 + CGFloat(i) * 230, y: 120), in: v)
            }
            PixlSkins.currentID = "frogg"
            try png(v, "\(out)/10-hover.png")
        }

        // Roam: Silky's route (up the wall, along the top, down on silk); Frogg reads along in a code app
        do {
            let caretX: CGFloat = 330
            let v = desktop { r in
                window(NSRect(x: 60, y: 250, width: 560, height: 270), title: "claude — ~/pixlz-near", lines: [
                    "> make the frog hop to folders", "  ⏺ Editing Roam.swift…", "  ⏺ 95 tests passed", "> |"], dark: true)
                // Silky's route: right wall up, ceiling left, then the thread down
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 935, y: 545)); path.line(to: NSPoint(x: 935, y: 40)); path.line(to: NSPoint(x: 760, y: 40))
                path.lineWidth = 2
                path.setLineDash([5, 5], count: 2, phase: 0)
                NSColor(srgbRed: 0.90, green: 0.14, blue: 0.18, alpha: 0.55).setStroke()
                path.stroke()
                NSColor(srgbRed: 0.86, green: 0.88, blue: 0.93, alpha: 1).setFill()
                NSRect(x: 759, y: 26, width: 1.5, height: 150).fill()
                label("Roam: each Pixl explores in its own way. Never while you type.", Theme.mono(11, .bold),
                      NSColor(white: 0.25, alpha: 1), at: NSPoint(x: 60, y: 540))
                _ = caretX
            }
            PixlSkins.currentID = "widow"
            let climbing = FroggView(scale: 1.4, frameName: "move_0")
            climbing.surface = .rightWall
            let c1 = Surface.rightWall.bodyCenter(foot: CGPoint(x: 950, y: 330), height: climbing.frame.height / FroggView.headroom * 0.9)
            climbing.frame.origin = NSPoint(x: c1.x - climbing.frame.width / 2, y: c1.y - climbing.frame.height / 2)
            v.addSubview(climbing)
            let hanging = FroggView(scale: 1.4, frameName: "idle_0")
            hanging.surface = .ceiling
            let c2 = Surface.ceiling.bodyCenter(foot: CGPoint(x: 760, y: 146), height: hanging.frame.height / FroggView.headroom * 0.9)
            hanging.frame.origin = NSPoint(x: c2.x - hanging.frame.width / 2, y: c2.y - hanging.frame.height / 2)
            v.addSubview(hanging)
            pet("frogg", "emotion_curious", feet: CGPoint(x: 230, y: 251), in: v, mirrored: false)
            PixlSkins.currentID = "frogg"
            try png(v, "\(out)/11-roam.png")
        }

        // Text channels: voice (sounds only), a notice card (plain English, led by a sound), and status narration
        do {
            let v = desktop()
            let pets: [(String, String, Notice, String)] = [
                ("frogg", "ribbit!", .replaced, "Frogg is practicing his croak."),
                ("cat", "mrrp?", .noDevices, "Kiti is judging you."),
                ("widow", "tk tk", .copied, "Silky is climbing the walls."),
            ]
            for (i, (skin, sound, notice, status)) in pets.enumerated() {
                let x = 40 + CGFloat(i) * 310
                pet(skin, "idle_0", feet: CGPoint(x: x + 90, y: 470), in: v)
                PixlSkins.currentID = skin
                put(BubbleView(text: sound, look: solid), at: NSPoint(x: x + 50, y: 300), in: v)
                put(NoticeView(notice, voice: i == 0 ? "ribbit!" : nil, look: solid), at: NSPoint(x: x, y: 120), in: v)
                v.addSubview(Painting(frame: v.bounds) { _ in
                    let font = Theme.mono(11, .bold)
                    let w = (status as NSString).size(withAttributes: [.font: font]).width + 16
                    let r = NSRect(x: x, y: 500, width: w, height: 22)
                    Theme.ink.setFill(); r.insetBy(dx: 0, dy: 2).fill(); r.insetBy(dx: 2, dy: 0).fill()
                    (status as NSString).draw(at: NSPoint(x: r.minX + 8, y: r.minY + 4), withAttributes: [.font: font, .foregroundColor: Theme.paper])
                })
            }
            PixlSkins.currentID = "frogg"
            try png(v, "\(out)/12-channels.png")
        }
        PixlSkins.currentID = "frogg"
    }
}

/// A transparent overlay that runs a drawing closure (labels and pills above other views).
final class Painting: NSView {
    let draws: (NSRect) -> Void
    init(frame: NSRect, draws: @escaping (NSRect) -> Void) { self.draws = draws; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { draws(bounds) }
}
