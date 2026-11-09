import AppKit
import PixlMemoryKit

/// Resize like a video window: hover the Pixl and a box with four corner handles appears; drag
/// a corner to scale it (feet planted, 1× to 6× in crisp half steps, a live "2.5×" label).
/// A light 6 Hz check of the mouse position shows and hides the handles; nothing else runs.
@MainActor
final class ResizeController {
    unowned let app: AppController
    var panel: HandlesPanel?
    var timer: Timer?
    var hoverSince: TimeInterval?
    var lastInside: TimeInterval = 0
    var drag: (start: Double, corner: CGVector, feet: CGPoint)?

    init(app: AppController) { self.app = app }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.05
    }

    /// The Pixl's art box (top-left global coordinates).
    var box: CGRect? {
        guard let foot = app.foot, app.frogg.surface == .floor else { return nil }
        let a = FroggArt.shared.size("idle_0")   // a steady box, whatever frame is showing
        let w = a.width * app.scale, h = a.height * app.scale
        return CGRect(x: foot.x - w / 2, y: foot.y - h, width: w, height: h)
    }

    var blocked: Bool {
        app.userHidden || app.paused || app.fullscreenHidden || app.moving || app.menu.isOpen || app.game.isOn
            || app.mode != .perched || (app.busy && drag == nil) || app.awayOn != nil
    }

    func tick() {
        if drag != nil { return }
        guard !blocked, let b = box else { hide(); return }
        let t = app.now
        if b.insetBy(dx: -18, dy: -18).contains(app.mouseTopLeft) {
            lastInside = t
            if hoverSince == nil { hoverSince = t }
            if t - (hoverSince ?? t) >= 0.35 { show(b) }   // a short dwell, so passing over doesn't flash it
        } else {
            hoverSince = nil
            if panel != nil, t - lastInside > 1.0 { hide() }
        }
    }

    func show(_ b: CGRect) {
        let p = panel ?? HandlesPanel(controller: self)
        panel = p
        p.fit(box: b, primaryHeight: app.primaryHeight)
        if !p.isVisible { p.orderFrontRegardless(); Debug.log("resize handles shown") }
    }

    func hide() {
        guard let p = panel, drag == nil else { return }
        p.orderOut(nil)
        panel = nil
        hoverSince = nil
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
        app.busy = true
        app.cancelAnimations()
        app.frogg.frameName = "idle_0"
        Debug.log("resize start at \(PixlScale.label(app.settings.scale))")
    }

    func moved() {
        guard let d = drag else { return }
        let raw = PixlScale.fromDrag(start: d.start, corner: d.corner, mouse: app.mouseTopLeft, feet: d.feet)
        let s = PixlScale.snap(raw, backing: app.froggPanel.backingScaleFactor)
        if s != app.settings.scale {
            app.setSize(s, live: true)
            app.place(at: onScreen(d.feet))
        }
        panel?.label = PixlScale.label(s)
        if let b = box { panel?.fit(box: b, primaryHeight: app.primaryHeight); panel?.orderFrontRegardless() }
    }

    /// Feet moved inward just enough that the whole box (and so every handle) is on screen.
    func onScreen(_ feet: CGPoint) -> CGPoint {
        let a = FroggArt.shared.size("idle_0")
        let w = a.width * app.scale, h = a.height * app.scale, m = HandlesView.handle
        guard let sc = app.screensTopLeft.first(where: { $0.insetBy(dx: -w, dy: -h).contains(feet) }) ?? app.screensTopLeft.first else { return feet }
        let x = min(max(feet.x, sc.minX + w / 2 + m), sc.maxX - w / 2 - m)
        let y = min(max(feet.y, sc.minY + h + m), sc.maxY)
        return CGPoint(x: x, y: y)
    }

    func end() {
        guard drag != nil else { return }
        drag = nil
        panel?.label = nil
        app.busy = false
        app.settings.save()
        Debug.log("resize end at \(PixlScale.label(app.settings.scale))")
        app.puff(at: app.foot ?? .zero)
        app.backToIdle()
    }
}

/// The handles' window: just around the Pixl's box, clickable only on the four handles.
@MainActor
final class HandlesPanel: NSPanel {
    static let margin: CGFloat = 14
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

    /// Around `box` (top-left global coordinates), with room above for the size label.
    func fit(box: CGRect, primaryHeight: CGFloat) {
        let m = Self.margin, top: CGFloat = 26
        let r = NSRect(x: box.minX - m, y: primaryHeight - box.maxY - m, width: box.width + 2 * m, height: box.height + 2 * m + top)
        if frame != r { setFrame(r, display: true) }
        view.boxInset = NSEdgeInsets(top: m + top, left: m, bottom: m, right: m)
        view.needsDisplay = true
    }
}

@MainActor
final class HandlesView: NSView {
    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }
    unowned let controller: ResizeController
    var boxInset = NSEdgeInsets()
    var label: String?
    static let handle: CGFloat = 12

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
        Corner.allCases.first { hypot(point($0).x - p.x, point($0).y - p.y) <= Self.handle * 1.4 }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Accent.color
        let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        accent.withAlphaComponent(0.9).setStroke()
        outline.stroke()
        for c in Corner.allCases {
            let p = point(c), s = Self.handle
            let r = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
            Theme.ink.setFill(); NSRect(x: r.minX + 1, y: r.minY - 1, width: s, height: s).fill()   // hard shadow
            Theme.paper.setFill(); r.fill()
            accent.setStroke()
            let b = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); b.lineWidth = 2; b.stroke()
        }
        if let label {
            let font = Theme.mono(11, .bold)
            let size = (label as NSString).size(withAttributes: [.font: font])
            let pill = NSRect(x: box.midX - size.width / 2 - 8, y: box.maxY + 4, width: size.width + 16, height: 20)
            Theme.ink.setFill(); NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
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
    override func mouseUp(with event: NSEvent) { controller.end() }
}
