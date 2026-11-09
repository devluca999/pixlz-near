import AppKit
import PixlMemoryKit
import PixlzCore
import QuartzCore

/// The pet mini-games (Direction C16): Slugg "Inevitable" and Frogg "Snap" (rules in PixlzCore
/// `ChaseGame` / `SnapGame`), and Kiti's Laser chase. The pet acts, you respond. Everything is
/// drawn on a click-through overlay: the real cursor is never moved, hidden or blocked, and no
/// file or window is touched. Typing, or a click in another app, ends a game at once.
/// The loop runs on the display's clock, and only while a game is on.
@MainActor
final class GameController {
    unowned let app: AppController

    enum Kind: String { case inevitable, snap, laser }

    // the round in play
    var chase: ChaseGame?
    var snap: SnapGame?
    var laser: LaserChase?
    var kind: Kind?
    var isOn: Bool { kind != nil }

    // drawing and input
    var overlay: GameOverlay?
    var ticker: DisplayTicker?
    var dotPanel: OverlayPanel?
    var monitors: [Any] = []          // NSEvent monitors
    var observers: [NSObjectProtocol] = []   // workspace notifications
    var lastStep: TimeInterval = 0
    /// Hit-stop: the pet and the round hold still until then.
    var frozenUntil: TimeInterval = 0
    /// When a squash/stretch spring started, and its size.
    var springAt: TimeInterval = -10
    var springAmount = 0.0
    var homeFoot: CGPoint?
    var inviteTimer: Timer?
    var lastWobble: TimeInterval = 0

    init(app: AppController) {
        self.app = app
        // Chaos only: now and then a pet invites you (2 s, ignorable)
        inviteTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maybeInvite() }
        }
    }

    // MARK: which game

    var petID: String { PixlSkins.currentID }
    /// This pet's own game, if it has one.
    var ownGame: Kind? {
        switch petID {
        case "slugg": .inevitable
        case "frogg": .snap
        case "cat": .laser
        default: nil
        }
    }
    static func title(_ k: Kind) -> String {
        switch k { case .inevitable: "Inevitable"; case .snap: "Snap"; case .laser: "Laser chase" }
    }
    static func owner(_ k: Kind) -> String {
        switch k { case .inevitable: "Slugg"; case .snap: "Frogg"; case .laser: "Kiti" }
    }
    static func blurb(_ k: Kind) -> String {
        switch k {
        case .inevitable: "Slugg chases. Survive 60 s"
        case .snap: "Frogg strikes. Dodge for 60 s"
        case .laser: "Keep the dot away from Kiti"
        }
    }

    // MARK: records (best per pet, for the status line)

    static let recordsKey = "PixlMemory.gameRecords"
    var records: GameRecords {
        get { (UserDefaults.standard.data(forKey: Self.recordsKey)).flatMap { try? JSONDecoder().decode(GameRecords.self, from: $0) } ?? GameRecords() }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.recordsKey) }
    }
    /// "Best: Inevitable 1:12 · Snap 9 dodges", or nil before any game.
    var statusLine: String? {
        let r = records.best
        var parts: [String] = []
        if let s = r["slugg"] { parts.append("Inevitable \(Self.clock(s.seconds))") }
        if let f = r["frogg"] { parts.append("Snap \(f.count) dodge\(f.count == 1 ? "" : "s")") }
        if let k = r["cat"] { parts.append("Laser \(k.count)") }
        return parts.isEmpty ? nil : "Best: " + parts.joined(separator: " · ")
    }
    static func clock(_ s: Double) -> String { let n = Int(s.rounded(.down)); return "\(n / 60):" + String(format: "%02d", n % 60) }

    // MARK: start

    /// Whether a game may start now: not in Focus, fullscreen, hidden or asleep.
    var blocked: String? {
        if isOn { return "a game is on" }
        if app.focusUntil.map({ $0 > Date() }) == true { return "Focus" }
        if app.fullscreenHidden { return "fullscreen" }
        if app.userHidden { return "hidden" }
        if app.foot == nil { return "not placed" }
        return nil
    }

    /// From Play (or the debug driver): the pet's own game, straight in.
    func start() { if let k = ownGame { start(k) } }

    func start(_ k: Kind, invite: Bool = false) {
        if let why = blocked { Debug.log("game: not now (\(why))"); return }
        guard k == ownGame, let foot = app.foot else { Debug.log("game: \(k) isn't \(petID)'s game"); return }
        if k == .laser { startLaser(foot); return }
        app.menu.close(reason: "game")
        app.cancelMotion()
        app.cancelAnimations()
        app.leaveSurface()
        app.busy = true
        homeFoot = foot
        kind = k
        let now = app.now
        let screen = app.screensTopLeft.first { $0.insetBy(dx: -4, dy: -4).contains(foot) } ?? app.screensTopLeft.first ?? .zero
        let scale = Double(app.scale)
        switch k {
        case .inevitable:
            let head = CGPoint(x: foot.x, y: foot.y - app.spriteSize.height * 0.3)
            let round: TimeInterval = app.settings.chaos ? 90 : 60
            chase = ChaseGame(head: head, heading: app.mouseTopLeft.x < foot.x ? .pi : 0, bounds: screen, scale: scale,
                              body: Double(app.spriteSize.width) * 0.9, round: round, invite: invite, now: now)
            app.trail.lengthBodies = 4
            app.exclaim(invite ? "…" : "…", for: 1.6)
            app.frogg.frameName = "emotion_curious"
        case .snap:
            snap = SnapGame(seed: UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF, scale: scale, invite: invite, now: now)
            app.frogg.frameName = "emotion_curious"
            if invite { app.exclaim("ribbit?", for: 1.8) }
        case .laser: break
        }
        Debug.log("game start \(k.rawValue)\(invite ? " (invite)" : "")")
        openOverlay(on: screen)
        watchForWork()
        lastStep = now
        ticker = DisplayTicker(view: overlay!.view) { [weak self] in self?.tick() }
    }

    /// Chaos: a 2 s invite now and then, only when you're idle and not typing, never in Focus,
    /// fullscreen or while sharing the screen.
    func maybeInvite() {
        guard app.settings.chaos, blocked == nil, let k = ownGame, k != .laser,
              !app.menu.isOpen, !app.moving, app.mode == .perched, !app.sleep.dozing, !Self.screenShared,
              Double.random(in: 0..<1) < 0.12 else { return }
        // not mid-typing: no key for 20 s; you're here: the mouse moved in the last 10 s
        let key = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        guard key > 20, mouse < 10 else { return }
        Debug.log("game: invite")
        start(k, invite: true)
    }

    /// Screen sharing or recording: another process is capturing the display. macOS has no public
    /// signal for it; the menu bar's sharing indicator process is the closest one.
    static var screenShared: Bool {
        NSWorkspace.shared.runningApplications.contains { ["com.apple.screensharing.agent", "com.apple.ScreenContinuity"].contains($0.bundleIdentifier ?? "") }
    }

    // MARK: work wins

    func watchForWork() {
        // typing anywhere, or a click outside the Pixl: the game ends at once
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.interrupt(e.type == .keyDown ? "typing" : "click elsewhere") }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.interrupt(e.keyCode == 53 ? "esc" : "typing") }
            return e.keyCode == 53 ? nil : e
        }) { monitors.append(m) }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if a != .current { self?.interrupt("another app") } }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt("space change") }
        })
    }

    /// A click on the Pixl during a game (the app routes it here instead of a grab).
    /// Returns true when the game used it.
    func clickedPet() -> Bool {
        guard isOn else { return false }
        let now = app.now
        if var g = chase {
            if case .invite = g.phase { g.accept(now: now); chase = g; Debug.log("game: invite accepted"); return true }
            if g.bonk(now: now) {
                chase = g
                Debug.log("game: bonk \(g.bonks)")
                frozenUntil = now + 0.05                       // hit-stop on the click
                spring(0.18, at: now)
                app.frogg.frameName = "seal_1"
                overlay?.star(at: app.mouseTopLeft, now: now)
                overlay?.pop("bonk!", at: app.mouseTopLeft, now: now)
            }
            chase = g
            return true
        }
        if var g = snap {
            if case .invite = g.phase { g.accept(now: now); snap = g; Debug.log("game: invite accepted"); return true }
            return true   // clicking Frogg does nothing in Snap, but doesn't end it either
        }
        return false
    }

    func interrupt(_ why: String) {
        guard isOn, kind != .laser else { if kind == .laser { end(early: true) }; return }
        let now = app.now
        if var g = chase { _ = g.interrupt(now: now); chase = g }
        if var g = snap { _ = g.interrupt(now: now); snap = g }
        Debug.log("game: interrupted (\(why))")
        let wasChase = chase != nil
        stop()
        // turn away, heavy lids: "…another time." No score, no penalty.
        app.frogg.mirrored.toggle()
        app.frogg.frameName = wasChase ? "emotion_sleepy" : "emotion_annoyed"
        app.exclaim("…another time", for: 2)
        app.later(2) { [weak self] in self?.app.frogg.mirrored = false; self?.settleHome() }
    }

    /// Esc or the menu: same as an interrupt (a game never nags).
    func end(early: Bool) {
        guard isOn else { return }
        if kind == .laser { stopLaser(); app.backToIdle(); return }
        interrupt("ended")
    }

    // MARK: the loop

    func tick() {
        let now = app.now
        guard isOn else { return }
        defer { lastStep = now }
        if now < frozenUntil { overlay?.redraw(now: now); return }   // hit-stop
        let mouse = app.mouseTopLeft
        if chase != nil { stepChase(now, mouse) }
        if snap != nil { stepSnap(now, mouse) }
        applySpring(now)
        overlay?.petBox = app.topLeft(app.froggBox)
        overlay?.redraw(now: now)
    }

    func spring(_ amount: Double, at now: TimeInterval) { springAt = now; springAmount = amount }

    /// Squash and stretch from the spring helper: a little overshoot, settled in ~160 ms.
    func applySpring(_ now: TimeInterval) {
        let t = now - springAt
        guard t < 0.5 else { return }
        let s = DampedSpring(dampingRatio: 0.32, omega: 2 * .pi / 0.16)
        let v = s.value(from: springAmount, to: 0, at: t)
        app.frogg.squash = CGSize(width: 1 + v, height: 1 - v)
    }

    // MARK: Slugg · Inevitable

    func stepChase(_ now: TimeInterval, _ mouse: CGPoint) {
        guard var g = chase else { return }
        let events = g.step(now: now, cursor: mouse)
        chase = g
        let dir = CGPoint(x: cos(g.heading), y: sin(g.heading))
        // he's drawn side-on: facing his way across, with a little tilt for up and down
        let facingLeft = dir.x < 0
        let foot = CGPoint(x: g.head.x - (facingLeft ? -1 : 1) * app.spriteSize.width * 0.42, y: g.head.y + app.spriteSize.height * 0.3)
        switch g.phase {
        case .invite:
            app.frogg.mirrored = mouse.x < app.foot?.x ?? 0
            app.frogg.frameName = "emotion_curious"
        case .chase:
            app.frogg.mirrored = facingLeft
            if g.waiting {
                app.frogg.frameName = "emotion_curious"         // eyes up at the menu bar: waits
            } else {
                app.frogg.frameName = "crawl_\(Int(g.stride * 8) % 8)"
                app.place(at: foot)
                app.trail.step(force: true)
            }
            app.frogg.lean = max(-0.12, min(0.12, CGFloat(-dir.y) * (facingLeft ? -0.12 : 0.12)))
        case .shell:
            app.frogg.frameName = "seal_1"
            app.frogg.lean = 0
        case .wobble(let until):
            // back out with a wobble: ±4°, two swings
            let p = 1 - (until - now) / max(g.tuning.wobble, 0.01)
            app.frogg.frameName = p < 0.3 ? "seal_0" : "crawl_0"
            app.frogg.lean = CGFloat(0.07 * sin(p * 4 * .pi) * (1 - p))
        default: break
        }
        overlay?.danger = Reduce.motion ? 0 : g.danger(cursor: mouse)
        overlay?.hud = (Self.clock(g.remaining(now)), "\(g.bonks) bonk\(g.bonks == 1 ? "" : "s")")
        if Debug.enabled {
            overlay?.debug = [
                .circle(g.head, g.tuning.gotchaRadius * g.scale, .systemRed),
                .circle(g.head, g.tuning.dangerBodies * g.body, .systemOrange),
                .circle(g.head, g.tuning.closeBodies * g.body, .systemYellow),
                .point(g.goal(for: mouse), .systemBlue),
                .text("Inevitable \(g.phase) · \(String(format: "%.1f", g.elapsed(now)))/\(Int(g.round)) s · v \(Int(g.speed)) pt/s · bonks \(g.bonks)\(g.waiting ? " · waiting" : "")\(g.parked ? " · parked" : "")"),
            ]
        }
        for e in events {
            switch e {
            case .cameOut: Debug.log("game: out of the shell")
            case .gotcha: finishChase(won: true, now: now)
            case .survived: finishChase(won: false, now: now)
            case .declined: Debug.log("game: invite declined"); stop(); app.frogg.mirrored = false; settleHome()
            default: break
            }
        }
    }

    func finishChase(won: Bool, now: TimeInterval) {
        guard let g = chase else { return }
        let score = g.score(now)
        var r = records
        let newBest = !won && r.offer(score, for: "slugg", byCount: false)
        if won, r.best["slugg"] == nil { r.offer(score, for: "slugg", byCount: false) }
        records = r
        let best = records.best["slugg"]?.seconds ?? score.seconds
        Debug.log("game over inevitable won=\(won) t=\(Int(score.seconds)) bonks=\(score.count)")
        let line = "Survived \(Self.clock(score.seconds)) · \(score.count) bonk\(score.count == 1 ? "" : "s") · best \(Self.clock(best))"
        if won {
            // gotcha: a smug rise, a tiny crown, "squelch!", then a nap
            frozenUntil = now + 0.08
            spring(-0.08, at: now)
            app.frogg.frameName = "emotion_proud"
            overlay?.crown(over: app.topLeft(app.froggBox), now: now)
            app.exclaim("squelch!", for: 1.6)
            app.later(1.6) { [weak self] in
                guard let self else { return }
                self.app.notify(.gameResult(line))
                self.stop()
                self.app.show("rest_1", for: 20)   // naps in his shell
            }
        } else {
            // you lasted: a dramatic flop, a sigh, and back where he was
            app.frogg.frameName = "rest_0"
            app.exclaim(newBest ? "fine. FINE. (new best)" : "fine. FINE.", for: 1.8)
            app.later(1.8) { [weak self] in
                self?.app.notify(.gameResult(line))
                self?.stop()
                self?.settleHome()
            }
        }
        chase = nil
        kind = .inevitable   // keeps the overlay for the ending until stop()
    }

    // MARK: Frogg · Snap

    var mouth: CGPoint {
        let b = app.topLeft(app.froggBox)
        // the mouth line (17/54 of the way down), moved with the squash: the body squashes from the feet
        let fromFeet = b.height * (1 - 17 / 54) * app.frogg.squash.height
        return CGPoint(x: b.midX + (app.frogg.mirrored ? -1 : 1) * b.width * 0.04, y: b.maxY - fromFeet)
    }

    func stepSnap(_ now: TimeInterval, _ mouse: CGPoint) {
        guard var g = snap else { return }
        let fly = SnapGame.fly(cursor: mouse, scale: g.scale)
        let events = g.step(now: now, fly: fly)
        snap = g
        overlay?.fly = fly
        app.frogg.mirrored = fly.x < (app.foot?.x ?? 0)
        overlay?.tongue = nil
        overlay?.throat = nil
        switch g.phase {
        case .invite, .track:
            app.frogg.frameName = Int(now * 0.7) % 6 == 0 && (now * 0.7).truncatingRemainder(dividingBy: 1) < 0.15 ? "blink" : "idle_0"
            app.frogg.squash = CGSize(width: 1, height: 1)
        case .tell(let start, let end, _):
            // throat puffs over the first 60 %, eyes narrow, the body coils
            let p = (now - start) / max(end - start, 0.01)
            app.frogg.frameName = "mischief_0"
            app.frogg.squash = CGSize(width: 1.08, height: 0.9)
            overlay?.throat = (mouth, min(1, p / 0.6))
        case .feinted(let at):
            // deflates, then strikes as you relax
            app.frogg.frameName = "idle_0"
            app.frogg.squash = CGSize(width: 1, height: 1)
            overlay?.throat = (mouth, max(0, (at - now) / g.tuning.feintFollow) * 0.55)
        case .strike(let start, let end, let aim):
            app.frogg.frameName = "poke_1"
            app.frogg.squash = CGSize(width: 0.94, height: 1.08)
            let p = min(1, (now - start) / max(end - start, 0.01))
            overlay?.tongue = (mouth, CGPoint(x: mouth.x + (aim.x - mouth.x) * p, y: mouth.y + (aim.y - mouth.y) * p), 3, false)
        case .hitStop(_, let aim):
            overlay?.tongue = (mouth, aim, 2, true)                // frozen at full reach, white tip
        case .recover(let until):
            let left = until - now, total = g.recoveryLength(at: g.elapsed(now))
            let back = min(1, (total - left) / 0.12)
            if back < 1, case let a? = overlay?.lastAim {
                overlay?.tongue = (mouth, CGPoint(x: a.x + (mouth.x - a.x) * back, y: a.y + (mouth.y - a.y) * back), 2, false)
            }
            app.frogg.frameName = back < 1 ? "poke_1" : (total - left < 0.4 ? "blink" : "idle_0")   // an annoyed slow blink
            app.frogg.squash = CGSize(width: 1, height: 1)
        default: break
        }
        overlay?.hud = (Self.clock(g.remaining(now)), "dodged \(g.dodges)")
        if Debug.enabled {
            var d: [GameOverlay.Debug] = [.circle(fly, g.tuning.hitRadius * g.scale, .systemGreen), .point(mouth, .systemPink)]
            if case .strike(_, _, let aim) = g.phase { d.append(.circle(aim, g.tuning.hitRadius * g.scale, .systemRed)) }
            if case .hitStop(_, let aim) = g.phase { d.append(.circle(aim, g.tuning.hitRadius * g.scale, .systemRed)) }
            let el = g.elapsed(now)
            d.append(.text("Snap \(g.phase.label) · \(String(format: "%.1f", el)) s · tell \(Int(g.tellLength(at: el) * 1000)) ms · gap \(String(format: "%.2f", g.gap(at: el))) s · feint \(Int(g.feintChance(at: el) * 100)) % · dodged \(g.dodges)"))
            overlay?.debug = d
        }
        for e in events {
            switch e {
            case .strike(let aim): overlay?.lastAim = aim
            case .dodged(let n):
                frozenUntil = now + 0.0                         // the hit-stop already happened at full reach
                if let a = overlay?.lastAim { overlay?.whiff(at: a, now: now) }
                overlay?.popStreak(now: now)
                Debug.log("game: dodged \(n)")
            case .feinted: Debug.log("game: feint")
            case .caught: finishSnap(caught: true, now: now)
            case .survived: finishSnap(caught: false, now: now)
            case .declined: Debug.log("game: invite declined"); overlay?.flyAway(now: now); stop(after: 1); settleHome()
            default: break
            }
        }
        // the strike's hit-stop: 60 ms at full reach
        if case .hitStop(let until, _) = g.phase { frozenUntil = max(frozenUntil, min(until, now + g.tuning.hitStop)) }
    }

    func finishSnap(caught: Bool, now: TimeInterval) {
        guard let g = snap else { return }
        let score = g.score(now)
        var r = records
        let newBest = r.offer(score, for: "frogg", byCount: true)
        records = r
        let best = records.best["frogg"]?.count ?? score.count
        Debug.log("game over snap caught=\(caught) dodges=\(score.count)")
        snap = nil
        let line = "Dodged \(score.count) · best \(best)\(newBest && score.count > 0 ? " (new!)" : "")"
        if caught {
            // gulp: the fly is gone, a satisfied swallow and a smug throat puff
            frozenUntil = now + 0.09
            spring(0.06, at: now)
            overlay?.fly = nil
            overlay?.tongue = nil
            app.frogg.frameName = "emotion_proud"
            overlay?.throat = (mouth, 0.9)
            app.exclaim("*gulp*", for: 1.4)
        } else {
            // you survived: a grumpy sulk, looking away; the fly buzzes off
            app.frogg.frameName = "emotion_annoyed"
            app.frogg.mirrored.toggle()
            overlay?.flyAway(now: now)
            app.exclaim("hmph.", for: 1.4)
        }
        app.later(1.4) { [weak self] in
            self?.app.notify(.gameResult(line))
            self?.stop()
            self?.app.frogg.mirrored = false
            self?.settleHome()
        }
    }

    // MARK: overlay and teardown

    func openOverlay(on screen: CGRect) {
        let o = GameOverlay(screenTopLeft: screen, app: app)
        o.panel.order(.above, relativeTo: app.froggPanel.windowNumber)
        overlay = o
    }

    func stop(after delay: TimeInterval = 0) {
        ticker?.stop(); ticker = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        chase = nil; snap = nil; kind = nil
        frozenUntil = 0
        app.trail.lengthBodies = 1
        app.frogg.squash = CGSize(width: 1, height: 1)
        app.frogg.lean = 0
        app.busy = false
        let o = overlay
        overlay = nil
        if delay > 0, let o {
            // a last few frames (the fly buzzing off), on a plain timer
            let until = app.now + delay
            func frame() {
                guard app.now < until else { o.close(); return }
                o.redraw(now: app.now)
                app.later(1.0 / 30) { frame() }
            }
            frame()
        } else { o?.close() }
    }

    /// After a game: back to normal, and back where it was if the chase moved it.
    func settleHome() {
        app.frogg.squash = CGSize(width: 1, height: 1)
        if let h = homeFoot, let f = app.foot, hypot(h.x - f.x, h.y - f.y) > 4 {
            app.userPlaced = false
            app.reposition(force: true)
        }
        homeFoot = nil
        app.backToIdle()
    }

    // MARK: Kiti · Laser chase (kept from before)

    func startLaser(_ foot: CGPoint) {
        let h = app.spriteSize.height
        let screen = app.screensTopLeft.first { $0.insetBy(dx: -4, dy: -4).contains(foot) } ?? app.screensTopLeft.first ?? .zero
        laser = LaserChase(cat: CGPoint(x: foot.x, y: foot.y - h / 2), at: app.now,
                           bounds: screen.insetBy(dx: app.spriteSize.width / 2, dy: h / 2))
        kind = .laser
        app.menu.close(reason: "game")
        app.busy = true
        app.cancelAnimations()
        app.leaveSurface()
        app.notify(.laserStart("Laser chase", name: app.settings.name))
        Debug.log("game start laser")
        let size = NSSize(width: 22, height: 22)
        let p = OverlayPanel(size: size)
        p.contentView = LaserDotView(frame: NSRect(origin: .zero, size: size))
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        dotPanel = p
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.end(early: true) }; return nil }
            return e
        }) { monitors.append(m) }
        lastStep = app.now
        ticker = DisplayTicker(view: p.contentView!) { [weak self] in self?.stepLaser() }
    }

    func stepLaser() {
        guard var g = laser else { return }
        let t = app.now
        let dot = app.mouseTopLeft
        dotPanel?.setFrameOrigin(NSPoint(x: NSEvent.mouseLocation.x - 11, y: NSEvent.mouseLocation.y - 11))
        let event = g.step(dt: min(t - lastStep, 0.05), at: t, dot: dot)
        lastStep = t
        laser = g
        let h = app.spriteSize.height
        let frame: String
        switch g.phase {
        case .run:
            if FroggArt.shared.frames["trot_0"] != nil { frame = "trot_\(Int(t * 12) % 6)" } else { frame = Int(t * 10) % 2 == 0 ? "move_0" : "move_2" }
        case .stalk: frame = Int(t * 3) % 2 == 0 ? "mischief_0" : "mischief_1"
        case .pounce: frame = "move_1"
        case .caught: frame = "mischief_2"
        }
        if app.frogg.frameName != frame { app.frogg.frameName = frame }
        if g.phase != .caught { app.frogg.mirrored = g.facingLeft }
        app.place(at: CGPoint(x: g.cat.x, y: g.cat.y + h / 2))
        switch event {
        case .caught(let n)?:
            Debug.log("laser caught \(n)")
            app.puff(at: dot)
            dotPanel?.alphaValue = 0.25
            app.later(LaserChase.rest) { [weak self] in self?.dotPanel?.alphaValue = 1 }
        case .over(let n)?: finishLaser(n)
        default: break
        }
    }

    func finishLaser(_ catches: Int) {
        var r = records
        let record = r.offer(GameScore(seconds: 0, count: catches), for: "cat", byCount: true)
        records = r
        Debug.log("laser over catches=\(catches)")
        stopLaser()
        app.notify(.laserScore(catches, name: app.settings.name, record: record), voice: record ? .happy : .idle)
        app.show(record ? "emotion_happy" : "emotion_proud", for: 2.5)
        app.later(2.6) { [weak self] in self?.app.userPlaced = false; self?.app.reposition(force: true) }
    }

    func stopLaser() {
        ticker?.stop(); ticker = nil
        laser = nil
        kind = nil
        dotPanel?.orderOut(nil); dotPanel = nil
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        app.busy = false
        app.frogg.mirrored = false
    }
}

extension SnapGame.Phase {
    var label: String {
        switch self {
        case .invite: "invite"; case .track: "track"; case .tell(_, _, let f): f ? "tell (feint)" : "tell"
        case .feinted: "feinted"; case .strike: "strike"; case .hitStop: "hit-stop"; case .recover: "recover"
        case .caught: "caught"; case .survived: "survived"; case .interrupted: "interrupted"; case .declined: "declined"
        }
    }
}

enum Reduce {
    @MainActor static var motion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Calls `step` once per display refresh (the display-synced clock), until stopped.
@MainActor
final class DisplayTicker: NSObject {
    let step: @MainActor () -> Void
    var link: CADisplayLink?
    init(view: NSView, step: @escaping @MainActor () -> Void) {
        self.step = step
        super.init()
        let l = view.displayLink(target: self, selector: #selector(fire))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc func fire() { step() }
    func stop() { link?.invalidate(); link = nil }
}

/// The laser pointer's dot: red, with a soft glow.
final class LaserDotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0.15, blue: 0.2, alpha: 0.28).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor(srgbRed: 1, green: 0.1, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 7, dy: 7)).fill()
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: bounds.midY, width: 3, height: 3)).fill()
    }
}
