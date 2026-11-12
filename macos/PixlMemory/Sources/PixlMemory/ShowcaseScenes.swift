import AppKit
import PixlAgents
import PixlMemoryKit
import PixlzCore

/// The demo video's scenes (showcase/SHOTLIST.md): every beat is a real feature, staged and
/// triggered on cue. Positions are on the main screen; the recording region frames them for a
/// 9:16 crop.
@MainActor
enum ShowcaseScenes {
    static var all: [ShowcaseScene] { [h1, f1, f2, f3, e1, f4, e2] + memoryScenes + agentScenes }

    // MARK: staging helpers

    /// The main screen's visible area, top-left global.
    static func screen(_ d: ShowcaseDirector) -> CGRect {
        NSScreen.screens.first.map { d.app.topLeft($0.visibleFrame) } ?? .zero
    }

    /// Frogg's mark for the Frogg scenes: the middle of the screen, standing on the floor.
    static func mark(_ d: ShowcaseDirector) -> CGPoint {
        let s = screen(d)
        return CGPoint(x: s.midX.rounded(), y: (s.maxY - 140).rounded())   // standing on the desk, above the bottom
    }

    /// The size the takes use (the user's own size setting isn't touched: live only, not saved).
    static let takeScale = 3.0

    /// Frogg (the app's own Pixl, not an actor) on his mark, idle, nothing open.
    static func frogg(on p: CGPoint, _ d: ShowcaseDirector) {
        let app = d.app
        cleanup()
        d.cleanDesk()
        parkCursor(d)
        if PixlSkins.currentID != "frogg" { app.setSkin("frogg") }
        app.sleep.held = true      // awake, out of the pond, no dozing mid-take
        app.menu.close(reason: "showcase")
        app.menu.closeCard()
        app.menu.closeList()
        app.cancelMotion()
        app.cancelAnimations()
        app.leaveSurface()
        app.userPlaced = true
        app.busy = true            // no roaming, no idle quirks during a take
        app.bubbleArea = app.topLeft(column(d))     // his bubbles stay inside the recorded column
        if app.settings.scale != takeScale { app.setSize(takeScale, live: true) }
        app.froggPanel.alphaValue = 1
        app.place(at: p)
        app.frogg.mirrored = false
        app.frogg.squash = CGSize(width: 1, height: 1)
        app.frogg.frameName = "idle_0"
    }

    /// The pointer out of the recorded region (the takes frame the middle of the screen).
    static func parkCursor(_ d: ShowcaseDirector) {
        let s = screen(d)
        CGWarpMouseCursorPosition(CGPoint(x: s.maxX - 60, y: s.minY + 60))
    }

    /// The landing spring on the app's Pixl (squash, overshoot, settle).
    static func spring(_ d: ShowcaseDirector, from amount: Double = 0.2) async {
        let s = DampedSpring(dampingRatio: 0.35, omega: 2 * .pi / 0.18)
        let start = d.app.now
        while d.app.now - start < 0.45 {
            let v = s.value(from: amount, to: 0, at: d.app.now - start)
            d.app.frogg.squash = CGSize(width: 1 + v, height: 1 - v)
            try? await Task.sleep(for: .milliseconds(16))
        }
        d.app.frogg.squash = CGSize(width: 1, height: 1)
    }

    /// A happy hop on the spot, with squash on take-off and landing.
    static func hop(_ d: ShowcaseDirector, height: CGFloat = 30) async {
        let app = d.app
        guard let base = app.foot else { return }
        app.frogg.squash = CGSize(width: 1.12, height: 0.88)
        try? await Task.sleep(for: .milliseconds(70))
        Sfx.shared.play(.whoosh)
        let start = app.now, dur = 0.38
        app.frogg.frameName = "move_1"
        while true {
            let t = min(1, (app.now - start) / dur)
            app.frogg.squash = CGSize(width: 0.94, height: 1.08)
            app.place(at: CGPoint(x: base.x, y: base.y - height * CGFloat(4 * t * (1 - t))))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        app.frogg.frameName = "idle_0"
        Sfx.shared.play(.thud)
        await spring(d, from: 0.22)
    }

    // MARK: H1 · handoff

    /// Full black, Frogg big in the middle, idling (matching the last frame of the intro clip);
    /// then the stage zooms out to a clean desktop and he lands on his mark.
    static var startScale: CGFloat {
        CGFloat(Double(ProcessInfo.processInfo.environment["PIXL_SHOWCASE_START_SCALE"] ?? "") ?? 5.55)
    }
    /// Where the intro clip leaves him, as a fraction of the take's column: the middle of his
    /// body across, the bottom of his feet down (measured on the clip's last frame).
    static let startAt = CGPoint(x: 0.4085, y: 0.753)

    static let h1 = ShowcaseScene(id: "H1", title: "Handoff from the intro clip", setup: { d in
        let s = screen(d)
        let stage = d.stageOverlay()
        stage.backdrop = (.black, 1)
        stage.panel.order(.above, relativeTo: d.app.froggPanel.windowNumber)
        frogg(on: mark(d), d)
        d.app.froggPanel.alphaValue = 0
        // where the intro clip's last frame has him (his feet sit a little above the bottom of his canvas)
        let col = column(d)
        let big = ShowcaseActor("frogg", at: CGPoint(x: (col.minX + col.width * startAt.x).rounded(),
                                                     y: (col.minY + col.height * startAt.y + 1.3 * startScale).rounded()), scale: startScale, app: d.app)
        big.panel.order(.above, relativeTo: stage.panel.windowNumber)
        h1Actor = big
        // holding the intro clip's pose (eyes open); a quick blink now and then
        h1Idle = Task { @MainActor in
            while !Task.isCancelled {
                big.frame = "idle_0"
                try? await Task.sleep(for: .milliseconds(3400))
                if Task.isCancelled { return }
                big.frame = "blink"
                try? await Task.sleep(for: .milliseconds(140))
            }
        }
    }, beats: [
        ShowcaseBeat(name: "zoom out to the desktop", hold: 1.2) { d in
            guard let big = h1Actor, let stage = d.stage else { return }
            h1Idle?.cancel()
            big.frame = "idle_0"
            let start = d.app.now
            let fade = Task { @MainActor in
                while d.app.now - start < 1.3 {
                    let t = (d.app.now - start) / 1.3
                    stage.backdrop = (.black, CGFloat(1 - t * t))
                    try? await Task.sleep(for: .milliseconds(16))
                }
                stage.backdrop = nil
            }
            await big.zoom(to: mark(d), scale: d.app.scale, duration: 1.3)
            await fade.value
            d.app.froggPanel.alphaValue = 1
            big.remove()
            h1Actor = nil
            Sfx.shared.play(.thud)
            await spring(d)
        },
    ])
    static var h1Actor: ShowcaseActor?
    static var h1Idle: Task<Void, Never>?

    // MARK: F1 · fly snack

    static let f1 = ShowcaseScene(id: "F1", title: "Fly snack", setup: { d in
        frogg(on: mark(d), d)
        d.stageOverlay().flyScale = 1.6
    }, beats: [
        ShowcaseBeat(name: "a fly loops; his eyes follow it", hold: 0.2) { d in
            let stage = d.stageOverlay()
            let c = d.head
            let start = d.app.now, dur = 2.6
            Sfx.shared.play(.whoosh)
            while d.app.now - start < dur {
                let t = d.app.now - start
                // a loose figure-eight in front of him, drifting in
                let r = 110 - 40 * CGFloat(t / dur)
                let p = CGPoint(x: c.x + r * CGFloat(sin(t * 2.4)) + 40, y: c.y - 70 + r * 0.45 * CGFloat(sin(t * 4.8)))
                stage.fly = p
                d.app.frogg.mirrored = p.x < c.x
                d.app.frogg.frameName = p.y < c.y - 60 ? "emotion_curious" : "idle_0"
                try? await Task.sleep(for: .milliseconds(16))
            }
        },
        ShowcaseBeat(name: "tongue snap, gulp, a satisfied blink", hold: 1.0) { d in
            let stage = d.stageOverlay()
            guard let fly = stage.fly else { return }
            // the tell: coil and puff
            d.app.frogg.frameName = "mischief_0"
            d.app.frogg.squash = CGSize(width: 1.08, height: 0.9)
            for i in 0...8 { stage.throat = (d.mouth, Double(i) / 8); try? await Task.sleep(for: .milliseconds(20)) }
            stage.throat = nil
            // strike
            Sfx.shared.play(.snap)
            d.app.frogg.frameName = "poke_1"
            d.app.frogg.squash = CGSize(width: 0.94, height: 1.08)
            let m = d.mouth
            for i in 1...6 {
                let k = CGFloat(i) / 6
                stage.tongue = (m, CGPoint(x: m.x + (fly.x - m.x) * k, y: m.y + (fly.y - m.y) * k), 3, false)
                try? await Task.sleep(for: .milliseconds(15))
            }
            stage.tongue = (m, fly, 2, true)                      // hit-stop at full reach
            try? await Task.sleep(for: .milliseconds(70))
            for i in stride(from: 5, through: 0, by: -1) {       // back in, with the fly
                let k = CGFloat(i) / 6
                let tip = CGPoint(x: m.x + (fly.x - m.x) * k, y: m.y + (fly.y - m.y) * k)
                stage.tongue = (m, tip, 2, false)
                stage.fly = tip
                try? await Task.sleep(for: .milliseconds(18))
            }
            stage.tongue = nil
            stage.fly = nil
            // gulp
            Sfx.shared.play(.gulp)
            d.app.frogg.frameName = "emotion_proud"
            await spring(d, from: -0.1)
            for i in 0...10 { stage.throat = (d.mouth, 0.8 * sin(Double(i) / 10 * .pi)); try? await Task.sleep(for: .milliseconds(30)) }
            stage.throat = nil
            try? await Task.sleep(for: .milliseconds(350))
            d.app.frogg.frameName = "blink"                       // satisfied
            try? await Task.sleep(for: .milliseconds(380))
            d.app.frogg.frameName = "idle_0"
        },
    ])

    // MARK: F2 · wallet

    static let f2 = ShowcaseScene(id: "F2", title: "Frogg's wallet", setup: { d in
        frogg(on: mark(d), d)
        _ = d.stageOverlay()
    }, beats: [
        ShowcaseBeat(name: "a coin pops over him, ding", hold: 0.5) { d in
            let stage = d.stageOverlay()
            stage.coinBurst(at: CGPoint(x: d.head.x, y: d.head.y - 8), count: 5, now: d.app.now)
            Sfx.shared.play(.coin)
            try? await Task.sleep(for: .milliseconds(160))
            Sfx.shared.play(.ding)
            await hop(d, height: 18)
        },
        ShowcaseBeat(name: "his wallet: account, balance, last receipt", hold: 2.4) { d in
            // fetched under the spinner, so the card opens already filled
            d.app.menu.wallet = await d.live("wallet") { await d.app.client.wallet() }
            d.app.menu.showWallet()
            Sfx.shared.play(.pop)
            cardIntoFrame(d)
        },
        ShowcaseBeat(name: "the same payment on the testnet explorer", hold: 1.2) { d in
            let receipts = await d.live("payments") { await d.app.client.payments(limit: 5) }
            guard let url = receipts.first(where: { $0.status == "paid" })?.explorer.flatMap(URL.init(string:)) else {
                Debug.log("showcase: no paid receipt to show on the explorer yet"); return
            }
            d.app.menu.closeCard()
            await chrome(url, d)
            perch(on: chromeID, d)
        },
    ])

    // MARK: F3 · private brain

    static let f3 = ShowcaseScene(id: "F3", title: "A private brain", setup: { d in
        frogg(on: mark(d), d)
        _ = d.stageOverlay()
    }, beats: [
        ShowcaseBeat(name: "a brain with a padlock glows above him", hold: 0.9) { d in
            let stage = d.stageOverlay()
            stage.brain = (CGPoint(x: d.head.x, y: d.head.y - 56), d.app.now)
            Sfx.shared.play(.pop)
            d.app.frogg.frameName = "emotion_curious"
        },
        ShowcaseBeat(name: "click: the attestation card (verified · TEE · NEAR AI)", hold: 3.0) { d in
            let stage = d.stageOverlay()
            if let b = stage.brain { await ScriptedCursor.click(at: b.at) }
            parkCursor(d)
            let v = await d.live("attestation") { await d.app.client.attestation() }
            Sfx.shared.play(.chime)
            d.app.frogg.frameName = "emotion_happy"
            guard let v else { d.app.notify(.agentsError("Attestation unavailable right now.")); return }
            var rows = [ListMenuView.Row(id: "v", title: v.badge.contains("TEE") ? "\(v.badge) · NEAR AI" : "\(v.badge) · TEE · NEAR AI", icon: v.verdict == "verified" ? "check" : "warn", enabled: false),
                        ListMenuView.Row(id: "n", title: "\(v.passed)/\(v.checks.count) checks passed · \(v.model)", icon: nil, enabled: false)]
            rows += v.checks.filter { $0.status == "pass" }.prefix(5).enumerated().map { i, c in
                ListMenuView.Row(id: "c\(i)", title: "✓ " + c.label, icon: nil, enabled: false)
            }
            d.app.menu.showList(rows, near: nil) { _ in }
        },
    ])

    // MARK: E1 · friends

    /// Where the lineup stands: two each side of Frogg; Silky hangs above on her thread.
    /// The lineup's size: five across the 9:16 column.
    static let lineupScale = 2.0

    static func lineup(_ d: ShowcaseDirector) -> [(id: String, at: CGPoint)] {
        let m = mark(d), gap = (column(d).width / 5.2).rounded()
        return [("cat", CGPoint(x: m.x - 2 * gap, y: m.y)), ("shiba", CGPoint(x: m.x - gap, y: m.y)),
                ("ghost", CGPoint(x: m.x + gap, y: m.y)), ("slugg", CGPoint(x: m.x + 2 * gap, y: m.y)),
                ("widow", CGPoint(x: m.x, y: m.y - d.app.spriteSize.height * 1.9))]
    }
    static var cast: [ShowcaseActor] = []

    static func clearCast() { cast.forEach { $0.remove() }; cast = [] }

    /// Everything an earlier setup or take left on stage (setups can run twice: select, then run).
    static func cleanup() {
        clearCast()
        h1Idle?.cancel(); h1Idle = nil
        h1Actor?.remove(); h1Actor = nil
        w1Z?.cancel(); w1Z = nil
        cardKeeper?.cancel(); cardKeeper = nil
    }

    static let e1 = ShowcaseScene(id: "E1", title: "The Pixlz", setup: { d in
        frogg(on: mark(d), d)
        d.app.setSize(lineupScale, live: true)
        d.app.place(at: mark(d))
        _ = d.stageOverlay()
    }, beats: [
        ShowcaseBeat(name: "friends enter from both sides and drop from the top", hold: 0.3) { d in
            let s = screen(d), sc = d.app.scale
            let spots = Dictionary(uniqueKeysWithValues: lineup(d).map { ($0.id, $0.at) })
            @MainActor func actor(_ id: String, _ p: CGPoint) -> ShowcaseActor { let a = ShowcaseActor(id, at: p, scale: sc, app: d.app); cast.append(a); return a }
            let kiti = actor("cat", CGPoint(x: s.minX - 80, y: spots["cat"]!.y))
            let mochi = actor("shiba", CGPoint(x: s.minX - 160, y: spots["shiba"]!.y))
            let boo = actor("ghost", CGPoint(x: s.maxX + 80, y: spots["ghost"]!.y))
            let slugg = actor("slugg", CGPoint(x: spots["slugg"]!.x, y: s.minY - 200))
            let silky = actor("widow", CGPoint(x: spots["widow"]!.x, y: s.minY - 120))
            silky.thread = CGPoint(x: spots["widow"]!.x, y: s.minY)
            Sfx.shared.play(.whoosh)
            async let a: () = kiti.walk(to: spots["cat"]!, duration: 1.3, frames: (0..<8).map { "walk_\($0)" })
            async let b: () = mochi.walk(to: spots["shiba"]!, duration: 1.1, frames: (0..<6).map { "trot_\($0)" }, fps: 12)
            async let c: () = boo.walk(to: spots["ghost"]!, duration: 1.4, frames: ["idle_0", "idle_1"], fps: 3)
            try? await Task.sleep(for: .milliseconds(450))
            async let e: () = slugg.drop(to: spots["slugg"]!, from: spots["slugg"]!.y - s.minY + 60, duration: 0.6)
            async let f: () = silky.walk(to: spots["widow"]!, duration: 0.9, frames: ["idle_0"], fps: 1)
            _ = await (a, b, c, e, f)
            for x in [kiti, mochi, boo] { Task { await x.land() } }
            Sfx.shared.play(.thud)
            for x in [kiti, mochi, boo, slugg] { x.mirrored = x.foot.x > mark(d).x }
        },
        ShowcaseBeat(name: "“The Pixlz” pops in, ding", hold: 2.0) { d in
            let stage = d.stageOverlay()
            stage.title = ("THE PIXLZ", CGPoint(x: mark(d).x, y: screen(d).midY - 40), 64, d.app.now)
            Sfx.shared.play(.ding)
            await hop(d, height: 22)
        },
    ])

    // MARK: F4 · pays per thought

    static let f4 = ShowcaseScene(id: "F4", title: "Pays for its own thinking", setup: { d in
        frogg(on: mark(d), d)
        _ = d.stageOverlay()
    }, beats: [
        ShowcaseBeat(name: "he's asked a short question; it's answered privately and paid", hold: 3.2) { d in
            d.app.menu.showAsk()
            guard let card = d.app.menu.askCard else { return }
            keepAskInFrame(d, gap: 52)      // above him, clear of the coin pill that rises from his head
            let q = "What's a fly's favourite sport?"
            for ch in q { card.input.stringValue.append(ch); try? await Task.sleep(for: .milliseconds(45)) }
            try? await Task.sleep(for: .milliseconds(250))
            let before = await d.app.client.wallet()?.balanceNear
            card.submit()
            // the answer lands (inference, attestation and the testnet payment, all live)
            let landed = await d.live("ask") {
                let start = d.app.now
                while d.app.now - start < 90 {
                    if card.lastAnswer.isEmpty == false { return true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }
            guard landed else { return }
            let stage = d.stageOverlay()
            stage.coinBurst(at: CGPoint(x: d.head.x, y: d.head.y - 4), count: 3, now: d.app.now)
            Sfx.shared.play(.coin)
            let after = await d.app.client.wallet()?.balanceNear
            if let b = before, let a = after {
                stage.pop("\(b) → \(a) Ⓝ", at: CGPoint(x: d.head.x - 40, y: d.head.y - 20), now: d.app.now)
            }
            d.app.frogg.frameName = "emotion_happy"
        },
    ])

    // MARK: E2 · end

    static let e2 = ShowcaseScene(id: "E2", title: "Pixlz · powered by NEAR", setup: { d in
        frogg(on: mark(d), d)
        d.app.setSize(lineupScale, live: true)
        d.app.place(at: mark(d))
        _ = d.stageOverlay()
    }, beats: [
        ShowcaseBeat(name: "the Pixlz converge into one lineup", hold: 0.3) { d in
            let s = screen(d), sc = d.app.scale
            for (i, spot) in lineup(d).filter({ $0.id != "widow" }).enumerated() {
                let fromLeft = spot.at.x < mark(d).x
                let a = ShowcaseActor(spot.id, at: CGPoint(x: fromLeft ? s.minX - 100 - CGFloat(i) * 40 : s.maxX + 100 + CGFloat(i) * 40, y: spot.at.y),
                                      scale: sc, app: d.app)
                cast.append(a)
            }
            await withTaskGroup(of: Void.self) { g in
                for (a, spot) in zip(cast, lineup(d).filter { $0.id != "widow" }) {
                    let frames: [String] = a.art.frames["walk_0"] != nil ? (0..<8).map { "walk_\($0)" }
                        : a.art.frames["trot_0"] != nil ? (0..<6).map { "trot_\($0)" }
                        : a.art.frames["crawl_0"] != nil ? (0..<8).map { "crawl_\($0)" } : ["idle_0", "idle_1"]
                    g.addTask { await a.walk(to: spot.at, duration: 1.2, frames: frames, fps: 10); await a.land() }
                }
            }
            for a in cast { a.mirrored = a.foot.x > mark(d).x }
            Sfx.shared.play(.thud)
        },
        ShowcaseBeat(name: "“Pixlz · powered by NEAR”, ding, hold", hold: 2.0) { d in
            d.stageOverlay().title = ("PIXLZ\nPOWERED BY NEAR", CGPoint(x: mark(d).x, y: screen(d).midY - 40), 32, d.app.now)
            Sfx.shared.play(.ding)
            await withTaskGroup(of: Void.self) { g in
                for (i, a) in cast.enumerated() { g.addTask { try? await Task.sleep(for: .milliseconds(60 * i)); await a.hop(height: 20) } }
                g.addTask { await hop(d, height: 24) }
            }
        },
    ])

}

// MARK: - Memory and writing (M1–M3, W1)

@MainActor
extension ShowcaseScenes {
    static var memoryScenes: [ShowcaseScene] { [m1, m2, m3, w1] }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../showcase/demo").standardized
    static let articleURL = URL(string: "http://127.0.0.1:8766/glass-frogs.html")!
    static let highlight = "The skin on a glass frog's belly is so clear that you can watch its heart beat and its stomach fill."
    static var server: Process?
    static let chromeID = "com.google.Chrome", textEditID = "com.apple.TextEdit"

    /// The demo article, served from this Mac only (the extension and text-fragment links want http).
    static func serveDemoSite() {
        if let s = server, s.isRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", "8766", "--bind", "127.0.0.1", "--directory", repo.appending(path: "site").path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        server = p
    }

    /// The take's frame on screen (a 9:16 column in the middle): apps are sized into it.
    static func column(_ d: ShowcaseDirector) -> CGRect {
        let s = screen(d)
        let h = min(960, s.height - 40), w = (h * 9 / 16).rounded()
        return CGRect(x: (s.midX - w / 2).rounded(), y: s.maxY - h, width: w, height: h)
    }

    static func app(_ id: String) -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: id).first }

    /// Opens `url` in Chrome, brings it forward and sizes its window into the column.
    static func chrome(_ url: URL, _ d: ShowcaseDirector, top: CGFloat = 250) async {
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = true
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/Applications/Google Chrome.app"), configuration: conf)
        try? await Task.sleep(for: .milliseconds(900))
        await stageChrome(d, top: top)
    }

    /// Chrome's front window into the take's frame (retrying while macOS changes Space), on the desk.
    static func stageChrome(_ d: ShowcaseDirector, top: CGFloat = 250) async {
        guard let c = app(chromeID) else { return }
        c.activate()
        let col = column(d)
        let want = CGRect(x: col.minX, y: col.minY + top, width: col.width, height: col.height - top - 20)
        // the window may sit on another Space: macOS switches over after a moment, so keep at it
        for _ in 0..<12 {
            AX.setFrame(pid: c.processIdentifier, want)
            try? await Task.sleep(for: .milliseconds(250))
            if let f = AX.windowFrame(pid: c.processIdentifier), abs(f.minX - want.minX) < 4, abs(f.minY - want.minY) < 4,
               abs(f.width - want.width) < 4 { break }
        }
        AX.enableWebAccessibility(for: c)
        try? await Task.sleep(for: .milliseconds(500))
        d.cleanDesk(keeping: chromeID)
    }

    /// The Pixl on top of a window (its title bar), facing in.
    static func perch(on bundleID: String, _ d: ShowcaseDirector, at fraction: CGFloat = 0.72) {
        guard let a = app(bundleID), let f = AX.windowFrame(pid: a.processIdentifier) else { return }
        d.app.place(at: CGPoint(x: (f.minX + f.width * fraction).rounded(), y: f.minY))
    }

    /// Selects a phrase by dragging across it, like a person.
    static func select(_ phrase: String, in bundleID: String) async -> Bool {
        guard let a = app(bundleID), let b = AX.phraseBounds(pid: a.processIdentifier, phrase: phrase) else {
            Debug.log("showcase: can't find the phrase to select"); return false
        }
        await ScriptedCursor.drag(from: CGPoint(x: b.first.minX + 1, y: b.first.midY), to: CGPoint(x: b.last.maxX - 1, y: b.last.midY), duration: 1.1)
        return true
    }

    /// The Pixl's tongue to a point and back (grabbing something there).
    static func tongue(to p: CGPoint, _ d: ShowcaseDirector) async {
        let stage = d.stageOverlay()
        stage.panel.order(.above, relativeTo: d.app.froggPanel.windowNumber)
        let m = d.mouth
        Sfx.shared.play(.snap)
        d.app.frogg.frameName = "poke_1"
        for i in 1...7 { let k = CGFloat(i) / 7; stage.tongue = (m, CGPoint(x: m.x + (p.x - m.x) * k, y: m.y + (p.y - m.y) * k), 3, false); try? await Task.sleep(for: .milliseconds(14)) }
        stage.tongue = (m, p, 2, true)
        try? await Task.sleep(for: .milliseconds(80))
        for i in stride(from: 6, through: 0, by: -1) { let k = CGFloat(i) / 7; stage.tongue = (m, CGPoint(x: m.x + (p.x - m.x) * k, y: m.y + (p.y - m.y) * k), 2, false); try? await Task.sleep(for: .milliseconds(16)) }
        stage.tongue = nil
        d.app.frogg.frameName = "idle_0"
    }

    // M1 · highlight to memory

    static let m1 = ShowcaseScene(id: "M1", title: "Highlight to memory", setup: { d in
        serveDemoSite()
        frogg(on: mark(d), d)
        await chrome(articleURL, d)
        perch(on: chromeID, d)
    }, beats: [
        ShowcaseBeat(name: "highlight a passage", hold: 0.4) { d in
            _ = await select(highlight, in: chromeID)
        },
        ShowcaseBeat(name: "the tongue grabs it, sparkles, saved to memory", hold: 2.0) { d in
            guard let c = app(chromeID), let page = AX.webPage(pid: c.processIdentifier),
                  let sel = AX.selectedText(pid: c.processIdentifier), let b = AX.phraseBounds(pid: c.processIdentifier, phrase: highlight) else {
                Debug.log("showcase: nothing selected in the article"); return
            }
            let target = CGPoint(x: (b.first.minX + b.last.maxX) / 2, y: (b.first.midY + b.last.midY) / 2)
            await tongue(to: target, d)
            let link = TextFragment.link(page: page.url, passage: sel)
            let saved = await d.live("save") {
                try? await d.app.client.saveNote(sel, title: page.title, folder: nil, url: page.url.absoluteString, fragmentURL: link?.absoluteString)
            }
            guard saved != nil else { d.app.notify(.noteNotSaved); return }
            d.stageOverlay().sparkles(at: target, count: 7, radius: 46, now: d.app.now)
            Sfx.shared.play(.chime)
            d.app.notify(Notice(.done, "Saved to memory, with a link back to the passage.", seconds: 2.5))
            d.app.frogg.frameName = "blink"          // a smug blink
            try? await Task.sleep(for: .milliseconds(300))
            d.app.frogg.frameName = "emotion_proud"
        },
    ])

    // M2 · ask and retrieve (another window: the draft in TextEdit)

    static func openDraft(_ d: ShowcaseDirector, file name: String = "draft.txt") async {
        let file = repo.appending(path: name)
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = true
        _ = try? await NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: conf)
        try? await Task.sleep(for: .milliseconds(900))
        guard let t = app(textEditID) else { return }
        t.activate()
        let col = column(d)
        AX.setFrame(pid: t.processIdentifier, CGRect(x: col.minX, y: col.minY + 260, width: col.width, height: col.height - 380))
        try? await Task.sleep(for: .milliseconds(300))
        d.cleanDesk(keeping: textEditID)
    }

    /// Closes TextEdit's windows of a demo draft (its close button, as a person would), so the
    /// next take opens the file fresh. Other TextEdit windows are left alone.
    static func closeDraft(_ name: String) async {
        guard let t = app(textEditID) else { return }
        let windows: [AXUIElement] = AX.attr(AX.app(t.processIdentifier), kAXWindowsAttribute) ?? []
        var closed = false
        for w in windows where ((AX.attr(w, kAXTitleAttribute) as String?) ?? "").hasPrefix(name) {
            guard let b: AXUIElement = AX.attr(w, kAXCloseButtonAttribute) else { continue }
            AXUIElementPerformAction(b, kAXPressAction as CFString)
            closed = true
        }
        if closed { try? await Task.sleep(for: .milliseconds(600)) }
    }

    static let m2 = ShowcaseScene(id: "M2", title: "Ask, from memory", setup: { d in
        frogg(on: mark(d), d)
        await openDraft(d)
        perch(on: textEditID, d)
    }, beats: [
        ShowcaseBeat(name: "ask what the article said; it answers from memory, with its source", hold: 3.5) { d in
            d.app.menu.showAsk()
            guard let card = d.app.menu.askCard else { return }
            keepAskInFrame(d)
            let q = "What did that article say about glass frog skin?"
            for ch in q { card.input.stringValue.append(ch); try? await Task.sleep(for: .milliseconds(38)) }
            try? await Task.sleep(for: .milliseconds(250))
            d.app.frogg.frameName = "emotion_curious"
            card.submit()
            _ = await d.live("ask") {
                let start = d.app.now
                while d.app.now - start < 90, card.lastAnswer.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
            Sfx.shared.play(.pop)
            d.app.frogg.frameName = "emotion_happy"
        },
    ])

    // M3 · notes jump back

    static let m3 = ShowcaseScene(id: "M3", title: "Back to the passage", setup: { d in
        serveDemoSite()
        frogg(on: mark(d), d)
        await openDraft(d)
        perch(on: textEditID, d)
    }, beats: [
        ShowcaseBeat(name: "the memories panel pops in", hold: 1.4) { d in
            d.app.menu.closeCard()
            d.app.menu.showMemory()
            // the card opens once its rows load
            for _ in 0..<40 where d.app.menu.cardPanel == nil { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(60))
            cardIntoFrame(d)
            Sfx.shared.play(.pop)
        },
        ShowcaseBeat(name: "click the highlight: the page opens at the passage, glowing", hold: 2.5) { d in
            // the first saved highlight's row in the memory card
            guard let panel = d.app.menu.cardPanel, let row = firstHighlightRow(in: panel.contentView) else { return }
            let r = panel.convertToScreen(row.convert(row.bounds, to: nil))
            await ScriptedCursor.click(at: CGPoint(x: r.midX, y: d.app.primaryHeight - r.midY))
            try? await Task.sleep(for: .milliseconds(1200))
            d.app.menu.closeCard()
            await stageChrome(d)
        },
    ])

    /// The open card, moved inside the take's 9:16 frame: centered, above the Pixl if it fits there,
    /// else below it, never over it. `gap` is the space left between the card and the Pixl.
    static func cardIntoFrame(_ d: ShowcaseDirector, gap: CGFloat = 16) {
        guard let p = d.app.menu.cardPanel else { return }
        let col = column(d), f = p.frame, pet = d.app.topLeft(d.app.froggBox)
        let petTop = pet.maxY - FroggArt.shared.canvas.height * d.app.scale
        var y = petTop - gap - f.height                      // top-left y of the card, above the Pixl
        if y < col.minY + 20 { y = pet.maxY + 16 }          // no room: below
        let x = min(max(col.minX + 12, col.midX - f.width / 2), col.maxX - 12 - f.width)
        let o = NSPoint(x: x, y: d.app.primaryHeight - y - f.height)
        if o != f.origin { p.setFrameOrigin(o) }
    }

    /// The Ask card grows when its answer lands: this keeps it inside the frame (and off the Pixl)
    /// for as long as it is open.
    static func keepAskInFrame(_ d: ShowcaseDirector, gap: CGFloat = 16) {
        cardKeeper?.cancel()
        cardIntoFrame(d, gap: gap)
        cardKeeper = Task { @MainActor in
            while !Task.isCancelled, d.app.menu.askCard != nil, d.app.menu.cardPanel != nil {
                cardIntoFrame(d, gap: gap)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    static var cardKeeper: Task<Void, Never>?

    static func firstHighlightRow(in v: NSView?) -> NSView? {
        guard let v else { return nil }
        if v.accessibilityRole() == .link, (v.accessibilityLabel() ?? "").contains("glass frog") { return v }
        for s in v.subviews { if let r = firstHighlightRow(in: s) { return r } }
        return nil
    }

    // W1 · write in place

    static let intro = "hey so basically i wanted to reach out because i think maybe we could possibly do the launch next week if thats ok with everyone, but im not totally sure about the date yet and stuff"

    static let w1 = ShowcaseScene(id: "W1", title: "Write in place", setup: { d in
        frogg(on: mark(d), d)
        // a fresh copy of the clunky draft (the last take's copy is still open, changed by the drop)
        await closeDraft("draft-take")
        try? FileManager.default.removeItem(at: repo.appending(path: "draft-take.txt"))
        try? FileManager.default.copyItem(at: repo.appending(path: "draft.txt"), to: repo.appending(path: "draft-take.txt"))
        await openDraft(d, file: "draft-take.txt")
        perch(on: textEditID, d, at: 0.56)
        d.app.frogg.frameName = "rest_1"            // dozing nearby
        w1Z = Task { @MainActor in while !Task.isCancelled { d.app.puffZ(); try? await Task.sleep(for: .seconds(1.6)) } }
    }, beats: [
        ShowcaseBeat(name: "select the intro; the Pixl wakes and hops up", hold: 0.5) { d in
            _ = await select(intro, in: textEditID)
            w1Z?.cancel()
            d.app.frogg.frameName = "emotion_startled"
            Sfx.shared.play(.pop)
            try? await Task.sleep(for: .milliseconds(250))
            await hop(d, height: 34)
        },
        ShowcaseBeat(name: "polish this: the polished text in its card", hold: 1.5) { d in
            d.app.menu.open(trigger: "showcase")
            try? await Task.sleep(for: .milliseconds(700))
            d.app.menu.close(reason: "showcase")
            if ShowcaseDirector.rehearsing {
                await rehearsePolish(d)
            } else {
                await d.live("polish") {
                    d.app.polish(0)
                    let start = d.app.now
                    try? await Task.sleep(for: .milliseconds(300))
                    while d.app.now - start < 90, d.app.busy { try? await Task.sleep(for: .milliseconds(16)) }
                }
            }
            resultIntoFrame(d)
            Sfx.shared.play(.pop)
        },
        ShowcaseBeat(name: "drag it into the draft: it drops in place", hold: 2.0) { d in
            guard let panel = d.app.resultPanel, let card = findCard(panel.contentView),
                  let t = app(textEditID), let b = AX.phraseBounds(pid: t.processIdentifier, phrase: String(intro.prefix(30))) else { return }
            let r = panel.convertToScreen(card.convert(card.bounds, to: nil))
            await ScriptedCursor.drag(from: CGPoint(x: r.midX, y: d.app.primaryHeight - r.midY), to: CGPoint(x: b.first.minX + 30, y: b.first.midY), duration: 1.2)
            Sfx.shared.play(.chime)
            d.stageOverlay().sparkles(at: CGPoint(x: b.first.minX + 60, y: b.first.midY), now: d.app.now)
            await hop(d, height: 20)
        },
    ])
    static var w1Z: Task<Void, Never>?

    /// The polish card where the take can see it: over the empty part of the draft window, under
    /// its lines (beside the Pixl it would open outside the recorded column).
    static func resultIntoFrame(_ d: ShowcaseDirector) {
        guard let p = d.app.resultPanel else { return }
        let col = column(d), f = p.frame
        let top = min(col.minY + 260 + 140, col.maxY - 24 - f.height)       // top-left y
        p.setFrameOrigin(NSPoint(x: (col.midX - f.width / 2).rounded(), y: d.app.primaryHeight - top - f.height))
    }

    /// `--rehearse`: a stand-in card that says what it is, instead of asking the model. For
    /// checking where things land in the frame without an inference or a payment. Never a take.
    static func rehearsePolish(_ d: ShowcaseDirector) async {
        let stand = "REHEARSAL, not a model answer. This stand-in only checks where the card opens and where the dragged text lands in the draft."
        let json = """
        {"draft_id": "rehearsal", "suggestion": "\(stand)",
         "diff": [{"op": "delete", "text": "\(intro)"}, {"op": "insert", "text": "\(stand)"}],
         "verification": {"verdict": "offline", "summary": "Rehearsal: nothing was sent to a model and nothing was paid.", "checks": [], "model": "rehearsal"},
         "receipt": {"status": "refused", "reason": "rehearsal, nothing to pay for"}}
        """
        guard let r = try? JSONDecoder().decode(PolishResult.self, from: Data(json.utf8)) else { return }
        Debug.log("showcase: REHEARSAL polish (no inference, no payment)")
        d.app.polishedText = d.app.pendingSelection?.text
        d.app.polishedElement = d.app.selectionElement
        try? await Task.sleep(for: .seconds(1.5))
        d.app.showResult(.result(r, instruction: "Polish", app: "TextEdit"))
    }

    static func findCard(_ v: NSView?) -> NSView? {
        guard let v else { return nil }
        if String(describing: type(of: v)) == "SuggestionCard" { return v }
        for s in v.subviews { if let c = findCard(s) { return c } }
        return nil
    }
}


// MARK: - Coding agents (C1–C3)

@MainActor
extension ShowcaseScenes {
    static var agentScenes: [ShowcaseScene] { [c1, c2, c3] }
    static let terminalID = "com.apple.Terminal"

    /// Runs one of the demo's .command scripts in a new Terminal window, standing on the desk
    /// inside the column (so a Pixl can climb its side), and keeps only that window on the desk.
    static func terminal(_ script: String, _ d: ShowcaseDirector, height: CGFloat = 420) async {
        let conf = NSWorkspace.OpenConfiguration()
        conf.activates = true
        _ = try? await NSWorkspace.shared.open([repo.appending(path: script)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                               configuration: conf)
        try? await Task.sleep(for: .milliseconds(1200))
        guard let t = app(terminalID) else { return }
        t.activate()
        let col = column(d), s = screen(d)
        AX.setFrame(pid: t.processIdentifier, CGRect(x: col.minX + 70, y: s.maxY - height, width: col.width - 90, height: height))
        try? await Task.sleep(for: .milliseconds(300))
        d.cleanDesk(keeping: terminalID)
    }

    // C1 · tests: Slugg rounds the Terminal's corner as they go green

    static let c1 = ShowcaseScene(id: "C1", title: "Tests, with Slugg", setup: { d in
        frogg(on: mark(d), d)
        if PixlSkins.currentID != "slugg" { d.app.setSkin("slugg") }
        try? await Task.sleep(for: .milliseconds(500))
        let col = column(d), s = screen(d)
        d.app.place(at: CGPoint(x: col.minX + 48, y: s.maxY))     // on the desk, left of where the Terminal stands
    }, beats: [
        ShowcaseBeat(name: "swift test in the demo repo; Slugg climbs and rounds the corner", hold: 4.0) { d in
            await terminal("run-tests.command", d)
            try? await Task.sleep(for: .milliseconds(400))
            // beside the Terminal, on the desk (whatever he did meanwhile)
            d.app.cancelMotion()
            d.app.place(at: CGPoint(x: column(d).minX + 48, y: screen(d).maxY))
            d.app.busy = false
            // the Terminal may still be settling into place: look again for a few seconds
            for i in 0..<12 {
                var w = d.app.roam.world()
                w.avoid = []
                var p = d.app.roam.planner
                if let o = p.outing(named: "overWindow", w) { d.app.roam.go(o, debug: true); break }
                if i == 11 {
                    Debug.log("showcase: no window for Slugg to climb (foot \(w.foot), floor \(w.screen.maxY), windows \((w.active.map { [$0] } ?? []) + w.others))")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        },
    ])

    // C2 · guard: a risky command, a red ribbit, Deny, a stomp

    static func waitForRequest(_ d: ShowcaseDirector) async -> AgentRequest? {
        await d.live("permission request") {
            let start = d.app.now
            while d.app.now - start < 120 {
                if let r = d.app.agents.hub.requests.last, d.app.agents.canAnswer(r.id) { return r }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }
    }

    static let c2 = ShowcaseScene(id: "C2", title: "Guard on a risky command", setup: { d in
        frogg(on: mark(d), d)
        d.app.agents.answerHere = true       // Allow / Deny from Pixlz
        d.app.agents.replyHere = true        // and hold finished turns for a reply (C3)
    }, beats: [
        ShowcaseBeat(name: "a Claude Code session asks to run rm -rf build && npm run deploy", hold: 0.2) { d in
            await terminal("run-claude.command", d, height: 560)
            _ = await waitForRequest(d)
        },
        ShowcaseBeat(name: "the Pixl leaps onto the Terminal, alert, red ribbit", hold: 0.6) { d in
            guard let t = app(terminalID), let f = AX.windowFrame(pid: t.processIdentifier), let from = d.app.foot else { return }
            let to = CGPoint(x: (f.minX + f.width * 0.7).rounded(), y: f.minY)
            Sfx.shared.play(.whoosh)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                d.app.run(Choreography.hop(d.app.route(from: from, to: to)), target: to) { c.resume() }
            }
            d.app.busy = true
            d.app.frogg.frameName = "emotion_startled"
            Sfx.shared.play(.ribbit)
            d.app.exclaim("RIBBIT!", for: 1.6)
            await spring(d, from: 0.18)
            if let r = d.app.agents.hub.requests.last { d.app.menu.showRequest(r.id) }
        },
        ShowcaseBeat(name: "Deny; it stomps", hold: 1.4) { d in
            guard let l = d.app.menu.listPanel, let deny = findRow("Deny", in: l.contentView) else { return }
            let r = l.convertToScreen(deny.convert(deny.bounds, to: nil))
            await ScriptedCursor.click(at: CGPoint(x: r.midX, y: d.app.primaryHeight - r.midY))
            // the stomp: a hard squash, a thud, a little shake
            d.app.frogg.frameName = "emotion_annoyed"
            d.app.frogg.squash = CGSize(width: 1.28, height: 0.74)
            Sfx.shared.play(.thud)
            try? await Task.sleep(for: .milliseconds(90))
            await spring(d, from: 0.25)
            d.app.frogg.frameName = "emotion_proud"
            parkCursor(d)
        },
    ])

    static func findRow(_ title: String, in v: NSView?) -> NSView? {
        guard let v else { return nil }
        if (v.accessibilityLabel() ?? "").hasPrefix(title) { return v }
        for s in v.subviews { if let r = findRow(title, in: s) { return r } }
        return nil
    }

    // C3 · reply: "done, anything else?" → a reply → Claude carries on

    static let c3 = ShowcaseScene(id: "C3", title: "Reply to a finished session", setup: { d in
        d.app.agents.replyHere = true
    }, beats: [
        ShowcaseBeat(name: "the session finishes; the Pixl asks “done, anything else?”", hold: 0.6) { d in
            _ = await d.live("the session's turn ends") {
                let start = d.app.now
                while d.app.now - start < 180, d.app.agents.doneAsked == nil { try? await Task.sleep(for: .milliseconds(200)) }
            }
            Sfx.shared.play(.pop)
            d.app.frogg.frameName = "emotion_curious"
        },
        ShowcaseBeat(name: "a reply typed into its bubble; Claude carries on", hold: 3.0) { d in
            guard let sid = d.app.agents.doneAsked else { return }
            d.app.menu.closeList()
            d.app.chats.open(sid)
            try? await Task.sleep(for: .milliseconds(500))
            guard let panel = d.app.chats.panels[sid] else { return }
            panel.focusField()
            let reply = "No deploy today. Just run the tests."
            for ch in reply { panel.input.stringValue.append(ch); try? await Task.sleep(for: .milliseconds(40)) }
            let b = panel.sendButton
            let r = panel.window.convertToScreen(b.convert(b.bounds, to: nil))
            await ScriptedCursor.click(at: CGPoint(x: r.midX, y: d.app.primaryHeight - r.midY))   // Send (a real click)
            Sfx.shared.play(.whoosh)
            await hop(d, height: 18)
            parkCursor(d)
        },
    ])
}
