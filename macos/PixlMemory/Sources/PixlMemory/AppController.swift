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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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
    var hop: (plan: HopPlan, start: TimeInterval)?
    var flight: ThrowFlight?
    var drop: (from: CGPoint, to: CGPoint, start: TimeInterval)?
    var motionTimer: Timer?
    var animTimers: [Timer] = []
    var idleTimer: Timer?
    var bubbleTimer: Timer?
    var permissionTimer: Timer?
    var clickTimer: Timer?
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
        }
        guard !spaceTransition else { return }
        updateFullscreen()
        if change == .moved, mode == .perched, hop == nil, !userPlaced, let spot = target() {
            place(at: spot.foot)  // ride along while the window is dragged
            return
        }
        reposition(force: change == .switched)
    }

    /// Hop to the perch. `force` hops even a short distance (a different window, not a drag).
    func reposition(force: Bool = false) {
        guard !paused, !userHidden, !fullscreenHidden, !spaceTransition, mode == .perched, !userPlaced,
              let spot = target() else { return }
        guard let current = foot else { place(at: spot.foot); return }
        let d = hypot(spot.foot.x - current.x, spot.foot.y - current.y)
        if d < 1 { return }
        if !force && d < 60 { place(at: spot.foot) } else { hopTo(spot.foot) }
    }

    /// Swiping between Spaces: Frogg leaves, then drops in from above onto the new
    /// active window (the travel entrance, SPEC D9).
    @objc func spaceChanged() {
        guard !userHidden else { return }
        spaceTransition = true
        cancelMotion()
        hideOverlays(fade: 0.12)
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watcher.attachToFrontmost()
                self.spaceTransition = false
                if self.settings.hideInFullscreen && self.watcher.activeWindowIsFullscreen {
                    self.fullscreenHidden = true
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

    // MARK: motion (display timer only while moving, SPEC R6)

    func place(at p: CGPoint) {
        foot = p
        froggPanel.setFrame(Perch.panelFrame(foot: p, canvas: frogg.frame.size, primaryHeight: primaryHeight), display: true)
        positionBubble()
    }

    func cancelMotion() {
        motionTimer?.invalidate()
        hop = nil; flight = nil; drop = nil
        if mode != .held { mode = .perched }
    }

    func startMotionTimer(_ step: @escaping @MainActor () -> Void) {
        motionTimer?.invalidate()
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { step() }
        }
    }

    func hopTo(_ target: CGPoint) {
        guard let start = foot else { place(at: target); return }
        cancelAnimations()
        hop = (HopPlan(from: start, to: target, apexHeight: 30 * Double(scale), gravity: 900 * Double(scale)), now + 0.2)
        frogg.frameName = "move_0"  // coil
        startMotionTimer { [weak self] in self?.stepHop() }
    }

    func stepHop() {
        guard let (plan, t0) = hop else { motionTimer?.invalidate(); return }
        let t = now - t0
        if t < 0 { return }
        if t >= plan.duration {
            hop = nil
            motionTimer?.invalidate()
            place(at: plan.end)
            land(frame: "move_2")
            return
        }
        frogg.frameName = "move_1"
        place(at: plan.position(at: t))
    }

    func dropIn(to target: CGPoint) {
        cancelAnimations()
        let screen = screensTopLeft.first { $0.minX <= target.x && target.x <= $0.maxX } ?? screensTopLeft.first ?? .zero
        let from = CGPoint(x: target.x, y: screen.minY + 4)  // just under the menu bar
        mode = .dropping
        drop = (from, target, now)
        frogg.frameName = "move_1"
        place(at: from)
        froggPanel.alphaValue = 1
        froggPanel.orderFrontRegardless()
        startMotionTimer { [weak self] in self?.stepDrop() }
    }

    func stepDrop() {
        guard let (from, to, t0) = drop else { motionTimer?.invalidate(); return }
        let g = 900 * Double(scale)
        let t = now - t0
        let y = from.y + 0.5 * g * t * t
        if y >= to.y {
            drop = nil
            motionTimer?.invalidate()
            mode = .perched
            place(at: to)
            land(frame: "grab_2")  // squash on landing
            return
        }
        place(at: CGPoint(x: to.x, y: y))
    }

    func land(frame: String) {
        frogg.frameName = frame
        after(0.3) { [weak self] in self?.backToIdle() }
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
        guard mode == .perched, hop == nil else { return }
        frogg.frameName = "idle_0"
        scheduleIdle()
    }

    func scheduleIdle() {
        idleTimer?.invalidate()
        guard !paused else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3...8), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode == .perched, self.hop == nil, !self.busy, self.frogg.frameName.hasPrefix("idle") else { return }
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
            if event.clickCount == 2 {
                clickTimer?.invalidate()
                gesture = nil
                signature()
                return
            }
            gesture = PointerGesture(at: mouseTopLeft, time: now)
            dragSamples = [(now, mouseTopLeft)]
        case .dragged:
            guard var g = gesture else { return }
            dragSamples.append((now, mouseTopLeft))
            if g.moved(to: mouseTopLeft) { startGrab() }
            gesture = g
            if mode == .held { moveHeld() }
        case .up:
            defer { gesture = nil }
            if mode == .held { release(); return }
            if let g = gesture, g.isClick(releasedAt: mouseTopLeft, time: now) { clicked(event) }
            else { Debug.log("mouse up: not a click (held ≥250 ms or moved)") }
        case .right:
            showRadial()
        }
    }

    /// Poke: instant reaction; with text selected, the polish menu follows unless this
    /// turns out to be the first half of a double-click.
    func clicked(_ event: NSEvent) {
        let selection = readSelection()
        if pokes.poke(at: now) {
            show("emotion_annoyed", for: 2)
            say("Hey! \(settings.name) is busy being a frog.", for: 2)
            return
        }
        play(.poke)
        if let until = focusUntil {
            say("Focus: \(Int(until.timeIntervalSinceNow / 60) + 1) min left", for: 2)
            return
        }
        guard selection != nil else {
            if !AX.trusted { say("Allow Accessibility so I can read your selection", for: 3) }
            return
        }
        clickTimer?.invalidate()
        clickTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPolishMenu() }
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
        frogg.frameName = "move_1"
        var last = now
        startMotionTimer { [weak self] in
            guard let self, var f = self.flight else { return }
            let t = self.now
            let landed = f.step(dt: min(t - last, 1.0 / 30))
            last = t
            self.flight = f
            self.place(at: f.body.position)
            if let spot = landed {
                self.flight = nil
                self.motionTimer?.invalidate()
                self.mode = .perched
                self.userPlaced = true
                self.place(at: spot)
                self.land(frame: "grab_2")  // splat
            }
        }
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

    func placeBeside(_ panel: NSPanel) {
        let f = froggPanel.frame
        let s = panel.frame.size
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) })?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        var x = f.minX - s.width - 8
        if x < screen.minX + 8 { x = f.maxX + 8 }
        x = min(max(x, screen.minX + 8), screen.maxX - s.width - 8)
        let y = min(max(f.maxY - s.height, screen.minY + 8), screen.maxY - s.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
            // centred over Frogg's head, like the radial menu
            let f = froggPanel.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - view.frame.width / 2, y: f.minY + spriteSize.height + 8))
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
        let view = RadialMenuView(items: items)
        view.onSelect = { [weak self] item in self?.radialSelected(item) }
        let panel = OverlayPanel(size: RadialMenuView.size)
        panel.level = .popUpMenu
        panel.contentView = view
        let body = NSPoint(x: froggPanel.frame.midX, y: froggPanel.frame.minY + spriteSize.height / 2)
        panel.setFrameOrigin(NSPoint(x: body.x - RadialMenuView.size.width / 2, y: body.y - RadialMenuView.size.height / 2))
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
            say(item.id == "polish" ? "Select some text first" : "\(item.title) is coming soon 🐸", for: 2.5)
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
        var origin = NSPoint(x: f.midX - s.width / 2, y: headTop + 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - s.width - 4)
            if origin.y + s.height > screen.maxY { origin.y = f.minY - s.height }
        }
        bubblePanel.setFrameOrigin(origin)
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
        await wait(1.5)

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
            let c = RadialMenuView.centers(count: rv.items.count, in: rv.bounds.size)
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
            click(rv, at: RadialMenuView.centers(count: rv.items.count, in: rv.bounds.size)[2])
            await wait(0.3)
            check("radial Chat (disabled) → \"coming soon\" bubble", (bubblePanel.contentView as? BubbleView)?.text.contains("coming soon") == true)
        }

        showRadial()
        await wait(0.3)
        if let rv = radialView {
            click(rv, at: RadialMenuView.centers(count: rv.items.count, in: rv.bounds.size)[5])
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
            click(rv, at: RadialMenuView.centers(count: rv.items.count, in: rv.bounds.size)[4])
            await wait(0.4)
            check("radial Hide → Frogg hidden", userHidden)
            toggleHidden()
        }

        let failed = results.filter { !$0.1 }.count
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}
