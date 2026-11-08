import AppKit
import PixlMemoryKit
import PixlzCore

/// A borderless panel that never becomes key or main (SPEC R5): the app you're
/// typing in keeps focus and its selection while you use Frogg.
final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let scale: CGFloat = 2
    let client = MemoryClient()
    let watcher = WindowWatcher()
    lazy var frogg = FroggView(scale: scale)
    lazy var froggPanel = OverlayPanel(size: frogg.frame.size)
    let bubblePanel = OverlayPanel(size: NSSize(width: 10, height: 10))
    var resultPanel: OverlayPanel?
    var statusItem: NSStatusItem?

    var foot: CGPoint?                // current foot position, top-left coordinates
    var hop: (plan: HopPlan, start: TimeInterval)?
    var motionTimer: Timer?
    var idleTimer: Timer?
    var bubbleTimer: Timer?
    var permissionTimer: Timer?
    var busy = false
    var hidden = false

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        froggPanel.contentView = frogg
        frogg.onClick = { [weak self] e in self?.froggClicked(e) }
        setUpStatusItem()
        if !AX.trusted {
            AX.requestTrust()
            say("I need Accessibility to see your window and selection", for: 8)
        }
        watcher.onChange = { [weak self] in self?.reposition() }
        watcher.start()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Re-check permission until granted, then start following windows.
        if !AX.trusted {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AX.trusted else { return }
                    self.permissionTimer?.invalidate()
                    self.watcher.attachToFrontmost()
                }
            }
            permissionTimer?.tolerance = 1
        }
        reposition()
        froggPanel.orderFrontRegardless()
        scheduleIdle()
    }

    @objc func screensChanged() { reposition() }

    // MARK: placement and motion

    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    var screensTopLeft: [CGRect] {
        NSScreen.screens.map { Perch.toAppKit($0.visibleFrame, primaryHeight: primaryHeight) }  // same flip both ways
    }

    var spriteSize: CGSize {
        // The idle silhouette, for clearance; the panel itself is the full canvas.
        let s = FroggArt.shared.size("idle_0")
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func reposition() {
        guard !hidden, let spot = Perch.spot(window: watcher.activeWindowFrame, screens: screensTopLeft, sprite: spriteSize) else { return }
        guard let current = foot else { place(at: spot.foot); return }
        let d = hypot(spot.foot.x - current.x, spot.foot.y - current.y)
        if d < 1 { return }
        // Small moves are the window being dragged: ride along. Big ones: hop over.
        if hop == nil && d < 60 { place(at: spot.foot) } else { hopTo(spot.foot) }
    }

    func place(at p: CGPoint) {
        foot = p
        froggPanel.setFrame(Perch.panelFrame(foot: p, canvas: frogg.frame.size, primaryHeight: primaryHeight), display: true)
        positionBubble()
    }

    func hopTo(_ target: CGPoint) {
        guard let start = foot else { place(at: target); return }
        let g = 900 * Double(scale)  // pixl.json gravity, apx/s² → pt/s²
        hop = (HopPlan(from: start, to: target, apexHeight: 30 * Double(scale), gravity: g), ProcessInfo.processInfo.systemUptime + 0.2)
        frogg.frameName = "move_0"  // coil
        idleTimer?.invalidate()
        motionTimer?.invalidate()
        // The display timer runs only while Frogg is moving (SPEC R6).
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepHop() }
        }
    }

    func stepHop() {
        guard let (plan, t0) = hop else { motionTimer?.invalidate(); return }
        let t = ProcessInfo.processInfo.systemUptime - t0
        if t < 0 { return }  // still coiling
        if t >= plan.duration {
            hop = nil
            motionTimer?.invalidate()
            place(at: plan.end)
            frogg.frameName = "move_2"
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.backToIdle() }
            }
            return
        }
        frogg.frameName = "move_1"
        place(at: plan.position(at: t))
    }

    // MARK: idle (timers only on frame changes, SPEC §4.4)

    func backToIdle() {
        guard hop == nil else { return }
        frogg.frameName = "idle_0"
        scheduleIdle()
    }

    func scheduleIdle() {
        idleTimer?.invalidate()
        let wait = Double.random(in: 3...8)
        idleTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hop == nil, !self.busy, self.frogg.frameName.hasPrefix("idle") else { return }
                let next = Bool.random() ? "idle_1" : "idle_2"  // blink or throat puff
                self.frogg.frameName = next
                self.idleTimer = Timer.scheduledTimer(withTimeInterval: next == "idle_1" ? 0.17 : 0.66, repeats: false) { _ in
                    MainActor.assumeIsolated { self.backToIdle() }
                }
            }
        }
        idleTimer?.tolerance = 0.5
    }

    func show(_ frame: String, for seconds: TimeInterval) {
        idleTimer?.invalidate()
        frogg.frameName = frame
        idleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.backToIdle() }
        }
    }

    // MARK: bubble

    func say(_ text: String, for seconds: TimeInterval? = 3) {
        let bubble = BubbleView(text: text)
        bubblePanel.contentView = bubble
        bubblePanel.setContentSize(bubble.frame.size)
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
        let f = froggPanel.frame
        let s = bubblePanel.frame.size
        let art = FroggArt.shared.size(frogg.frameName)
        let headTop = f.minY + art.height * scale
        var origin = NSPoint(x: f.midX - s.width / 2, y: headTop + 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) })?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - s.width - 4)
            if origin.y + s.height > screen.maxY { origin.y = f.minY - s.height }  // no room above: say it below
        }
        bubblePanel.setFrameOrigin(origin)
    }

    // MARK: clicking Frogg

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

    func froggClicked(_ event: NSEvent) {
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier ?? 0
        let text = AX.trusted ? AX.selectedText(pid: pid) : nil
        pendingSelection = text.map { ($0, front?.localizedName) }
        show("poke_1", for: 1.2)

        let menu = NSMenu()
        if busy {
            menu.addItem(withTitle: "Working on it…", action: nil, keyEquivalent: "")
        } else if let text {
            let preview = text.replacingOccurrences(of: "\n", with: " ")
            let header = NSMenuItem(title: "“\(preview.prefix(40))\(preview.count > 40 ? "…" : "")”", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (i, ins) in instructions.enumerated() {
                let item = NSMenuItem(title: ins.title, action: #selector(polishChosen(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                menu.addItem(item)
            }
        } else {
            let item = NSMenuItem(title: AX.trusted ? "Select some text first" : "Allow Accessibility to read selections",
                                  action: AX.trusted ? nil : #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Frogg", action: #selector(toggleHidden), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Pixl Memory", action: #selector(quit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: frogg.convert(event.locationInWindow, from: nil), in: frogg)
    }

    @objc func polishChosen(_ sender: NSMenuItem) {
        guard let sel = pendingSelection, instructions.indices.contains(sender.tag) else { return }
        let ins = instructions[sender.tag]
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
                show(v.verdict == "verified" ? "emotion_proud" : v.verdict == "partial" ? "emotion_curious" : "emotion_annoyed", for: 4)
                say(v.verdict == "verified" ? "✔ Verified in TEE · \(v.passed)/\(v.checks.count)" : v.badge, for: 4)
                showResult(.result(r, instruction: ins.title, app: sel.app))
            } catch {
                let e = (error as? MemoryError) ?? .upstream(error.localizedDescription)
                show("emotion_annoyed", for: 5)
                say(e.bubble, for: 6)
                switch e {
                case .attestationFailed, .serviceDown, .noApiKey, .noCredits: showResult(.error(e, app: sel.app))
                default: break
                }
            }
        }
    }

    // MARK: result panel

    func showResult(_ content: PolishView.Content) {
        let view = PolishView(content)
        view.fit()
        let panel = resultPanel ?? OverlayPanel(size: view.frame.size)
        resultPanel = panel
        panel.level = .popUpMenu
        panel.contentView = view
        panel.setContentSize(view.frame.size)
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
            self.placeResultPanel(panel)
        }
        placeResultPanel(panel)
        panel.orderFrontRegardless()
    }

    func placeResultPanel(_ panel: NSPanel) {
        let f = froggPanel.frame
        let s = panel.frame.size
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) })?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        // Beside Frogg, preferring the left (Frogg sits near the window's right edge).
        var x = f.minX - s.width - 8
        if x < screen.minX + 8 { x = f.maxX + 8 }
        x = min(max(x, screen.minX + 8), screen.maxX - s.width - 8)
        var y = f.maxY - s.height
        y = min(max(y, screen.minY + 8), screen.maxY - s.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
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
        menu.addItem(withTitle: "Hide / show Frogg", action: #selector(toggleHidden), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Accessibility settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pixl Memory", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc func toggleHidden() {
        hidden.toggle()
        if hidden {
            froggPanel.orderOut(nil); bubblePanel.orderOut(nil); resultPanel?.orderOut(nil)
        } else {
            froggPanel.orderFrontRegardless()
            reposition()
        }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }
}
