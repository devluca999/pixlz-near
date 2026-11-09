import AppKit

/// C8 option bubbles: 44 pt glass (or paper) bubbles on an arc over the Pixl's head. They puff
/// out of the head (45 ms stagger, 320 ms spring), close back into it in reverse (30 ms apart,
/// 170 ms), or all pop at once when a drag starts. Hover lifts and grows a bubble and shows its
/// label; press shrinks it. Keyboard: arrows/Tab move focus, Return/Space choose, Esc closes.
/// Driven by `advance(to:)` from the app's display-synced clock: no timers of its own.
@MainActor
public final class OptionBubblesView: NSView {
    public enum Phase: Equatable { case opening(TimeInterval), open, closing(TimeInterval), popping(TimeInterval), closed }

    public let slots: [BubbleMenuModel.Slot]
    public let look: SurfaceView.Look
    public let labelLook: SurfaceView.Look
    public var onSelect: ((BubbleMenuModel.Slot) -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) var phase: Phase = .closed
    public private(set) var focusIndex: Int?
    public var accent: NSColor = Theme.accent { didSet { buttons.forEach { $0.surface.accent = accent } } }

    /// Where bubbles emerge from (the head), and their resting centres, in view coordinates (flipped).
    public private(set) var head: CGPoint
    public private(set) var centers: [CGPoint]
    let buttons: [BubbleButton]
    private var rings: [PopRing] = []
    private var lastAdvance: TimeInterval?

    public init(frame: NSRect, slots: [BubbleMenuModel.Slot], head: CGPoint, centers: [CGPoint],
                look: SurfaceView.Look, labelLook: SurfaceView.Look) {
        self.slots = slots
        self.head = head
        self.centers = centers
        self.look = look
        self.labelLook = labelLook
        buttons = slots.map { BubbleButton(slot: $0, look: look, labelLook: labelLook) }
        super.init(frame: frame)
        for (i, b) in buttons.enumerated() {
            b.onPress = { [weak self] in self?.choose(i) }
            b.onHover = { [weak self] inside in if inside { self?.setFocus(nil) } }
            addSubview(b)
        }
        buttons.forEach { addSubview($0.label) }  // labels float above every bubble
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(PixlSkins.name)'s menu")
        layoutButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override var acceptsFirstResponder: Bool { true }

    // Only the bubbles catch the mouse; the rest of the panel is click-through.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard phase == .open || isOpening else { return nil }
        let p = convert(point, from: superview)
        return buttons.first { $0.frame.contains(p) && $0.alphaValue > 0.5 }.map { $0 }
    }

    var isOpening: Bool { if case .opening = phase { true } else { false } }
    public var isAnimating: Bool {
        switch phase { case .opening, .closing, .popping: true; default: buttons.contains { $0.animating } || !rings.isEmpty }
    }

    /// Moves the arc (the Pixl moved while the menu is open).
    public func move(head: CGPoint, centers: [CGPoint]) {
        self.head = head
        self.centers = centers
        layoutButtons()
    }

    // MARK: phases

    public func open(at t: TimeInterval) {
        phase = .opening(t)
        advance(to: t)
    }

    public func close(at t: TimeInterval) {
        guard phase != .closed else { return }
        if case .closing = phase { return }
        phase = .closing(t)
        advance(to: t)
    }

    /// Drag start: all bubbles pop at once into a sparse dither ring.
    public func pop(at t: TimeInterval) {
        guard phase != .closed else { return }
        phase = .popping(t)
        for (b, c) in zip(buttons, centers) where b.alphaValue > 0.05 {
            let r = PopRing(center: c, born: t)
            rings.append(r)
            addSubview(r)
        }
        advance(to: t)
    }

    /// The Pixl's menu style ("silk", "wisp"): drawn behind the bubbles, from the head to each.
    public var style: String? { didSet { needsDisplay = true } }
    public var styleColor: NSColor = NSColor(srgbRed: 0.72, green: 0.75, blue: 0.80, alpha: 1)

    public override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        for b in buttons where b.alphaValue > 0.02 {
            let end = CGPoint(x: b.frame.midX, y: b.frame.minY + 3)
            switch style {
            case "silk":
                // a thread with a little sag, from the Pixl to the top of each bubble
                let p = NSBezierPath()
                p.move(to: head)
                let mid = CGPoint(x: (head.x + end.x) / 2, y: (head.y + end.y) / 2 + 7)
                p.curve(to: end, controlPoint1: mid, controlPoint2: mid)
                p.lineWidth = 1
                styleColor.withAlphaComponent(0.9 * b.alphaValue).setStroke()
                p.stroke()
                styleColor.withAlphaComponent(b.alphaValue).setFill()
                NSRect(x: end.x - 1, y: end.y - 2, width: 2, height: 2).fill()
            case "wisp":
                // a dithered trail of 2 px dots, thinning out toward the bubble
                let d = hypot(end.x - head.x, end.y - head.y), n = max(Int(d / 5), 1)
                for k in 1..<n where k % 2 == 1 || k < n / 3 {
                    let f = CGFloat(k) / CGFloat(n)
                    styleColor.withAlphaComponent((0.75 - 0.45 * f) * b.alphaValue).setFill()
                    let x = head.x + (end.x - head.x) * f, y = head.y + (end.y - head.y) * f + sin(f * .pi) * 6
                    NSRect(x: x.rounded() - 1, y: y.rounded() - 1, width: 2, height: 2).fill()
                }
            default: break
            }
        }
    }

    /// Steps every animation to time `t`; returns true while anything is still moving.
    @discardableResult
    public func advance(to t: TimeInterval) -> Bool {
        let dt = min(max(t - (lastAdvance ?? t), 0), 0.05)
        lastAdvance = t
        let n = buttons.count
        for (i, b) in buttons.enumerated() {
            var f: BubbleMenuModel.Frame?
            switch phase {
            case .opening(let t0): f = BubbleMenuModel.open(t - t0 - BubbleMenuModel.openDelay(i)) ?? BubbleMenuModel.Frame(q: 0, s: 0.2, op: 0)
            case .open: f = .rest
            case .closing(let t0): f = BubbleMenuModel.close(t - t0 - BubbleMenuModel.closeDelay(i, of: n))
            case .popping(let t0): f = BubbleMenuModel.pop(t - t0)
            case .closed: f = nil
            }
            b.step(dt: dt)
            place(b, i, f)
        }
        rings.removeAll { r in
            let alive = r.step(t)
            if !alive { r.removeFromSuperview() }
            return !alive
        }
        if style != nil { needsDisplay = true }
        switch phase {
        case .opening(let t0) where t - t0 >= BubbleMenuModel.openDuration(count: n): phase = .open
        case .closing(let t0) where t - t0 >= BubbleMenuModel.closeDuration(count: n): phase = .closed
        case .popping(let t0) where t - t0 >= BubbleMenuModel.popTime: phase = .closed
        default: break
        }
        return isAnimating
    }

    func place(_ b: BubbleButton, _ i: Int, _ f: BubbleMenuModel.Frame?) {
        guard let f else { b.alphaValue = 0; b.label.alphaValue = 0; return }
        let c = CGPoint(x: head.x + (centers[i].x - head.x) * f.q, y: head.y + (centers[i].y - head.y) * f.q)
        let state = BubbleMenuModel.hoverPress(hover: b.hover, press: b.press, paper: !look.glass)
        let size = BubbleMenuModel.bubbleSize * f.s * state.scale
        let y = c.y + state.lift
        b.frame = NSRect(x: (c.x - size / 2).rounded(), y: (y - size / 2).rounded(), width: size.rounded(), height: (size + b.surface.shadowInset).rounded())
        b.alphaValue = f.op
        // label above the bubble, shown on hover or keyboard focus once the bubble has settled
        let show = (b.hover > 0 || b.focused) && phase == .open
        b.labelShown = BubbleMenuModel.approach(b.labelShown, to: show ? 1 : 0, dt: 1 / 60)
        let lw = b.label.frame.width, lh = b.label.frame.height
        b.label.frame.origin = NSPoint(x: (c.x - lw / 2).rounded(), y: (y - BubbleMenuModel.bubbleSize / 2 - 9 - lh).rounded())
        b.label.alphaValue = b.labelShown * f.op
    }

    func layoutButtons() { advance(to: lastAdvance ?? 0) }

    // MARK: choosing and keyboard

    func choose(_ i: Int) {
        guard slots.indices.contains(i), phase == .open || isOpening else { return }
        Debug.log("bubble chosen \(slots[i].id)")
        onSelect?(slots[i])
    }

    public func setFocus(_ i: Int?) {
        focusIndex = i
        for (j, b) in buttons.enumerated() { b.focused = (j == i) }
    }

    public override func keyDown(with event: NSEvent) {
        guard phase == .open || isOpening else { return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "k",
           let i = slots.firstIndex(where: { $0.id == "ask" }) { choose(i); return }
        let n = buttons.count
        switch event.keyCode {
        case 123, 126: setFocus(((focusIndex ?? 0) - 1 + n) % n)          // ← ↑
        case 124, 125, 48: setFocus(((focusIndex ?? -1) + 1) % n)         // → ↓ Tab
        case 36, 76, 49: if let i = focusIndex { choose(i) } else { setFocus(0) }  // Return, Enter, Space
        case 53: onCancel?()                                              // Esc
        default: super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) { onCancel?() }

    public override func accessibilityChildren() -> [Any]? { buttons }
}

/// One option bubble: a circular surface with a pixel icon, and its label pill.
@MainActor
final class BubbleButton: NSView {
    let slot: BubbleMenuModel.Slot
    let surface: SurfaceView
    let icon: NSImageView
    let label: SurfaceView
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private(set) var hover: CGFloat = 0
    private(set) var press: CGFloat = 0
    var labelShown: CGFloat = 0
    private var hovering = false
    private var down = false
    var focused = false { didSet { surface.focused = focused } }
    var animating: Bool {
        abs(hover - (hovering || focused ? 1 : 0)) > 0.001 || abs(press - (down ? 1 : 0)) > 0.001
    }

    init(slot: BubbleMenuModel.Slot, look: SurfaceView.Look, labelLook: SurfaceView.Look) {
        self.slot = slot
        let s = BubbleMenuModel.bubbleSize
        surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: s, height: s + (look.glass ? 0 : 3)), shape: .circle, look: look)
        icon = NSImageView(image: BubbleIcons.image(slot.id, dark: look.variant == .dark)
                           ?? BubbleIcons.image("more", dark: look.variant == .dark) ?? NSImage())
        icon.imageScaling = .scaleNone
        // label pill: "Wallet  4.20 NEAR"
        let text = NSMutableAttributedString(string: slot.label, attributes: [.font: Theme.mono(11, .bold), .foregroundColor: labelLook.textColor])
        if let sub = slot.sub {
            text.append(NSAttributedString(string: "  \(sub)", attributes: [.font: Theme.mono(10), .foregroundColor: labelLook.mutedColor]))
        }
        let size = text.size()
        label = SurfaceView(frame: NSRect(x: 0, y: 0, width: ceil(size.width) + 18, height: BubbleMenuModel.labelHeight + (labelLook.glass ? 0 : 3)),
                            shape: .rounded(8), look: labelLook)
        let t = NSTextField(labelWithAttributedString: text)
        t.maximumNumberOfLines = 1
        t.lineBreakMode = .byClipping
        t.cell?.wraps = false  // one line: a wrapped "selection" would fall below the pill
        let lineH = ceil(Theme.mono(11, .bold).boundingRectForFont.height)
        t.frame = NSRect(x: 7, y: ((BubbleMenuModel.labelHeight - lineH) / 2).rounded(), width: ceil(size.width) + 6, height: lineH)
        label.content.addSubview(t)
        label.alphaValue = 0
        super.init(frame: surface.frame)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        surface.content.addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(slot.accessibilityLabel)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let s = min(bounds.width, bounds.height - surface.shadowInset)
        let iconSize = 24 * s / BubbleMenuModel.bubbleSize
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = NSRect(x: (s - iconSize) / 2, y: (s - iconSize) / 2, width: iconSize, height: iconSize)
    }

    override var frame: NSRect { didSet { needsLayout = true } }

    func step(dt: TimeInterval) {
        hover = BubbleMenuModel.approach(hover, to: hovering || focused ? 1 : 0, dt: dt)
        press = BubbleMenuModel.approach(press, to: down ? 1 : 0, dt: dt * 1.5)
        surface.lit = hover > 0.5
        surface.pressed = press > 0.5
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; down = false; onHover?(false) }

    // Handles mouseDown itself, so the mouseUp always comes back here (the earlier radial bug).
    override func mouseDown(with event: NSEvent) {
        down = true
        Debug.log("bubble down \(slot.id)")
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        down = false
        Debug.log("bubble up \(slot.id) inside=\(inside)")
        if inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// The sparse pixel dither ring a bubble leaves when it pops (C8 drag start).
@MainActor
final class PopRing: NSView {
    let born: TimeInterval
    let center: CGPoint
    private var progress: CGFloat = 0

    init(center: CGPoint, born: TimeInterval) {
        self.center = center
        self.born = born
        super.init(frame: NSRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func step(_ t: TimeInterval) -> Bool {
        progress = CGFloat((t - born) / BubbleMenuModel.ringTime)
        needsDisplay = true
        return progress < 1
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = min(max(progress, 0), 1)
        let r = 13 * 2 * (0.7 + 0.6 * p)  // design pxRing(13) at 2 pt per pixel, scale .7 → 1.3
        Theme.ink.withAlphaComponent(1 - p).setFill()
        let px: CGFloat = 2
        var y = -r
        while y <= r {
            var x = -r
            while x <= r {
                let d = hypot(x + px / 2, y + px / 2)
                if abs(d - r) < px * 0.7, (Int((x + r) / px) + Int((y + r) / px)) % 2 == 0 {
                    NSRect(x: 40 + x, y: 40 + y, width: px, height: px).fill()
                }
                x += px
            }
            y += px
        }
    }
}
