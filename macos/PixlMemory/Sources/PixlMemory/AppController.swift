import AppKit
import PixlMemoryKit
import PixlzCore

/// A borderless panel that never becomes key or main (SPEC R5): the app you're
/// typing in keeps focus and its selection while you use Frogg.
class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        // One Space at a time: Frogg slides away with the old desktop during a swipe and is
        // brought onto the new one when ordered front (no floating over the slide).
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The mini menu takes typing (its name field) without activating the app.
final class KeyPanel: OverlayPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum Mode { case perched, held, airborne, dropping }

    var settings = PixlSettings.load()
    let client = MemoryClient()
    let watcher = WindowWatcher()
    var frogg: FroggView!
    var froggPanel: OverlayPanel!
    let bubblePanel = OverlayPanel(size: NSSize(width: 10, height: 10))
    var resultPanel: OverlayPanel?
    var radialPanel: OverlayPanel?
    var radialView: RadialMenuView?
    var choicePanel: OverlayPanel?
    var choiceView: ChoiceMenuView?
    var chosenInSelfTest: Int?
    var miniPanel: KeyPanel?
    var statusItem: NSStatusItem?

    var mode = Mode.perched
    var foot: CGPoint?                 // feet, top-left global coordinates
    var flight: ThrowFlight?
    var animTimers: [Timer] = []
    var idleTimer: Timer?
    var bubbleTimer: Timer?
    var permissionTimer: Timer?
    var clickTimer: Timer?
    var longPressTimer: Timer?
    var longPressed = false
    var pendingSwitch: Timer?
    var focusTimer: Timer?

    var gesture: PointerGesture?
    var dragSamples: [(TimeInterval, CGPoint)] = []
    var pokes = PokeCounter()
    var userPlaced = false             // the user put Frogg somewhere; stay until the next window switch
    var userHidden = false
    var fullscreenHidden = false
    var paused = false
    var busy = false
    var spaceTransition = false
    var focusUntil: Date?
    var lastNudge = Date.distantPast
    var lastVerdict: String?
    var cachedStatus: ServiceStatus?
    var monitors: [Any] = []

    var scale: CGFloat { CGFloat(settings.scale) }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.log("launch pid=\(ProcessInfo.processInfo.processIdentifier) accessibility=\(AX.trusted) debug=\(Debug.enabled)")
        bubblePanel.ignoresMouseEvents = true  // the bubble is opaque; it must never swallow clicks (R2)
        buildFrogg()
        setUpStatusItem()
        HotKeys.shared.register(.p) { [weak self] in self?.toggleMiniMenu() }
        HotKeys.shared.register(.space) { [weak self] in self?.chatStub() }
        HotKeys.shared.register(.h) { [weak self] in self?.toggleHidden() }
        if !AX.trusted {
            AX.requestTrust()
            say("I need Accessibility to see your window and selection", for: 8)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AX.trusted else { return }
                    self.permissionTimer?.invalidate()
                    Debug.log("accessibility granted")
                    self.watcher.attachToFrontmost()
                }
            }
            permissionTimer?.tolerance = 1
        }
        watcher.onChange = { [weak self] change in self?.windowChanged(change) }
        watcher.start()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        reposition(force: true)
        froggPanel.orderFrontRegardless()
        scheduleIdle()
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in await self.selfTest() }
        }
    }

    func buildFrogg() {
        let current = foot
        link?.invalidate()
        link = nil
        froggPanel?.orderOut(nil)
        frogg = FroggView(scale: scale)
        frogg.onMouse = { [weak self] kind, event in self?.mouse(kind, event) }
        froggPanel = OverlayPanel(size: frogg.frame.size)
        froggPanel.contentView = frogg
        if let current { place(at: current) }
    }

    @objc func screensChanged() { reposition(force: true) }

    // MARK: geometry

    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    func topLeft(_ r: CGRect) -> CGRect { Perch.toAppKit(r, primaryHeight: primaryHeight) }  // same flip both ways
    func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    var screensTopLeft: [CGRect] { NSScreen.screens.map { topLeft($0.visibleFrame) } }
    var spriteSize: CGSize {
        let s = FroggArt.shared.size("idle_0")
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func target() -> Perch.Spot? {
        let window = settings.perchOnWindows && focusUntil == nil ? watcher.activeWindowFrame : nil
        return Perch.spot(window: window, screens: screensTopLeft, sprite: spriteSize)
    }

    // MARK: following windows and Spaces

    func windowChanged(_ change: WindowWatcher.Change) {
        if change == .switched {
            userPlaced = false
            nudgeIfDistracting()
            // Wait a beat: swiping Spaces also activates another app, and the Space change
            // arrives just after. Hopping first, then being interrupted, looked like a glitch.
            pendingSwitch?.invalidate()
            pendingSwitch = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.spaceTransition else { return }
                    self.updateFullscreen()
                    self.reposition(force: true)
                }
            }
            return
        }
        guard !spaceTransition else { return }
        updateFullscreen()
        if change == .moved, mode == .perched, motion == nil, !userPlaced, let spot = target() {
            ride(to: spot.foot)  // feet glued to the dragged window, leaning against the drag
            return
        }
        reposition(force: change == .switched)
    }

    /// Hop to the perch. Mid-motion, the current flight is retargeted (never snaps back).
    func reposition(force: Bool = false) {
        guard !paused, !userHidden, !fullscreenHidden, !spaceTransition, mode == .perched, !userPlaced,
              let spot = target() else { return }
        guard let current = foot else { place(at: spot.foot); return }
        if let m = motion {
            if let end = motionTarget, hypot(end.x - spot.foot.x, end.y - spot.foot.y) < 1 { return }
            let t = now - motionStart
            motion = m.retargeted(at: t) { [unowned self] from in self.route(from: from, to: spot.foot) }
            motionStart = now
            lastMotionT = 0
            motionTarget = spot.foot
            Debug.log("motion retarget at t=\(String(format: "%.2f", t))")
            return
        }
        let d = hypot(spot.foot.x - current.x, spot.foot.y - current.y)
        if d < 1 { return }
        if !force && d < 60 { place(at: spot.foot); return }
        run(Choreography.hop(route(from: current, to: spot.foot)), target: spot.foot)
    }

    /// A shaped route (PixlzCore HopRoute): distance-scaled arc, chained when long, kept under
    /// the menu bar and clear of the focused window's body (SPEC §7.3).
    func route(from a: CGPoint, to b: CGPoint) -> HopRoute {
        let bounds = screensTopLeft.first { $0.minX <= b.x && b.x <= $0.maxX && $0.minY <= b.y && b.y <= $0.maxY + 1 }
            ?? screensTopLeft.first ?? .zero
        let window = settings.perchOnWindows && focusUntil == nil ? watcher.activeWindowFrame : nil
        let displays = NSScreen.screens.enumerated().map { i, s in
            DisplayInfo(id: i, frame: topLeft(s.frame), visibleFrame: topLeft(s.visibleFrame))
        }
        let world = WorldMap(WorldInput(displays: displays, windows: window.map { [WindowInfo(id: 1, frame: $0)] } ?? []))
        let r = HopRoute.plan(from: a, to: b, bounds: bounds, sprite: spriteSize, scale: scale, keepOut: window, world: world)
        Debug.log("route legs=\(r.legs.count) duration=\(String(format: "%.2f", r.duration))s clear=\(r.clear)")
        return r
    }

    /// Swiping between Spaces: a quick hop up and away (with a puff), then on the new
    /// Space a peek from under the menu bar and a drop onto the active window (≤ 0.6 s).
    @objc func spaceChanged() {
        guard !userHidden else { return }
        Debug.log("space changed")
        pendingSwitch?.invalidate()
        spaceTransition = true
        cancelMotion()
        closeMenus()
        // Frogg's panels belong to the old Space and slid away with it; take them down and
        // bring Frogg in on this Space: peek from under the menu bar, drop, squash, settle.
        for p in [froggPanel, bubblePanel, resultPanel, dustPanel] { p?.orderOut(nil) }
        enterAfterSpaceChange()
    }

    func enterAfterSpaceChange() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watcher.attachToFrontmost()
                self.spaceTransition = false
                if self.settings.hideInFullscreen && self.watcher.activeWindowIsFullscreen {
                    self.fullscreenHidden = true
                    self.froggPanel.orderOut(nil)
                    return
                }
                self.fullscreenHidden = false
                if let spot = self.target() { self.dropIn(to: spot.foot) }
            }
        }
    }

    func updateFullscreen() {
        let fs = settings.hideInFullscreen && watcher.activeWindowIsFullscreen
        if fs && !fullscreenHidden {
            fullscreenHidden = true
            cancelMotion()
            hideOverlays(fade: 0.2)
        } else if !fs && fullscreenHidden {
            fullscreenHidden = false
            if !userHidden, let spot = target() { dropIn(to: spot.foot) }
        }
    }

    /// Peek down from under the menu bar (hanging by a toe pad), then drop onto `target`.
    func dropIn(to target: CGPoint) {
        let screen = screensTopLeft.first { $0.minX <= target.x && target.x <= $0.maxX } ?? screensTopLeft.first ?? .zero
        let hang = FroggArt.shared.frames[MotionFrames.hang]
        let below = CGFloat((hang?.h ?? 40) - (hang?.pin?[1] ?? 0)) * scale  // pin (toe) to feet
        let hangFoot = CGPoint(x: target.x, y: min(screen.minY + below, target.y - 20))
        froggPanel.alphaValue = 1
        froggPanel.orderFrontRegardless()
        run(Choreography.dropIn(hangFoot: hangFoot, to: target), target: target)
    }

    // MARK: motion: one display-synced clock, running only while something moves (SPEC R6, D7)

    var motion: Choreography?
    var motionStart: TimeInterval = 0
    var lastMotionT: TimeInterval = -1
    var motionTarget: CGPoint?
    var motionDone: (@MainActor () -> Void)?
    var link: CADisplayLink?
    var lastTick: TimeInterval = 0
    var dust: DustView?
    var dustPanel: OverlayPanel?
    var riding = false
    var lastRide: (x: CGFloat, t: TimeInterval)?
    var leanTarget: CGFloat = 0
    var dragStopTimer: Timer?

    var moving: Bool { motion != nil || flight != nil }

    func run(_ c: Choreography, target: CGPoint?, then done: (@MainActor () -> Void)? = nil) {
        cancelAnimations()
        motion = c
        motionStart = now
        lastMotionT = -1
        motionTarget = target
        motionDone = done
        Debug.log("motion start segments=\(c.segments.count) duration=\(String(format: "%.2f", c.duration))s")
        startClock()
    }

    func startClock() {
        guard link == nil else { return }
        let l = frogg.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)  // keeps running during menus and window drags
        link = l
        lastTick = now
        Debug.log("display link on")
    }

    func stopClockIfIdle() {
        guard link != nil, !moving, dust?.pool.isEmpty ?? true, !riding, abs(frogg.lean) < 0.001 else { return }
        link?.invalidate()
        link = nil
        dustPanel?.orderOut(nil)
        Debug.log("display link off")
    }

    @objc func tick(_ l: CADisplayLink) {
        let t0 = now
        let dt = min(max(t0 - lastTick, 0), 0.05)
        lastTick = t0
        if let m = motion {
            let t = t0 - motionStart
            let (pose, done) = m.pose(at: t)
            apply(pose)
            for p in m.landings(between: lastMotionT, and: t) { puff(at: p) }
            lastMotionT = t
            if done {
                motion = nil
                motionTarget = nil
                let finished = motionDone
                motionDone = nil
                finishMotion()
                finished?()
            }
        }
        if var f = flight {
            let landed = f.step(dt: min(dt, 1.0 / 30))
            flight = f
            place(at: f.body.position)
            if let spot = landed {
                flight = nil
                mode = .perched
                userPlaced = true
                run(Choreography([.land(at: spot, frame: MotionFrames.dropLand, mirrored: false, duration: 0.1, dust: true),
                                  .settle(at: spot, duration: 0.2)]), target: nil)
                puff(at: spot)
            }
        }
        // lean against a window drag, easing back to upright
        let lean = riding ? leanTarget : 0
        frogg.lean += (lean - frogg.lean) * min(1, CGFloat(dt) * 14)
        if abs(frogg.lean - lean) < 0.002 { frogg.lean = lean }
        if let dust, !dust.pool.isEmpty { dust.step(to: Date(), dt: dt) }
        stopClockIfIdle()
    }

    func apply(_ pose: Pose) {
        if frogg.frameName != pose.frame { frogg.frameName = pose.frame }
        frogg.squash = pose.squash
        frogg.mirrored = pose.mirrored
        froggPanel.alphaValue = pose.alpha
        place(at: pose.foot)
    }

    func finishMotion() {
        frogg.squash = CGSize(width: 1, height: 1)
        frogg.mirrored = false
        mode = .perched
        backToIdle()
    }

    /// Feet in top-left coordinates → panel origin snapped to device pixels.
    func place(at p: CGPoint) {
        foot = p
        var f = Perch.panelFrame(foot: p, canvas: frogg.frame.size, primaryHeight: primaryHeight)
        let s = froggPanel.backingScaleFactor
        f.origin = NSPoint(x: (f.origin.x * s).rounded() / s, y: (f.origin.y * s).rounded() / s)
        if froggPanel.frame != f { froggPanel.setFrame(f, display: true) }
        positionBubble()
    }

    func cancelMotion() {
        motion = nil
        motionTarget = nil
        motionDone = nil
        flight = nil
        if mode != .held { mode = .perched }
        frogg?.squash = CGSize(width: 1, height: 1)
        frogg?.mirrored = false
        stopClockIfIdle()
    }

    /// Landing dust in its own click-through panel, so it stays where Frogg landed.
    func puff(at p: CGPoint) {
        let size = NSSize(width: 70 * scale, height: 24 * scale)
        if dust == nil || dust?.scale != scale {
            let v = DustView(scale: scale, size: size)
            let panel = OverlayPanel(size: size)
            panel.ignoresMouseEvents = true
            panel.contentView = v
            dust = v
            dustPanel = panel
        }
        guard let dust, let dustPanel else { return }
        dustPanel.setFrameOrigin(NSPoint(x: (p.x - size.width / 2).rounded(), y: (primaryHeight - p.y - 4 * scale).rounded()))
        dust.emit(at: CGPoint(x: size.width / 2, y: 4 * scale), now: Date())
        dustPanel.order(.below, relativeTo: froggPanel.windowNumber)
        startClock()
    }

    /// Riding a dragged window: feet glued, a lean against the drag, and a small hop when it stops.
    func ride(to p: CGPoint) {
        let t = now
        if let last = lastRide, t - last.t > 0.001 {
            let vx = (p.x - last.x) / CGFloat(t - last.t)
            leanTarget = max(-0.12, min(0.12, -vx / 2500))
        }
        lastRide = (p.x, t)
        riding = true
        cancelAnimations()
        place(at: p)
        startClock()
        dragStopTimer?.invalidate()
        dragStopTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.riding = false
                self.lastRide = nil
                self.leanTarget = 0
                if let f = self.foot, self.motion == nil, self.mode == .perched {
                    self.run(Choreography.bump(at: f, scale: self.scale), target: nil)
                }
            }
        }
    }

    // MARK: animation (frame changes only)

    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        animTimers.append(t)
    }

    func cancelAnimations() {
        animTimers.forEach { $0.invalidate() }
        animTimers.removeAll()
        idleTimer?.invalidate()
    }

    func play(_ anim: SlotAnimation, then next: (@MainActor () -> Void)? = nil) {
        cancelAnimations()
        for (frame, at) in anim.schedule {
            if at == 0 { frogg.frameName = frame } else { after(at) { [weak self] in self?.frogg.frameName = frame } }
        }
        after(anim.duration) { [weak self] in
            if let next { next() } else { self?.backToIdle() }
        }
    }

    func show(_ frame: String, for seconds: TimeInterval) {
        cancelAnimations()
        frogg.frameName = frame
        after(seconds) { [weak self] in self?.backToIdle() }
    }

    func backToIdle() {
        guard mode == .perched, !moving else { return }
        frogg.frameName = "idle_0"
        scheduleIdle()
    }

    func scheduleIdle() {
        idleTimer?.invalidate()
        guard !paused else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3...8), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode == .perched, !self.moving, !self.busy, self.frogg.frameName.hasPrefix("idle") else { return }
                let next = Bool.random() ? "idle_1" : "idle_2"  // blink or throat puff
                self.frogg.frameName = next
                self.after(next == "idle_1" ? 0.17 : 0.66) { [weak self] in self?.backToIdle() }
            }
        }
        idleTimer?.tolerance = 0.5
    }

    // MARK: mouse (SPEC §11.1)

    var mouseTopLeft: CGPoint { topLeft(NSEvent.mouseLocation) }

    func mouse(_ kind: FroggView.MouseEvent, _ event: NSEvent) {
        if kind != .dragged { Debug.log("mouse \(kind) clickCount=\(event.clickCount) mode=\(mode)") }
        switch kind {
        case .down:
            closeMenus()
            longPressTimer?.invalidate()
            longPressed = false
            if event.clickCount == 2 {
                clickTimer?.invalidate()
                gesture = nil
                signature()
                return
            }
            gesture = PointerGesture(at: mouseTopLeft, time: now)
            dragSamples = [(now, mouseTopLeft)]
            // Press and hold: the menu opens (like a long-press on the iPhone stage, SPEC §11.1).
            longPressTimer = Timer.scheduledTimer(withTimeInterval: PointerGesture.longPressTime, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.gesture?.dragging == false, self.mode == .perched else { return }
                    self.longPressed = true
                    Debug.log("long press → menu")
                    self.showRadial()
                }
            }
        case .dragged:
            guard var g = gesture else { return }
            dragSamples.append((now, mouseTopLeft))
            if g.moved(to: mouseTopLeft) {
                longPressTimer?.invalidate()
                if longPressed { closeMenus() }
                startGrab()
            }
            gesture = g
            if mode == .held { moveHeld() }
        case .up:
            defer { gesture = nil }
            longPressTimer?.invalidate()
            if mode == .held { release(); return }
            if longPressed { return }  // the menu is already open
            if let g = gesture, g.isClick(releasedAt: mouseTopLeft, time: now) { clicked(event) }
            else { Debug.log("mouse up: not a click (moved)") }
        case .right:
            showRadial()
        }
    }

    /// Click: Frogg reacts at once (poke), then his menu opens, unless this turns out to be
    /// the first half of a double-click (signature).
    func clicked(_ event: NSEvent) {
        if pokes.poke(at: now) {
            show("emotion_annoyed", for: 2)
            say("Hey! \(settings.name) is busy being a frog.", for: 2)
        } else {
            play(.poke)
        }
        if let until = focusUntil { say("Focus: \(Int(until.timeIntervalSinceNow / 60) + 1) min left", for: 2) }
        clickTimer?.invalidate()
        clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showRadial() }
        }
    }

    func signature() {
        play(.signature) { [weak self] in
            self?.show("emotion_proud", for: 2)
        }
    }

    // grab and throw

    func startGrab() {
        cancelMotion()
        cancelAnimations()
        clickTimer?.invalidate()
        mode = .held
        bubblePanel.orderOut(nil)
        frogg.frameName = "grab_0"  // peel-stretch
        after(0.25) { [weak self] in if self?.mode == .held { self?.frogg.frameName = "grab_1" } }  // limp sway
        moveHeld()
    }

    func moveHeld() {
        let pin = frogg.pinPoint(frogg.frameName) ?? NSPoint(x: frogg.bounds.midX, y: frogg.bounds.maxY)
        let m = NSEvent.mouseLocation
        froggPanel.setFrameOrigin(NSPoint(x: (m.x - pin.x).rounded(), y: (m.y - pin.y).rounded()))
        let f = froggPanel.frame
        foot = CGPoint(x: f.midX, y: primaryHeight - f.minY)
    }

    func release() {
        guard let start = foot else { mode = .perched; return }
        let v = Body.throwVelocity(samples: dragSamples, at: now, cap: 3000)
        let screens = NSScreen.screens.map { (frame: topLeft($0.frame), visible: topLeft($0.visibleFrame)) }
        flight = ThrowFlight(foot: start, velocity: v, scale: scale, screens: screens,
                             window: settings.perchOnWindows ? watcher.activeWindowFrame : nil, halfWidth: spriteSize.width / 2)
        mode = .airborne
        frogg.frameName = MotionFrames.fall
        Debug.log("throw v=(\(Int(v.dx)),\(Int(v.dy)))")
        startClock()
    }

    // MARK: polish

    struct Instruction {
        let title: String
        let prompt: String?
    }

    let instructions = [
        Instruction(title: "Polish this", prompt: nil),
        Instruction(title: "Make it shorter", prompt: "Make it shorter and clearer. Keep my voice."),
        Instruction(title: "Make it friendlier", prompt: "Make it warmer and friendlier. Keep the meaning."),
        Instruction(title: "Fix spelling & grammar only", prompt: "Fix spelling and grammar only. Change nothing else."),
    ]

    var pendingSelection: (text: String, app: String?)?

    @discardableResult
    func readSelection() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        let text = AX.trusted ? AX.selectedText(pid: front?.processIdentifier ?? 0) : nil
        pendingSelection = text.map { ($0, front?.localizedName) }
        return text
    }

    func instructionItems() -> [NSMenuItem] {
        guard let sel = pendingSelection else {
            let i = NSMenuItem(title: AX.trusted ? "Select some text first" : "Allow Accessibility to read selections",
                               action: AX.trusted ? nil : #selector(openAccessibility), keyEquivalent: "")
            i.target = self
            return [i]
        }
        let preview = sel.text.replacingOccurrences(of: "\n", with: " ")
        let header = NSMenuItem(title: "“\(preview.prefix(40))\(preview.count > 40 ? "…" : "")”", action: nil, keyEquivalent: "")
        header.isEnabled = false
        return [header] + instructions.enumerated().map { i, ins in
            let item = NSMenuItem(title: ins.title, action: #selector(polishChosen(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            return item
        }
    }

    /// The instruction picker: an overlay panel, not an NSMenu (pop-up menus from a
    /// non-activating panel in a menu-bar-only app are unreliable).
    func showPolishMenu() {
        guard !busy else { say("Working on it…", for: 1.5); return }
        guard let sel = pendingSelection else { say("Select some text first", for: 2); return }
        let preview = sel.text.replacingOccurrences(of: "\n", with: " ")
        showChoices(title: "“\(preview.prefix(28))\(preview.count > 28 ? "…" : "")”", options: instructions.map(\.title),
                    style: .list) { [weak self] i in self?.polish(i) }
    }

    @objc func polishChosen(_ sender: NSMenuItem) { polish(sender.tag) }

    func polish(_ index: Int) {
        Debug.log("polish chosen index=\(index)")
        if CommandLine.arguments.contains("--selftest") { chosenInSelfTest = index; return }  // never send text in a self-test
        guard let sel = pendingSelection, instructions.indices.contains(index) else { return }
        let ins = instructions[index]
        busy = true
        resultPanel?.orderOut(nil)
        show("emotion_curious", for: 600)
        say("Checking the enclave…", for: nil)
        let stage = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.busy == true { self?.say("Thinking privately…", for: nil) } }
        }
        Task { @MainActor in
            defer { busy = false; stage.invalidate() }
            do {
                let r = try await client.polish(sel.text, instruction: ins.prompt)
                let v = r.verification
                lastVerdict = "\(v.badge) · \(v.passed)/\(v.checks.count)"
                show(v.verdict == "verified" ? "emotion_proud" : v.verdict == "partial" ? "emotion_curious" : "emotion_annoyed", for: 4)
                let verdict = v.verdict == "verified" ? "✔ Verified in TEE · \(v.passed)/\(v.checks.count)" : v.badge
                say(r.receipt.map { verdict + "\n" + $0.bubble } ?? verdict, for: 5)
                showResult(.result(r, instruction: ins.title, app: sel.app))
            } catch {
                let e = (error as? MemoryError) ?? .upstream(error.localizedDescription)
                show("emotion_annoyed", for: 5)
                say(e.bubble, for: 6)
                switch e {
                case .attestationFailed, .serviceDown, .noApiKey, .noCredits, .outOfAllowance: showResult(.error(e, app: sel.app))
                default: break
                }
            }
        }
    }

    func showResult(_ content: PolishView.Content) {
        let view = PolishView(content)
        view.fit()
        let panel = resultPanel ?? OverlayPanel(size: view.frame.size)
        resultPanel = panel
        panel.level = .popUpMenu
        panel.contentView = view
        panel.setContentSize(view.frame.size)
        panel.alphaValue = 1
        view.onClose = { [weak panel] in panel?.orderOut(nil) }
        view.onCopy = { [weak self] s in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            self?.say("Copied", for: 1.5)
        }
        view.onDropped = { [weak self, weak panel] r in
            panel?.orderOut(nil)
            self?.show("emotion_happy", for: 3)
            self?.say("Dropped in. Saved as accepted.", for: 2.5)
            Task { await self?.client.markAccepted(draftId: r.draftId) }
        }
        view.onResize = { [weak self, weak panel, weak view] in
            guard let self, let panel, let view else { return }
            panel.setContentSize(view.frame.size)
            self.placeBeside(panel)
        }
        placeBeside(panel)
        panel.orderFrontRegardless()
    }

    /// The visible frame (below the menu bar, above the Dock) of the screen Frogg is on.
    var froggScreen: CGRect {
        let c = NSPoint(x: froggPanel.frame.midX, y: froggPanel.frame.minY + spriteSize.height / 2)
        return (NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    /// Frogg's head and body box in screen coordinates.
    var froggBox: CGRect {
        let f = froggPanel.frame
        let art = FroggArt.shared.size(frogg.frameName)
        return CGRect(x: f.midX - art.width * scale / 2, y: f.minY, width: art.width * scale, height: art.height * scale)
    }

    /// Beside Frogg (left preferred), fully on screen.
    func placeBeside(_ panel: NSPanel) {
        let b = froggBox
        let s = panel.frame.size
        let screen = froggScreen
        var x = b.minX - s.width - 8
        if x < screen.minX + 8 { x = b.maxX + 8 }
        let r = Placement.fit(CGRect(x: x, y: b.maxY - s.height, width: s.width, height: s.height), in: screen)
        panel.setFrameOrigin(r.origin)
    }

    // MARK: overlay pickers

    func showChoices(title: String?, options: [String], style: ChoiceMenuView.Style, onSelect: @escaping @MainActor (Int) -> Void) {
        closeMenus()
        let view = ChoiceMenuView(title: title, options: options, style: style) { [weak self] i in
            self?.closeMenus()
            onSelect(i)
        }
        let panel = OverlayPanel(size: view.frame.size)
        panel.level = .popUpMenu
        panel.contentView = view
        if style == .round {
            // centred over Frogg's head (under his feet if there's no room above), on screen
            let b = froggBox, screen = froggScreen, size = view.frame.size
            var r = CGRect(x: b.midX - size.width / 2, y: b.maxY + 8, width: size.width, height: size.height)
            if r.maxY > screen.maxY - 8 { r.origin.y = b.minY - size.height - 8 }
            panel.setFrameOrigin(Placement.fit(r, in: screen).origin)
        } else {
            placeBeside(panel)
        }
        panel.orderFrontRegardless()
        choicePanel = panel
        choiceView = view
        Debug.log("choices open \(title ?? "") options=\(options.count)")
        watchOutsideClicks()
    }

    /// A click in another app, or a key press, closes any open overlay menu.
    func watchOutsideClicks() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                Debug.log("outside click/key: closing menus")
                self?.closeMenus()
            }
        }) { monitors.append(m) }
    }

    func closeMenus() {
        closeRadial()
        choicePanel?.orderOut(nil)
        choicePanel = nil
        choiceView = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    // MARK: radial menu (SPEC §11.2)

    func showRadial() {
        closeMenus()
        readSelection()
        let items = [
            RadialMenuView.Item(id: "polish", title: "Polish", glyph: "✎", enabled: pendingSelection != nil),
            RadialMenuView.Item(id: "focus", title: focusUntil == nil ? "Focus" : "Stop focus", glyph: "◷"),
            RadialMenuView.Item(id: "chat", title: "Chat", glyph: "💬", enabled: false),
            RadialMenuView.Item(id: "mic", title: "Mic", glyph: "🎙", enabled: false),
            RadialMenuView.Item(id: "hide", title: "Hide", glyph: "◌"),
            RadialMenuView.Item(id: "settings", title: "Settings", glyph: "⚙"),
        ]
        // Around Frogg's body; a half-ring above or below him near the screen's bottom or top,
        // then nudged so every button and label is on screen.
        let body = NSPoint(x: froggPanel.frame.midX, y: froggPanel.frame.minY + spriteSize.height / 2)
        let screen = froggScreen
        let layout = Placement.radialLayout(center: body, visible: screen)
        let view = RadialMenuView(items: items, layout: layout)
        view.onSelect = { [weak self] item in self?.radialSelected(item) }
        let panel = OverlayPanel(size: RadialMenuView.size)
        panel.level = .popUpMenu
        panel.contentView = view
        var origin = NSPoint(x: body.x - RadialMenuView.size.width / 2, y: body.y - RadialMenuView.size.height / 2)
        let content = Placement.screenRect(of: view.contentRect, inFlippedViewOfHeight: RadialMenuView.size.height, windowOrigin: origin)
        let fitted = Placement.fit(content, in: screen)
        origin.x += fitted.minX - content.minX
        origin.y += fitted.minY - content.minY
        panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        Debug.log("radial layout=\(layout) shifted=(\(Int(fitted.minX - content.minX)),\(Int(fitted.minY - content.minY)))")
        panel.orderFrontRegardless()
        radialPanel = panel
        radialView = view
        Debug.log("radial open items=\(items.map { $0.id + ($0.enabled ? "" : "(off)") }.joined(separator: ","))")
        watchOutsideClicks()
    }

    func closeRadial() {
        radialPanel?.orderOut(nil)
        radialPanel = nil
        radialView = nil
    }

    func radialSelected(_ item: RadialMenuView.Item) {
        Debug.log("radial select \(item.id) enabled=\(item.enabled)")
        closeMenus()
        guard item.enabled else {
            let why = !AX.trusted ? "Allow Accessibility in System Settings so I can read your selection"
                                  : "Select some text first, then click me"
            say(item.id == "polish" ? why : "\(item.title) is coming soon 🐸", for: 3)
            return
        }
        switch item.id {
        case "polish": showPolishMenu()
        case "focus": focusUntil == nil ? showFocusMenu() : endFocus(completed: false)
        case "hide": toggleHidden()
        case "settings": toggleMiniMenu()
        default: break
        }
    }

    // MARK: focus guardian (SPEC §6.6)

    func showFocusMenu() {
        showChoices(title: "Focus for", options: ["25 min", "50 min"], style: .round) { [weak self] i in
            self?.startFocus(minutes: i == 0 ? 25 : 50)
        }
    }

    func startFocus(minutes: Int) {
        Debug.log("focus start \(minutes) min")
        focusUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        say("Focus for \(minutes) min. I'll sit still.", for: 3)
        focusTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endFocus(completed: true) }
        }
        userPlaced = false
        reposition(force: true)  // to the ground: no hopping between windows during a session
    }

    func endFocus(completed: Bool) {
        focusTimer?.invalidate()
        focusUntil = nil
        if completed {
            show("emotion_proud", for: 4)
            say("Focus session done! 🎉", for: 4)
        } else {
            say("Focus stopped", for: 2)
        }
        reposition(force: true)
    }

    func nudgeIfDistracting() {
        guard focusUntil != nil, Date().timeIntervalSince(lastNudge) > 120,
              let name = NSWorkspace.shared.frontmostApplication?.localizedName,
              settings.distractingApps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        lastNudge = Date()
        play(.nudge)
        say("\(name)? Back to focus soon 🐸", for: 3)
    }

    // MARK: bubble (SPEC §11.6)

    func say(_ text: String, for seconds: TimeInterval? = 3) {
        Debug.log("say \"\(text.prefix(40))\" hidden=\(userHidden) fullscreenHidden=\(fullscreenHidden)")
        guard !userHidden, !fullscreenHidden else { return }
        let bubble = BubbleView(text: text)
        bubblePanel.contentView = bubble
        bubblePanel.setContentSize(bubble.frame.size)
        bubblePanel.alphaValue = 1
        positionBubble()
        bubblePanel.orderFrontRegardless()
        bubbleTimer?.invalidate()
        if let seconds {
            bubbleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.bubblePanel.orderOut(nil) }
            }
        }
    }

    func positionBubble() {
        guard let froggPanel, let frogg else { return }
        let f = froggPanel.frame
        let s = bubblePanel.frame.size
        let headTop = f.minY + FroggArt.shared.size(frogg.frameName).height * scale
        let screen = froggScreen
        var r = CGRect(x: f.midX - s.width / 2, y: headTop + 2, width: s.width, height: s.height)
        if r.maxY > screen.maxY - 4 { r.origin.y = f.minY - s.height }  // no room above: say it below
        bubblePanel.setFrameOrigin(Placement.fit(r, in: screen, margin: 4).origin)
    }

    func chatStub() {
        guard !userHidden else { return }
        show("idle_0", for: 3)  // turns to face you
        say("Chat is coming soon 🐸", for: 3)
    }

    // MARK: hide / show (⌃⌥H, the screen-share panic button)

    func hideOverlays(fade: TimeInterval) {
        for p in [froggPanel, bubblePanel, resultPanel, radialPanel].compactMap({ $0 }) {
            NSAnimationContext.runAnimationGroup({ $0.duration = fade; p.animator().alphaValue = 0 },
                                                 completionHandler: { MainActor.assumeIsolated { p.orderOut(nil) } })
        }
    }

    @objc func toggleHidden() {
        userHidden.toggle()
        Debug.log("hide toggled hidden=\(userHidden)")
        closeMenus()
        if userHidden {
            cancelMotion()
            hideOverlays(fade: 0.15)
        } else if !fullscreenHidden, let spot = target() {
            userPlaced = false
            dropIn(to: spot.foot)
        }
    }

    // MARK: mini menu (⌃⌥P, SPEC §11.5)

    func toggleMiniMenu() {
        Debug.log("mini menu toggle (open=\(miniPanel?.isVisible == true))")
        if let p = miniPanel, p.isVisible { p.orderOut(nil); miniPanel = nil; return }
        // Open at once with what we last knew; fresh service/wallet status fills in after.
        var status = cachedStatus ?? ServiceStatus(service: "checking…")
        status.lastVerdict = lastVerdict
        let view = MiniMenuView(settings: settings, status: status)
        view.fit()
        let panel = KeyPanel(size: view.frame.size)
        panel.level = .popUpMenu
        panel.contentView = view
        panel.onCancel = { [weak self] in self?.miniPanel?.orderOut(nil); self?.miniPanel = nil }
        view.onClose = panel.onCancel
        view.onChange = { [weak self] s in self?.apply(s) }
        view.onOpenWallet = { [weak self] in self?.openWallet() }
        placeBeside(panel)
        panel.makeKeyAndOrderFront(nil)
        miniPanel = panel
        Debug.log("mini menu shown")
        Task { @MainActor [weak self, weak view, weak panel] in
            guard let self else { return }
            var fresh = await self.client.status()
            fresh.lastVerdict = self.lastVerdict
            self.cachedStatus = fresh
            guard let view, let panel, panel.isVisible else { return }
            let top = panel.frame.maxY
            view.update(status: fresh)
            panel.setContentSize(view.frame.size)
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
            Debug.log("mini menu status updated: service=\(fresh.service) walletReady=\(fresh.walletReady)")
        }
    }

    func apply(_ new: PixlSettings) {
        let old = settings
        settings = new
        if new.scale != old.scale { setSize(new.scale) }
        if new.perchOnWindows != old.perchOnWindows { userPlaced = false; reposition(force: true) }
        if new.hideInFullscreen != old.hideInFullscreen { updateFullscreen() }
    }

    func setSize(_ s: Int) {
        settings.scale = s
        settings.save()
        cancelMotion()
        buildFrogg()
        froggPanel.orderFrontRegardless()
        userPlaced = false
        reposition(force: true)
        backToIdle()
    }

    // MARK: menu bar (SPEC §11.3)

    func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = FroggArt.shared.nsImage("idle_0", scale: 1) {
            img.size = NSSize(width: 25, height: 18)
            item.button?.image = img
        }
        item.button?.toolTip = "Pixl Memory"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Debug.log("menu bar menu open")
        menu.removeAllItems()
        readSelection()
        func add(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }
        _ = add("Open menu", #selector(openRadialFromMenu))
        let polish = add("Polish selection", nil)
        polish.submenu = NSMenu()
        instructionItems().forEach { polish.submenu?.addItem($0) }
        let send = add("Send to", nil)
        send.submenu = NSMenu()
        send.submenu?.addItem(withTitle: "No devices nearby", action: nil, keyEquivalent: "").isEnabled = false

        let mischief = add("Mischief", nil)
        mischief.submenu = NSMenu()
        for level in ["chill", "normal", "chaos"] {
            let i = NSMenuItem(title: level.capitalized, action: #selector(setMischief(_:)), keyEquivalent: "")
            i.representedObject = level
            i.target = self
            i.state = settings.mischief == level ? .on : .off
            mischief.submenu?.addItem(i)
        }
        mischief.submenu?.addItem(.separator())
        mischief.submenu?.addItem(withTitle: "Mischief acts come in a later version", action: nil, keyEquivalent: "").isEnabled = false

        let size = add("Size", nil)
        size.submenu = NSMenu()
        for s in [2, 3, 4] {
            let i = NSMenuItem(title: "\(s)×", action: #selector(sizeChosen(_:)), keyEquivalent: "")
            i.tag = s
            i.target = self
            i.state = settings.scale == s ? .on : .off
            size.submenu?.addItem(i)
        }
        _ = add(paused ? "Resume" : "Pause", #selector(togglePause))
        _ = add("Reset position", #selector(resetPosition))
        _ = add(userHidden ? "Show \(settings.name)  ⌃⌥H" : "Hide \(settings.name)  ⌃⌥H", #selector(toggleHidden))
        menu.addItem(.separator())
        let wallet = add("Frogg's wallet…", #selector(openWallet))
        Task { @MainActor in
            let s = await client.status()
            wallet.title = "Wallet: " + (s.wallet ?? "not set up")
        }
        _ = add("Settings…  ⌃⌥P", #selector(openMiniMenu))
        _ = add("Permissions…", #selector(openAccessibility))
        menu.addItem(.separator())
        _ = add("Quit Pixl Memory", #selector(quit), "q")
    }

    @objc func openRadialFromMenu() { if !userHidden { showRadial() } }
    @objc func openMiniMenu() { toggleMiniMenu() }
    @objc func setMischief(_ sender: NSMenuItem) {
        settings.mischief = sender.representedObject as? String ?? "normal"
        settings.save()
    }
    @objc func sizeChosen(_ sender: NSMenuItem) { setSize(sender.tag) }

    @objc func togglePause() {
        paused.toggle()
        if paused {
            cancelMotion()
            cancelAnimations()
            frogg.frameName = "idle_0"
            say("Paused", for: 1.5)
        } else {
            reposition(force: true)
            scheduleIdle()
        }
    }

    @objc func resetPosition() {
        userPlaced = false
        paused = false
        reposition(force: true)
    }

    @objc func openWallet() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(client.port)/wallet/setup")!)
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: self-test (--selftest): clicks through the real panels with posted events

    func post(_ type: NSEvent.EventType, at p: NSPoint, in view: NSView, clicks: Int = 1) {
        guard let w = view.window else { return }
        let e = NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: clicks, pressure: [.leftMouseUp, .rightMouseUp].contains(type) ? 0 : 1)!
        NSApp.postEvent(e, atStart: false)
    }

    func click(_ view: NSView, at p: NSPoint, clicks: Int = 1) {
        post(.leftMouseDown, at: p, in: view, clicks: clicks)
        post(.leftMouseUp, at: p, in: view, clicks: clicks)
    }

    func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    func selfTest() async {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) {
            results.append((name, ok))
            let line = "\(ok ? "PASS" : "FAIL")  \(name)"
            print(line)
            Debug.log("selftest " + line)
        }
        await wait(1.0)
        paused = true  // keep Frogg still while we click it
        settings.hideInFullscreen = false  // for this run only (not saved): the terminal may be fullscreen
        fullscreenHidden = false
        cancelMotion()
        froggPanel.alphaValue = 1
        froggPanel.orderFrontRegardless()
        let belly = NSPoint(x: frogg.bounds.midX, y: 40)

        click(frogg, at: belly)
        await wait(0.12)
        check("click Frogg → poke animation", frogg.frameName.hasPrefix("poke"))
        await wait(NSEvent.doubleClickInterval + 0.25)
        check("click Frogg → menu opens", radialPanel?.isVisible == true)
        closeMenus()
        await wait(1.2)

        // a slow trackpad press (0.4 s, 4 pt of jitter) is still a click, not a throw
        post(.leftMouseDown, at: belly, in: frogg)
        await wait(0.2)
        post(.leftMouseDragged, at: NSPoint(x: belly.x + 3, y: belly.y + 3), in: frogg)
        await wait(0.2)
        post(.leftMouseUp, at: NSPoint(x: belly.x + 3, y: belly.y + 3), in: frogg)
        await wait(NSEvent.doubleClickInterval + 0.25)
        check("slow jittery press → click (menu), not a throw", radialPanel?.isVisible == true && mode == .perched && flight == nil)
        closeMenus()
        await wait(1.2)

        post(.leftMouseDown, at: belly, in: frogg)
        await wait(0.7)
        check("press and hold Frogg → menu opens", radialPanel?.isVisible == true)
        post(.leftMouseUp, at: belly, in: frogg)
        await wait(0.2)
        check("…and stays open after letting go", radialPanel?.isVisible == true)
        closeMenus()
        await wait(0.5)

        click(frogg, at: belly)
        click(frogg, at: belly, clicks: 2)
        await wait(0.12)
        check("double-click Frogg → signature", frogg.frameName.hasPrefix("signature"))
        await wait(2.5)

        post(.rightMouseDown, at: belly, in: frogg)
        post(.rightMouseUp, at: belly, in: frogg)
        await wait(0.3)
        check("right-click Frogg → radial menu opens", radialPanel?.isVisible == true)

        if let rv = radialView {
            let c = rv.centers
            click(rv, at: c[1])
            await wait(0.3)
            check("radial Focus → 25/50 picker opens", choicePanel?.isVisible == true && radialPanel == nil)
            if let cv = choiceView, let p = cv.center(of: 0) {
                click(cv, at: p)
                await wait(0.3)
            }
            check("picker 25 min → focus session starts", focusUntil != nil && choicePanel == nil)
            endFocus(completed: false)
        }

        showRadial()
        await wait(0.3)
        if let rv = radialView {
            click(rv, at: rv.centers[2])
            await wait(0.3)
            check("radial Chat (disabled) → \"coming soon\" bubble", (bubblePanel.contentView as? BubbleView)?.text.contains("coming soon") == true)
        }

        showRadial()
        await wait(0.3)
        if let rv = radialView {
            click(rv, at: rv.centers[5])
            await wait(0.3)  // must open at once, before any network status arrives
            check("radial Settings → mini menu opens at once", miniPanel?.isVisible == true)
            if let mv = miniPanel?.contentView as? MiniMenuView, let p = mv.closeButtonCenter {
                click(mv, at: p)
                await wait(0.3)
            }
            check("mini menu ✕ → closes", miniPanel == nil)
        }

        pendingSelection = ("teh frog sit on the windw", "SelfTest")
        showPolishMenu()
        await wait(0.3)
        if let cv = choiceView, let p = cv.center(of: 1) {
            click(cv, at: p)
            await wait(0.3)
        }
        check("polish picker → \"Make it shorter\" chosen (not sent)", chosenInSelfTest == 1 && choicePanel == nil)

        showRadial()
        await wait(0.3)
        if let rv = radialView {
            click(rv, at: rv.centers[4])
            await wait(0.4)
            check("radial Hide → Frogg hidden", userHidden)
            toggleHidden()
        }

        // every menu stays on screen, wherever Frogg is
        func inside(_ r: NSRect) -> Bool { froggScreen.insetBy(dx: -0.5, dy: -0.5).contains(r) }
        let vis = screensTopLeft.first ?? .zero
        for (name, spot) in [("bottom-right corner", CGPoint(x: vis.maxX - 10, y: vis.maxY)),
                             ("top-left corner", CGPoint(x: vis.minX + 10, y: vis.minY + spriteSize.height + 4))] {
            place(at: spot)
            showRadial()
            await wait(0.2)
            if let rv = radialView, let rp = radialPanel {
                let r = Placement.screenRect(of: rv.contentRect, inFlippedViewOfHeight: rv.bounds.height, windowOrigin: rp.frame.origin)
                check("menu fully on screen at the \(name) (layout \(rv.layout))", inside(r))
            }
            showFocusMenu()
            await wait(0.2)
            check("Focus picker fully on screen at the \(name)", choicePanel.map { inside($0.frame) } == true)
            closeMenus()
            say("A long-ish bubble to check it stays on screen", for: 1)
            check("bubble fully on screen at the \(name)", inside(bubblePanel.frame))
        }
        bubblePanel.orderOut(nil)
        reposition(force: true)
        await wait(0.3)

        // motion: the display link runs only while moving, lands exactly, never jumps on retarget
        paused = false
        cancelMotion()
        await wait(0.3)
        if let start = foot {
            let target = CGPoint(x: start.x - 420, y: start.y)
            run(Choreography.hop(route(from: start, to: target)), target: target)
            await wait(0.1)
            check("hop: display link runs while moving", link != nil)
            let retargetTo = CGPoint(x: start.x - 200, y: start.y)
            await wait(0.3)  // into the flight (after the notice beat and the coil)
            var snap: CGFloat = .infinity
            var fastest: CGFloat = 0
            if let m = motion {
                let t = now - motionStart
                let before = m.pose(at: t).pose.foot
                let next = m.retargeted(at: t) { [unowned self] in self.route(from: $0, to: retargetTo) }
                let after = next.pose(at: 0).pose.foot
                snap = hypot(after.x - before.x, after.y - before.y)
                motion = next
                motionStart = now
                lastMotionT = 0
                motionTarget = retargetTo
                // speed through the new flight, sampled finely (pt per 1/60 s)
                var prev = after
                for k in 1...240 {
                    let p = next.pose(at: Double(k) / 240 * next.duration).pose.foot
                    let perFrame = hypot(p.x - prev.x, p.y - prev.y) / CGFloat(next.duration / 240 * 60)
                    fastest = max(fastest, perFrame)
                    prev = p
                }
            }
            check("retarget mid-air: continues from where Frogg is (gap \(String(format: "%.1f", snap)) pt, fastest \(Int(fastest)) pt/frame)",
                  snap < 0.5 && fastest < 40)
            await wait(1.6)
            check("hop lands on the new target, squash back to neutral",
                  foot.map { hypot($0.x - retargetTo.x, $0.y - retargetTo.y) < 0.5 } == true && frogg.squash == CGSize(width: 1, height: 1))
            check("display link stops when motion ends", link == nil)
            let t0 = now
            dropIn(to: retargetTo)
            while motion != nil && now - t0 < 2 { await wait(0.01) }
            check("Space drop-in finishes within 0.6 s (\(Int((now - t0) * 1000)) ms)", now - t0 <= 0.62)
        }

        let failed = results.filter { !$0.1 }.count
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
