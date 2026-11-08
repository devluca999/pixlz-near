import AppKit

/// Draws one Frogg frame bottom-centred at an integer scale. Transparent pixels are
/// left untouched, so the window server passes clicks there through to the app
/// below (SPEC R2: only the Pixl's opaque pixels catch the mouse).
@MainActor
public final class FroggView: NSView {
    public var frameName: String { didSet { if frameName != oldValue { needsDisplay = true } } }
    public var squash = CGSize(width: 1, height: 1) { didSet { if squash != oldValue { needsDisplay = true } } }
    public var mirrored = false { didSet { if mirrored != oldValue { needsDisplay = true } } }
    public var lean: CGFloat = 0 { didSet { if lean != oldValue { needsDisplay = true } } }
    public let scale: CGFloat
    /// Room around the canvas so a stretch or squash never clips (transparent, click-through).
    public static let headroom: CGFloat = 1.3
    public enum MouseEvent { case down, dragged, up, right }
    public var onMouse: ((MouseEvent, NSEvent) -> Void)?
    private let art = FroggArt.shared

    public init(scale: CGFloat = 2, frameName: String = "idle_0") {
        self.scale = scale
        self.frameName = frameName
        let c = FroggArt.shared.canvas
        super.init(frame: NSRect(x: 0, y: 0, width: (c.width * scale * Self.headroom).rounded(),
                                 height: (c.height * scale * Self.headroom).rounded()))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        art.draw(frameName, in: bounds, scale: scale, context: ctx, squash: squash, mirrored: mirrored, lean: lean)
    }

    /// The art pixel under a point in view coordinates is opaque.
    public func hitsArt(at p: NSPoint) -> Bool {
        let s = art.size(frameName)
        let x0 = (bounds.midX - s.width * scale / 2).rounded(.down)
        let ax = Int(((p.x - x0) / scale).rounded(.down))
        let ay = Int(((s.height * scale - p.y) / scale).rounded(.down))  // art rows count from the top
        return art.isOpaque(frameName, x: ax, y: ay)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hit = hitsArt(at: local)
        if Debug.enabled, let e = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(e.type) {
            Debug.log("frogg hitTest \(e.type == .leftMouseDown ? "down" : "right") at (\(Int(local.x)),\(Int(local.y))) frame=\(frameName) \(hit ? "HIT opaque pixel" : "MISS transparent")")
        }
        return hit ? self : nil
    }

    /// Where a hanging frame's pin (the toe pad held by the cursor) is, in view coordinates.
    public func pinPoint(_ name: String) -> NSPoint? {
        guard let f = art.frames[name], let pin = f.pin, pin.count == 2 else { return nil }
        let x0 = (bounds.midX - CGFloat(f.w) * scale / 2).rounded(.down)
        return NSPoint(x: x0 + (CGFloat(pin[0]) + 0.5) * scale, y: (CGFloat(f.h - pin[1]) - 0.5) * scale)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) {
        Debug.log("frogg down clickCount=\(event.clickCount)")
        onMouse?(.down, event)
    }
    public override func mouseDragged(with event: NSEvent) { onMouse?(.dragged, event) }
    public override func mouseUp(with event: NSEvent) {
        Debug.log("frogg up clickCount=\(event.clickCount)")
        onMouse?(.up, event)
    }
    public override func rightMouseDown(with event: NSEvent) {
        Debug.log("frogg right clickCount=\(event.clickCount)")
        onMouse?(.right, event)
    }
}

/// The speech bubble (SPEC §11.6): white box, 3 pt ink outline, tail toward the Pixl,
/// bold monospace text.
@MainActor
public final class BubbleView: NSView {
    public var text: String { didSet { needsDisplay = true } }
    static let font = Theme.mono(12, .bold)
    static let pad: CGFloat = 10
    static let tail: CGFloat = 10

    public init(text: String) {
        self.text = text
        super.init(frame: NSRect(origin: .zero, size: Self.size(for: text)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public static func size(for text: String, maxWidth: CGFloat = 300) -> NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: 400),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return NSSize(width: ceil(r.width) + pad * 2 + Theme.border * 2, height: ceil(r.height) + pad * 2 + tail + Theme.border * 2)
    }

    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: Theme.border / 2, y: Self.tail + Theme.border / 2,
                         width: bounds.width - Theme.border, height: bounds.height - Self.tail - Theme.border)
        let path = NSBezierPath(rect: box)
        // tail toward the Pixl, below the box
        let tx = bounds.midX
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tx - 8, y: box.minY))
        tail.line(to: NSPoint(x: tx, y: Theme.border / 2))
        tail.line(to: NSPoint(x: tx + 8, y: box.minY))
        NSColor.white.setFill()
        path.fill(); tail.fill()
        Theme.ink.setStroke()
        path.lineWidth = Theme.border; path.stroke()
        tail.lineWidth = Theme.border; tail.stroke()
        NSColor.white.setFill()
        NSRect(x: tx - 6.5, y: box.minY - 1, width: 13, height: Theme.border + 2).fill()  // open the box where the tail joins
        let textRect = box.insetBy(dx: Self.pad + Theme.border / 2, dy: Self.pad + Theme.border / 2)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin],
                                attributes: [.font: Self.font, .foregroundColor: Theme.ink])
    }
}
