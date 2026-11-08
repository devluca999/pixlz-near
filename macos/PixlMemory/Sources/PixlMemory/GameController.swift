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
    var isOn: Bool { game != nil }

    init(app: AppController) { self.app = app }

    var info: PixlGame { app.ui.game ?? PixlGame(name: "Catch", target: "fly") }
    var bestKey: String { "PixlMemory.best.\(PixlSkins.currentID)" }

    func start() {
        guard !isOn, let foot = app.foot else { return }
        let screen = app.screensTopLeft.first { $0.minX <= foot.x && foot.x <= $0.maxX } ?? app.screensTopLeft.first ?? .zero
        var g = CatchGame(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        g.start(at: app.now, around: foot, bounds: screen)
        game = g
        app.busy = true
        app.cancelAnimations()
        app.frogg.frameName = "poke_1"
        app.say("\(info.name)! Click them before they're gone.", for: 2)
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
        app.say(newBest ? "\(score) \(thing)! New best." : "\(score) \(thing). Best: \(best).", for: 3.5)
    }

    func end(early: Bool) {
        guard isOn else { return }
        Debug.log("game ended early")
        stop()
        app.say("Okay, later.", for: 1.5)
        app.backToIdle()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
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
