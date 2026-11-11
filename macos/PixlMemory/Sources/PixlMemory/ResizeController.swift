import AppKit
import PixlMemoryKit

/// Settings ▸ Adjust size… (or the menu bar ▸ Size): a pixel-art box with four corner handles
/// around the Pixl; drag a corner to scale it (feet planted, 1× to 6× in crisp half steps, a
/// grid of its art pixels and a size label while you drag). Esc, a click anywhere else, or 30 s
/// untouched ends it. Never shown on its own: hovering or clicking the Pixl doesn't start it.
@MainActor
final class ResizeController {
    unowned let app: AppController
    var panel: HandlesPanel?
    var timer: Timer?
    var monitors: [Any] = []
    var lastTouch = Date()
    var drag: (start: Double, corner: CGVector, feet: CGPoint)?
    var adjusting: Bool { panel != nil }

    init(app: AppController) { self.app = app }

    /// The Pixl's art box (top-left global coordinates), from its standing pose so it stays steady.
    var box: CGRect? {
        guard let foot = app.foot else { return nil }
        let a = FroggArt.shared.size("idle_0")
        let w = a.width * app.scale, h = a.height * app.scale
        return CGRect(x: foot.x - w / 2, y: foot.y - h, width: w, height: h)
    }

    func beginAdjust() {
        guard !adjusting, !app.userHidden, app.awayOn == nil else { return }   // nothing to resize while it's away
        app.cancelMotion()
        app.cancelAnimations()
        app.leaveSurface()
        app.busy = true   // no outings, idle quirks or hops while adjusting
        app.frogg.frameName = "idle_0"
        if let f = app.foot { app.place(at: onScreen(f)) }
        let p = HandlesPanel(controller: self)
        panel = p
        p.label = "Drag a corner · Esc when done"
        refit()
        p.orderFrontRegardless()
        lastTouch = Date()
        Debug.log("resize: adjusting at \(PixlScale.label(app.settings.scale))")
        // Esc, or a click anywhere but the handles, finishes
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] e in
            let esc = e.type == .keyDown && e.keyCode == 53
            let click = e.type != .keyDown
            MainActor.assumeIsolated { if esc || click { self?.finish() } }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { MainActor.assumeIsolated { self?.finish() }; return nil }
            return e
        }) { monitors.append(m) }
        // follows the Pixl wherever it goes (grabbed, thrown, landing), 30 times a second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.drag == nil { self.refit() }
                if self.app.mode != .perched || self.app.moving { self.lastTouch = Date() }
                if self.drag == nil, Date().timeIntervalSince(self.lastTouch) > 30 { self.finish() }
            }
        }
    }

    func finish() {
        guard adjusting, drag == nil else { return }
        timer?.invalidate(); timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        panel?.orderOut(nil); panel = nil
        app.busy = false
        app.settings.save()
        Debug.log("resize: done at \(PixlScale.label(app.settings.scale))")
        app.puff(at: app.foot ?? .zero)
        app.backToIdle()
    }

    func refit() {
        guard let b = box else { return }
        panel?.fit(box: b, scale: app.scale, primaryHeight: app.primaryHeight)
    }

    // MARK: dragging a corner

    func begin(corner: HandlesView.Corner) {
        guard let b = box, let feet = app.foot else { return }
        let c: CGPoint
        switch corner {
        case .topLeft: c = CGPoint(x: b.minX, y: b.minY)
        case .topRight: c = CGPoint(x: b.maxX, y: b.minY)
        case .bottomLeft: c = CGPoint(x: b.minX, y: b.maxY)
        case .bottomRight: c = CGPoint(x: b.maxX, y: b.maxY)
        }
        drag = (app.settings.scale, CGVector(dx: c.x - feet.x, dy: c.y - feet.y), feet)
        panel?.view.showGrid = true
        lastTouch = Date()
        Debug.log("resize start at \(PixlScale.label(app.settings.scale))")
    }

    func moved() {
        guard let d = drag else { return }
        lastTouch = Date()
        let raw = PixlScale.fromDrag(start: d.start, corner: d.corner, mouse: app.mouseTopLeft, feet: d.feet)
        let s = PixlScale.snap(raw, backing: app.froggPanel.backingScaleFactor)
        if s != app.settings.scale {
            app.setSize(s, live: true)
            app.place(at: onScreen(d.feet))
        }
        panel?.label = PixlScale.label(s)
        refit()
        panel?.orderFrontRegardless()
    }

    func ended() {
        guard drag != nil else { return }
        drag = nil
        panel?.view.showGrid = false
        panel?.label = "\(PixlScale.label(app.settings.scale)) · Esc when done"
        app.settings.save()
        Debug.log("resize end at \(PixlScale.label(app.settings.scale))")
    }

    /// Feet moved inward just enough that the whole box (and so every handle) is on screen.
    func onScreen(_ feet: CGPoint) -> CGPoint {
        let a = FroggArt.shared.size("idle_0")
        let w = a.width * app.scale, h = a.height * app.scale, m = HandlesView.handle + 4
        guard let sc = app.screensTopLeft.first(where: { $0.insetBy(dx: -w, dy: -h).contains(feet) }) ?? app.screensTopLeft.first else { return feet }
        let x = min(max(feet.x, sc.minX + w / 2 + m), sc.maxX - w / 2 - m)
        let y = min(max(feet.y, sc.minY + h + m + 28), sc.maxY - m)
        return CGPoint(x: x, y: y)
    }
}

/// The handles' window: around the Pixl's box, clickable only on the four handles.
@MainActor
final class HandlesPanel: NSPanel {
    static let margin: CGFloat = 16
    let view: HandlesView
    var label: String? { didSet { view.label = label; view.needsDisplay = true } }

    init(controller: ResizeController) {
        view = HandlesView(controller: controller)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        becomesKeyOnlyIfNeeded = true
        contentView = view
    }

    /// Around `box` (top-left global coordinates), with room above for the label.
    func fit(box: CGRect, scale: CGFloat, primaryHeight: CGFloat) {
        let m = Self.margin, top: CGFloat = 30
        let r = NSRect(x: box.minX - m, y: primaryHeight - box.maxY - m, width: box.width + 2 * m, height: box.height + 2 * m + top)
        if frame != r { setFrame(r, display: true) }
        view.boxInset = NSEdgeInsets(top: m + top, left: m, bottom: m, right: m)
        view.pixel = scale
        view.needsDisplay = true
        invalidateCursorRects(for: view)
    }
}

/// Pixel-art handles: a border of square dots, chunky 8-bit corner handles, and (while you
/// drag) a faint grid of the art's own pixels, so you see each pixel grow or shrink.
@MainActor
final class HandlesView: NSView {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    unowned let controller: ResizeController
    var boxInset = NSEdgeInsets()
    var label: String?
    var pixel: CGFloat = 2
    var showGrid = false { didSet { needsDisplay = true } }
    static let handle: CGFloat = 14

    init(controller: ResizeController) { self.controller = controller; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    var box: NSRect { NSRect(x: boxInset.left, y: boxInset.bottom, width: bounds.width - boxInset.left - boxInset.right,
                             height: bounds.height - boxInset.top - boxInset.bottom) }

    func point(_ c: Corner) -> NSPoint {
        switch c {
        case .topLeft: NSPoint(x: box.minX, y: box.maxY)
        case .topRight: NSPoint(x: box.maxX, y: box.maxY)
        case .bottomLeft: NSPoint(x: box.minX, y: box.minY)
        case .bottomRight: NSPoint(x: box.maxX, y: box.minY)
        }
    }

    func corner(at p: NSPoint) -> Corner? {
        Corner.allCases.first { abs(point($0).x - p.x) <= Self.handle && abs(point($0).y - p.y) <= Self.handle }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Accent.color
        let b = box
        // the art's pixel grid, faint, while dragging
        if showGrid, pixel >= 1.5 {
            accent.withAlphaComponent(0.16).setFill()
            for x in stride(from: b.minX, through: b.maxX, by: pixel) { NSRect(x: x, y: b.minY, width: 1, height: b.height).fill() }
            for y in stride(from: b.minY, through: b.maxY, by: pixel) { NSRect(x: b.minX, y: y, width: b.width, height: 1).fill() }
        }
        // a border of square "pixels": 2 pt dots every 6 pt, each with a 1 pt ink shadow
        func dot(_ x: CGFloat, _ y: CGFloat) {
            Theme.ink.withAlphaComponent(0.7).setFill(); NSRect(x: x + 1, y: y - 1, width: 2, height: 2).fill()
            accent.setFill(); NSRect(x: x, y: y, width: 2, height: 2).fill()
        }
        for x in stride(from: b.minX, through: b.maxX, by: 6) { dot(x, b.minY - 1); dot(x, b.maxY - 1) }
        for y in stride(from: b.minY, through: b.maxY, by: 6) { dot(b.minX - 1, y); dot(b.maxX - 1, y) }
        // chunky handles: ink outline, paper face, an accent pixel core and a top-left highlight
        for c in Corner.allCases {
            let p = point(c), s = Self.handle
            let r = NSRect(x: (p.x - s / 2).rounded(), y: (p.y - s / 2).rounded(), width: s, height: s)
            Theme.ink.setFill(); NSRect(x: r.minX + 2, y: r.minY - 2, width: s, height: s).fill()   // hard shadow
            Theme.ink.setFill(); r.fill()
            Theme.paper.setFill(); r.insetBy(dx: 2, dy: 2).fill()
            accent.setFill(); r.insetBy(dx: 4, dy: 4).fill()
            NSColor.white.withAlphaComponent(0.7).setFill(); NSRect(x: r.minX + 4, y: r.maxY - 6, width: 2, height: 2).fill()
        }
        if let label {
            let font = Theme.mono(11, .bold)
            let size = (label as NSString).size(withAttributes: [.font: font])
            let w = size.width + 16, h: CGFloat = 20
            let pill = NSRect(x: (b.midX - w / 2).rounded(), y: b.maxY + 8, width: w, height: h)
            // a stepped, pixel-cornered plate
            Theme.ink.setFill()
            NSRect(x: pill.minX + 2, y: pill.minY, width: pill.width - 4, height: pill.height).fill()
            NSRect(x: pill.minX, y: pill.minY + 2, width: pill.width, height: pill.height - 4).fill()
            accent.setFill(); NSRect(x: pill.minX + 2, y: pill.minY, width: pill.width - 4, height: 2).fill()
            (label as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: [.font: font, .foregroundColor: Theme.paper])
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        corner(at: convert(point, from: superview)) != nil ? self : nil   // only the handles catch clicks
    }

    override func resetCursorRects() {
        for c in Corner.allCases {
            let p = point(c), s = Self.handle * 2
            let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            if #available(macOS 15.0, *) {
                let pos: NSCursor.FrameResizePosition = switch c {
                case .topLeft: .topLeft
                case .topRight: .topRight
                case .bottomLeft: .bottomLeft
                case .bottomRight: .bottomRight
                }
                addCursorRect(r, cursor: .frameResize(position: pos, directions: .all))
            } else {
                addCursorRect(r, cursor: .crosshair)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let c = corner(at: convert(event.locationInWindow, from: nil)) { controller.begin(corner: c) }
    }
    override func mouseDragged(with event: NSEvent) { controller.moved() }
    override func mouseUp(with event: NSEvent) { controller.ended() }
}
