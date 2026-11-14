import AppKit
import PixlAgents
import PixlMemoryKit

/// The chat panels (two-way Agent mode): one per session you open. The transcript tail (read
/// from the session's own file on this Mac; never sent anywhere), its state, and a field to
/// message it. Docked beside the Pixl, or torn off into its own window; resizable from any edge.
@MainActor
final class AgentChats {
    unowned let app: AppController
    private(set) var panels: [String: AgentChatPanel] = [:]

    init(app: AppController) {
        self.app = app
        app.agents.onChat = { [weak self] sid in self?.panels[sid]?.refresh() }
        app.agents.onDoneAsk = { [weak self] sid in self?.doneAsk(sid) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels.values.forEach { $0.keepOnScreen() } }
        }
    }

    func open(_ sid: String) {
        if let p = panels[sid] { p.show(); return }
        let p = AgentChatPanel(sessionID: sid, app: app) { [weak self] in self?.panels[sid] = nil }
        panels[sid] = p
        p.show()
    }

    /// The session whose "done. Anything else?" prompt is showing.
    private var doneAskShown: String?

    /// A session finished its turn and Pixlz holds it for your reply: the Pixl asks. A low-key
    /// prompt: it never takes the keyboard from what you're typing in, never replaces a list
    /// you're using, and goes when the reply window closes (nil).
    private func doneAsk(_ sid: String?) {
        guard let sid else {
            if doneAskShown != nil, app.menu.list?.rows.contains(where: { $0.id == "doneask.reply" }) == true { app.menu.closeList() }
            doneAskShown = nil
            return
        }
        if let p = panels[sid] { p.refresh(); p.focusField(); return }   // the panel's open: it says "Sends now"
        let mine = app.menu.list?.rows.contains(where: { $0.id == "doneask.reply" }) == true
        guard app.menu.listPanel == nil || mine else {
            Debug.log("agents: done prompt not shown (a list is open); it's under Agents")
            return
        }
        let project = app.agents.hub.sessions[sid]?.project ?? "Claude Code"
        let secs = Int(app.agents.replyWindow)
        doneAskShown = sid
        app.menu.showList([ListMenuView.Row(id: "q", title: "\(project): done. Anything else?", icon: "agents", enabled: false),
                           ListMenuView.Row(id: "doneask.reply", title: "Reply", icon: nil, trailing: "\(secs) s"),
                           ListMenuView.Row(id: "dismiss", title: "Dismiss", icon: nil, trailing: "esc")], near: nil, key: false) { [weak self] row in
            guard let self else { return }
            self.doneAskShown = nil
            self.app.menu.closeList()
            if row.id == "doneask.reply" { self.open(sid) } else if row.id == "dismiss" { self.app.agents.letStopGo(sid) }
        }
    }
}

/// One chat panel. Frame (and docked or not) are remembered per session.
@MainActor
final class AgentChatPanel: NSObject {
    let sid: String
    unowned let app: AppController
    let onClose: () -> Void
    let window: KeyPanel
    let surface: SurfaceView
    let root = ChatRoot()
    let title = NSTextField(labelWithString: "")
    let state = NSTextField(labelWithString: "")
    let transcript = NSTextView()
    let scroll = NSScrollView()
    let fieldBox = NSView()
    let input = AgentChatInput(frame: .zero)
    let sendButton: ChatButton
    let hint = NSTextField(labelWithString: "")
    let warning = NSTextField(wrappingLabelWithString: "")
    let sendAnyway: ChatButton
    let cancelSend: ChatButton
    let closeButton: ChatButton
    var bar: ChatTitleBar!
    var edges: ChatEdges!
    var docked = true
    var timer: Timer?
    var lastStamp: Date?
    /// A message held back until you confirm (resuming a session that may be open elsewhere).
    var pending: TypedMessage?
    var look: SurfaceView.Look { app.menu.cardLook }
    var tokens: MaterialTokens { look.tokens }

    static let minSize = NSSize(width: 320, height: 240)
    static let compact = NSSize(width: 360, height: 300)

    init(sessionID: String, app: AppController, onClose: @escaping () -> Void) {
        sid = sessionID
        self.app = app
        self.onClose = onClose
        let size = NSSize(width: 380, height: 440)
        window = KeyPanel(size: size)
        window.level = .floating
        window.animationBehavior = .none
        surface = SurfaceView(frame: NSRect(origin: .zero, size: size), shape: .rounded(14), look: app.menu.cardLook)
        sendButton = ChatButton(title: "Send", primary: true)
        sendAnyway = ChatButton(title: "Send anyway", primary: true)
        cancelSend = ChatButton(title: "Cancel", primary: false)
        closeButton = ChatButton(title: "×", primary: false)
        super.init()
        build()
    }

    // MARK: building

    func build() {
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
        root.frame = surface.content.bounds
        root.autoresizingMask = [.width, .height]
        surface.content.addSubview(root)
        let tk = tokens
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.textColor = tk.text
        title.lineBreakMode = .byTruncatingTail
        state.font = Theme.mono(9.5)
        state.textColor = tk.text2
        state.lineBreakMode = .byTruncatingTail
        bar = ChatTitleBar(panel: self)
        bar.addSubview(title)
        bar.addSubview(state)
        bar.addSubview(closeButton)
        closeButton.action = { [weak self] in self?.close() }
        closeButton.setAccessibilityLabel("Close the chat")

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 4, height: 6)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        scroll.documentView = transcript
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        fieldBox.wantsLayer = true
        fieldBox.layer?.cornerRadius = 9
        fieldBox.layer?.borderWidth = 2
        fieldBox.layer?.borderColor = tk.line.cgColor
        fieldBox.layer?.backgroundColor = tk.chip.cgColor
        input.font = .systemFont(ofSize: 13)
        input.textColor = tk.text
        input.placeholderString = "Message this session…"
        input.onSend = { [weak self] m in self?.typed(m) }
        fieldBox.addSubview(input)
        sendButton.action = { [weak self] in self?.input.sendTyped() }
        hint.font = Theme.mono(9)
        hint.textColor = tk.text2
        warning.font = .systemFont(ofSize: 11.5)
        warning.textColor = Theme.failed
        sendAnyway.action = { [weak self] in self?.confirmPending() }
        cancelSend.action = { [weak self] in self?.pending = nil; self?.layoutAll(); self?.refresh() }

        [bar!, scroll, fieldBox, sendButton, hint, warning, sendAnyway, cancelSend].forEach(root.addSubview)
        edges = ChatEdges(panel: self)
        root.addSubview(edges)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSWindow.didResizeNotification, object: window)
        window.onCancel = { [weak self] in self?.close() }
    }

    @objc func resized() { layoutAll(); saveFrame() }

    func layoutAll() {
        let b = root.bounds
        let pad: CGFloat = 12
        bar.frame = NSRect(x: 0, y: 0, width: b.width, height: 44)
        closeButton.frame = NSRect(x: b.width - pad - 24, y: 10, width: 24, height: 22)
        title.frame = NSRect(x: pad, y: 7, width: b.width - pad * 2 - 30, height: 17)
        state.frame = NSRect(x: pad, y: 25, width: b.width - pad * 2 - 30, height: 13)
        let confirm = pending != nil
        let warnH: CGFloat = confirm ? 64 : 0
        let fieldH: CGFloat = 54
        let bottom = b.height - pad
        hint.frame = NSRect(x: pad, y: bottom - 13, width: b.width - pad * 2, height: 13)
        fieldBox.frame = NSRect(x: pad, y: hint.frame.minY - 6 - fieldH, width: b.width - pad * 2 - 70, height: fieldH)
        input.frame = fieldBox.bounds.insetBy(dx: 8, dy: 6)
        sendButton.frame = NSRect(x: fieldBox.frame.maxX + 8, y: fieldBox.frame.maxY - 30, width: 62, height: 30)
        warning.isHidden = !confirm; sendAnyway.isHidden = !confirm; cancelSend.isHidden = !confirm
        if confirm {
            warning.frame = NSRect(x: pad, y: fieldBox.frame.minY - warnH, width: b.width - pad * 2, height: 30)
            sendAnyway.frame = NSRect(x: pad, y: warning.frame.maxY + 2, width: 110, height: 26)
            cancelSend.frame = NSRect(x: pad + 118, y: warning.frame.maxY + 2, width: 80, height: 26)
        }
        let top = bar.frame.maxY
        scroll.frame = NSRect(x: pad - 4, y: top, width: b.width - (pad - 4) * 2, height: max(40, fieldBox.frame.minY - warnH - 8 - top))
        edges.frame = b
    }

    // MARK: showing

    func show() {
        restoreFrame()
        layoutAll()
        refresh()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        focusField()
        timer?.invalidate()
        // the transcript is a file Claude Code appends to: re-read it while the panel is open
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.docked { self.dock(animated: false) }
                self.refreshIfChanged()
            }
        }
        timer?.tolerance = 0.3
        Debug.log("agents: chat open for \(project)")
    }

    func focusField() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(input) }

    func close() {
        timer?.invalidate(); timer = nil
        saveFrame()
        window.orderOut(nil)
        NotificationCenter.default.removeObserver(self)
        onClose()
    }

    var project: String { app.agents.hub.sessions[sid]?.project ?? "Claude Code" }

    // MARK: sending

    /// From the field (your Return or Send click). Resuming a session that may still be open in
    /// a terminal waits for your confirm.
    func typed(_ m: TypedMessage) {
        let agents = app.agents
        if agents.route(sid) == .resume, agents.mayBeOpenElsewhere(sid) {
            pending = m
            warning.stringValue = "This session may still be open in a terminal. Sending here can conflict with it."
            layoutAll()
            return
        }
        agents.send(m, to: sid)
        refresh()
    }

    func confirmPending() {
        guard let m = pending else { return }
        pending = nil
        app.agents.send(m, to: sid)
        layoutAll()
        refresh()
    }

    // MARK: the transcript

    var transcriptURL: URL? { app.agents.hub.sessions[sid]?.transcriptPath.flatMap { TranscriptReader.validated($0) } }

    func refreshIfChanged() {
        let stamp = transcriptURL.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        if stamp != lastStamp { lastStamp = stamp; refresh() } else { refreshChrome() }
    }

    func refreshChrome() {
        let agents = app.agents
        let s = agents.hub.sessions[sid]
        title.stringValue = project
        let held = agents.hub.heldStops[sid] != nil
        state.stringValue = held ? "Done · waiting for your reply" : agents.resuming[sid] != nil ? "Resumed · working" : (s?.doing ?? "Not heard from")
        var h = agents.route(sid).label
        if agents.route(sid) == .resume, agents.findClaudeCached == .some(nil) { h = "Can't resume: Claude Code isn't installed" }
        hint.stringValue = h
    }

    func refresh() {
        refreshChrome()
        let agents = app.agents
        let tk = tokens
        let entries = transcriptURL.map { TranscriptReader.tail($0) } ?? []
        let out = NSMutableAttributedString()
        func add(_ who: String, _ text: String, _ color: NSColor, note: String? = nil) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n\n")) }
            out.append(NSAttributedString(string: who + (note.map { "  · \($0)" } ?? "") + "\n",
                                          attributes: [.font: Theme.mono(9, .bold), .foregroundColor: color]))
            out.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: tk.text]))
        }
        if entries.isEmpty {
            add("Pixlz", transcriptURL == nil ? "No transcript yet (it shows once the session reports in)." : "Nothing said yet.", tk.text2)
        }
        for e in entries.suffix(60) {
            add(e.role == .user ? "YOU (TERMINAL)" : "CLAUDE", e.text, e.role == .user ? tk.text2 : Theme.accent)
        }
        // its last reply, if the file hasn't caught up with it yet
        if let r = agents.hub.sessions[sid]?.lastReply, entries.last(where: { $0.role == .assistant })?.text != r,
           !entries.contains(where: { $0.text == r }) {
            add("CLAUDE", r, Theme.accent, note: "latest")
        }
        for line in agents.resumeLog[sid] ?? [] { add("CLAUDE", line, Theme.accent, note: "resumed run") }
        for m in agents.hub.outbox[sid] ?? [] {
            let status: String = switch m.status {
            case .queued: "queued · " + agents.route(sid).label.lowercased()
            case .delivered: "delivered" + (m.note.map { " (\($0))" } ?? "")
            case .failed: "not sent" + (m.note.map { ": \($0)" } ?? "")
            }
            add("YOU (PIXLZ)", m.text, m.status == .failed ? Theme.failed : tk.text2, note: status)
        }
        let atBottom = scroll.verticalScroller.map { $0.floatValue >= 0.98 } ?? true
        transcript.textStorage?.setAttributedString(out)
        if atBottom { transcript.scrollToEndOfDocument(nil) }
    }

    // MARK: docking, size, position

    var frameKey: String { "PixlMemory.chatFrame.\(sid)" }

    func saveFrame() {
        let f = window.frame
        UserDefaults.standard.set(["x": f.minX, "y": f.minY, "w": f.width, "h": f.height, "docked": docked ? 1 : 0], forKey: frameKey)
    }

    func restoreFrame() {
        if let d = UserDefaults.standard.dictionary(forKey: frameKey) as? [String: Double] {
            let size = NSSize(width: max(Self.minSize.width, d["w"] ?? 380), height: max(Self.minSize.height, d["h"] ?? 440))
            docked = (d["docked"] ?? 1) == 1
            window.setFrame(NSRect(origin: NSPoint(x: d["x"] ?? 0, y: d["y"] ?? 0), size: size), display: false)
        }
        if docked { dock(animated: false) } else { keepOnScreen() }
    }

    /// Beside the Pixl (it follows the Pixl while docked).
    func dock(animated: Bool) {
        let before = window.frame
        app.placeBeside(window)
        if window.frame != before { saveFrame() }
    }

    /// The Pixl's box on screen, for docking by dropping the panel onto it.
    var petFrame: NSRect { app.froggPanel.frame }

    /// Never off every screen (after a display goes away, say).
    func keepOnScreen() {
        let f = window.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        var r = f
        r.size.width = min(max(r.width, Self.minSize.width), vis.width)
        r.size.height = min(max(r.height, Self.minSize.height), vis.height)
        r.origin.x = min(max(r.minX, vis.minX), vis.maxX - r.width)
        r.origin.y = min(max(r.minY, vis.minY), vis.maxY - r.height)
        if r != f { window.setFrame(r, display: true) }
    }

    /// Double-click on the title bar: compact ↔ tall, keeping the top edge where it is.
    func toggleSize() {
        let f = window.frame
        let vis = (window.screen ?? NSScreen.main)?.visibleFrame ?? f
        let tall = NSSize(width: max(f.width, 400), height: min(vis.height * 0.8, 720))
        let next = f.height > Self.compact.height + 20 ? Self.compact : tall
        window.setFrame(NSRect(x: f.minX, y: f.maxY - next.height, width: next.width, height: next.height), display: true, animate: true)
        keepOnScreen()
        saveFrame()
    }
}

/// The title bar: drag to move (away from the Pixl tears it off; drop it on the Pixl to dock
/// it again), double-click to snap between compact and tall.
@MainActor
final class ChatTitleBar: NSView {
    unowned let panel: AgentChatPanel
    var start: (mouse: NSPoint, origin: NSPoint)?
    init(panel: AgentChatPanel) { self.panel = panel; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { panel.toggleSize(); start = nil; return }
        start = (NSEvent.mouseLocation, panel.window.frame.origin)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let m = NSEvent.mouseLocation
        let o = NSPoint(x: s.origin.x + m.x - s.mouse.x, y: s.origin.y + m.y - s.mouse.y)
        panel.window.setFrameOrigin(o)
        if panel.docked, hypot(m.x - s.mouse.x, m.y - s.mouse.y) > 40 {
            panel.docked = false   // torn off: its own window now
            Debug.log("agents: chat torn off")
        }
    }
    override func mouseUp(with e: NSEvent) {
        defer { start = nil }
        guard start != nil else { return }
        if !panel.docked, panel.window.frame.intersects(panel.petFrame.insetBy(dx: -16, dy: -16)) {
            panel.docked = true    // dropped on the Pixl: docked again
            panel.dock(animated: true)
            Debug.log("agents: chat docked")
        }
        panel.keepOnScreen()
        panel.saveFrame()
    }
}

/// Resizing from any edge or corner (8 pt bands); everything inside passes through.
@MainActor
final class ChatEdges: NSView {
    unowned let panel: AgentChatPanel
    let band: CGFloat = 8
    var drag: (edges: (l: Bool, r: Bool, t: Bool, b: Bool), mouse: NSPoint, frame: NSRect)?
    init(panel: AgentChatPanel) { self.panel = panel; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Which edges a point (this view's flipped coordinates) is on.
    func edges(at p: NSPoint) -> (l: Bool, r: Bool, t: Bool, b: Bool) {
        (p.x < band, p.x > bounds.width - band, p.y < band, p.y > bounds.height - band)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let e = edges(at: p)
        return bounds.contains(p) && (e.l || e.r || e.t || e.b) ? self : nil
    }
    override func resetCursorRects() {
        let w = bounds.width, h = bounds.height, b = band
        func add(_ r: NSRect, _ pos: NSCursor.FrameResizePosition) {
            addCursorRect(r, cursor: NSCursor.frameResize(position: pos, directions: .all))
        }
        add(NSRect(x: b, y: 0, width: w - 2 * b, height: b), .top)
        add(NSRect(x: b, y: h - b, width: w - 2 * b, height: b), .bottom)
        add(NSRect(x: 0, y: b, width: b, height: h - 2 * b), .left)
        add(NSRect(x: w - b, y: b, width: b, height: h - 2 * b), .right)
        add(NSRect(x: 0, y: 0, width: b, height: b), .topLeft)
        add(NSRect(x: w - b, y: 0, width: b, height: b), .topRight)
        add(NSRect(x: 0, y: h - b, width: b, height: b), .bottomLeft)
        add(NSRect(x: w - b, y: h - b, width: b, height: b), .bottomRight)
    }
    override func mouseDown(with e: NSEvent) {
        drag = (edges(at: convert(e.locationInWindow, from: nil)), NSEvent.mouseLocation, panel.window.frame)
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - d.mouse.x, dy = m.y - d.mouse.y
        var f = d.frame
        let minW = AgentChatPanel.minSize.width, minH = AgentChatPanel.minSize.height
        if d.edges.r { f.size.width = max(minW, d.frame.width + dx) }
        if d.edges.l { let w = max(minW, d.frame.width - dx); f.origin.x = d.frame.maxX - w; f.size.width = w }
        // window coordinates are y-up: the top edge is maxY
        if d.edges.t { f.size.height = max(minH, d.frame.height + dy) }
        if d.edges.b { let h = max(minH, d.frame.height - dy); f.origin.y = d.frame.maxY - h; f.size.height = h }
        panel.window.setFrame(f, display: true)
    }
    override func mouseUp(with e: NSEvent) {
        drag = nil
        panel.keepOnScreen()
        panel.saveFrame()
        window?.invalidateCursorRects(for: self)
    }
}

/// A small flat button for the chat panel (Send, Send anyway, Cancel, ×).
@MainActor
final class ChatButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    let primary: Bool
    var action: (() -> Void)?
    private var down = false { didSet { needsDisplay = true } }
    init(title: String, primary: Bool) {
        self.title = title; self.primary = primary
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: down ? 1 : 0)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (primary ? Theme.accent : NSColor(white: 0.5, alpha: 0.18)).setFill()
        path.fill()
        Theme.ink.withAlphaComponent(primary ? 1 : 0.4).setStroke()
        path.lineWidth = primary ? 2 : 1
        if title != "×" { path.stroke() }
        let font = NSFont.systemFont(ofSize: title == "×" ? 15 : 12.5, weight: .semibold)
        let color: NSColor = primary ? Theme.ink : (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : Theme.ink)
        let s = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color])
        let sz = s.size()
        s.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    }
    override func mouseDown(with e: NSEvent) { down = true }
    override func mouseUp(with e: NSEvent) {
        down = false
        if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

/// The panel's content: y down, like every other Pixl view.
final class ChatRoot: NSView { override var isFlipped: Bool { true } }
