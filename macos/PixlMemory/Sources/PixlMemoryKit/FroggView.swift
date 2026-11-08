import AppKit

/// Draws one Frogg frame bottom-centred at an integer scale. Transparent pixels are
/// left untouched, so the window server passes clicks there through to the app
/// below (SPEC R2: only the Pixl's opaque pixels catch the mouse).
@MainActor
public final class FroggView: NSView {
    public var frameName: String { didSet { if frameName != oldValue { needsDisplay = true } } }
    public let scale: CGFloat
    public var onClick: ((NSEvent) -> Void)?
    private let art = FroggArt.shared

    public init(scale: CGFloat = 2, frameName: String = "idle_0") {
        self.scale = scale
        self.frameName = frameName
        let c = FroggArt.shared.canvas
        super.init(frame: NSRect(x: 0, y: 0, width: c.width * scale, height: c.height * scale))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        art.draw(frameName, in: bounds, scale: scale, context: ctx)
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
        return hitsArt(at: local) ? self : nil
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) { onClick?(event) }
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
