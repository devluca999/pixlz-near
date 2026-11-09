import AppKit
import PixlMemoryKit
import PixlzCore

/// More ▸ Mischief: the Catch mini-game (rules in PixlMemoryKit `CatchGame`). Targets are tiny
/// clickable panels; the Pixl watches each one and snaps it when you click it. 20 s, then a
/// score and your best for this Pixl. A 30 Hz timer runs only while a game is on.
@MainActor
final class GameController {
    unowned let app: AppController
    var game: CatchGame?
    var timer: Timer?
    var targetPanel: OverlayPanel?
    var targetID: Int?
    var keyMonitor: Any?
    var laser: LaserChase?
    var dotPanel: OverlayPanel?
    var lastStep: TimeInterval = 0
    var isOn: Bool { game != nil || laser != nil }

    init(app: AppController) { self.app = app }

    var info: PixlGame { app.ui.game ?? PixlGame(name: "Catch", target: "fly") }
    var bestKey: String { "PixlMemory.best.\(PixlSkins.currentID)" }

    func start() {
        guard !isOn, let foot = app.foot else { return }
        if info.target == "laser" { startLaser(foot); return }
        let screen = app.screensTopLeft.first { $0.minX <= foot.x && foot.x <= $0.maxX } ?? app.screensTopLeft.first ?? .zero
        var g = CatchGame(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        g.start(at: app.now, around: foot, bounds: screen)
        game = g
        app.busy = true
        app.cancelAnimations()
        app.frogg.frameName = "poke_1"
        app.notify(.gameStart(info.name))
        Debug.log("game start \(info.name)")
        // Esc ends it early
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.end(early: true) }; return nil }
            return e
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func step() {
        guard var g = game else { return }
        let event = g.tick(app.now)
        game = g
        switch event {
        case .spawn(let t)?: show(t)
        case .missed?: hideTarget(caught: false)
        case .over(let score, _)?: finish(score)
        case nil: break
        }
    }

    func show(_ t: CatchGame.Target) {
        guard let img = GameArt.image(info.target) else { return }
        let size = NSSize(width: img.size.width + 12, height: img.size.height + 12)
        let view = TargetView(image: img, size: size) { [weak self] in self?.clicked(t.id) }
        let p = OverlayPanel(size: size)
        p.contentView = view
        p.ignoresMouseEvents = false
        let r = Perch.toAppKit(CGRect(x: t.center.x - size.width / 2, y: t.center.y - size.height / 2, width: size.width, height: size.height),
                               primaryHeight: app.primaryHeight)
        p.setFrame(r, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        targetPanel = p
        targetID = t.id
        // the Pixl looks at it
        if let foot = app.foot { app.frogg.mirrored = t.center.x < foot.x }
        app.frogg.frameName = "poke_1"
    }

    func clicked(_ id: Int) {
        guard var g = game, g.hit(id, at: app.now) else { return }
        game = g
        Debug.log("game hit \(g.score)")
        let at = targetPanel.map { app.topLeft(NSPoint(x: $0.frame.midX, y: $0.frame.minY)) }
        hideTarget(caught: true)
        // snap!
        app.frogg.frameName = "signature_1"
        app.later(0.22) { [weak self] in if self?.isOn == true { self?.app.frogg.frameName = "poke_1" } }
        if let at { app.puff(at: at) }
    }

    func hideTarget(caught: Bool) {
        guard let p = targetPanel else { return }
        targetPanel = nil
        targetID = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = caught ? 0.06 : 0.18; p.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
    }

    func finish(_ score: Int) {
        let best = UserDefaults.standard.integer(forKey: bestKey)
        let newBest = score > best
        if newBest { UserDefaults.standard.set(score, forKey: bestKey) }
        let thing = info.target == "fly" ? "flies" : info.target == "yarn" ? "yarn balls" : info.target == "ball" ? "balls" : "socks"
        Debug.log("game over score=\(score) best=\(max(score, best))")
        stop()
        app.show(newBest ? "emotion_happy" : "emotion_proud", for: 3)
        app.notify(.gameScore(score, thing, best: best, newBest: newBest), voice: newBest ? .happy : .idle)
    }

    func end(early: Bool) {
        guard isOn else { return }
        Debug.log("game ended early")
        let wasLaser = laser != nil
        stop()
        if wasLaser { app.later(0.3) { [weak self] in self?.app.userPlaced = false; self?.app.reposition(force: true) } }
        app.notify(.gameEnded)
        app.backToIdle()
    }

    // MARK: Laser chase (Kiti)

    func startLaser(_ foot: CGPoint) {
        let h = app.spriteSize.height
        let screen = app.screensTopLeft.first { $0.insetBy(dx: -4, dy: -4).contains(foot) } ?? app.screensTopLeft.first ?? .zero
        laser = LaserChase(cat: CGPoint(x: foot.x, y: foot.y - h / 2), at: app.now,
                           bounds: screen.insetBy(dx: app.spriteSize.width / 2, dy: h / 2))
        app.busy = true
        app.cancelAnimations()
        app.leaveSurface()
        app.notify(.laserStart(info.name, name: app.settings.name))
        Debug.log("game start \(info.name)")
        let size = NSSize(width: 22, height: 22)
        let p = OverlayPanel(size: size)
        p.contentView = LaserDotView(frame: NSRect(origin: .zero, size: size))
        p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        dotPanel = p
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.end(early: true) }; return nil }
            return e
        }
        lastStep = app.now
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepLaser() }
        }
        RunLoop.main.add(timer!, forMode: .common)
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
        // frames: running, creeping low, the leap, and a proud arch after a catch
        let frame: String
        switch g.phase {
        case .run:
            // the trot loop (C13) when it has one
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
        let best = UserDefaults.standard.integer(forKey: bestKey)
        if catches > best { UserDefaults.standard.set(catches, forKey: bestKey) }
        Debug.log("laser over catches=\(catches) best=\(max(catches, best))")
        stop()
        let name = app.settings.name
        app.notify(.laserScore(catches, name: name, record: catches > best), voice: catches > best ? .happy : .idle)
        app.show(catches > best ? "emotion_happy" : "emotion_proud", for: 2.5)
        app.later(2.6) { [weak self] in self?.app.userPlaced = false; self?.app.reposition(force: true) }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        laser = nil
        dotPanel?.orderOut(nil); dotPanel = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil
        hideTarget(caught: false)
        game = nil
        app.busy = false
        app.frogg.mirrored = false
    }
}

/// One target: a pixel sprite you click.
@MainActor
final class TargetView: NSView {
    let action: () -> Void
    init(image: NSImage, size: NSSize, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(origin: .zero, size: size))
        let iv = NSImageView(image: image)
        iv.imageScaling = .scaleNone
        iv.frame = bounds
        addSubview(iv)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Catch it")
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }
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
