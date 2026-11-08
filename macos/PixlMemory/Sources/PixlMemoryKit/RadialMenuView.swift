import AppKit

/// The radial menu (SPEC §11.2): round pixel buttons around Frogg, clockwise from the top.
/// Near the bottom or top of the screen it becomes a half-ring above or below him, so no
/// button ends up off screen. The middle is transparent: Frogg stays clickable underneath.
@MainActor
public final class RadialMenuView: NSView {
    public struct Item: Sendable, Equatable {
        public let id: String
        public let title: String
        public let glyph: String
        public let enabled: Bool
        public init(id: String, title: String, glyph: String, enabled: Bool = true) {
            self.id = id; self.title = title; self.glyph = glyph; self.enabled = enabled
        }
    }

    /// `ring`: all the way round. `above` / `below`: a half-ring over or under Frogg.
    public enum Layout: Sendable, Equatable { case ring, above, below }

    public let items: [Item]
    public let layout: Layout
    public var onSelect: ((Item) -> Void)?
    static let labelHeight: CGFloat = 22
    public static let radius: CGFloat = 104
    public static let button: CGFloat = 54
    public static let size = NSSize(width: 2 * radius + button + 70, height: 2 * radius + button + 40)
    private var hovered: Int?
    private var pressed: Int?

    public init(items: [Item], layout: Layout = .ring) {
        self.items = items
        self.layout = layout
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    /// Button centres in a flipped (y-down) view: clockwise from 12 o'clock for a ring;
    /// left to right over the top (`above`) or under the bottom (`below`) for a half-ring.
    public static func centers(count: Int, in size: NSSize, layout: Layout = .ring) -> [NSPoint] {
        let c = NSPoint(x: size.width / 2, y: size.height / 2)
        let n = max(count, 1)
        return (0..<count).map { i in
            let a: CGFloat
            switch layout {
            case .ring: a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(n)
            case .above: a = -CGFloat.pi - 0.2 + (CGFloat.pi + 0.4) * CGFloat(i) / CGFloat(max(n - 1, 1))
            case .below: a = CGFloat.pi + 0.2 - (CGFloat.pi + 0.4) * CGFloat(i) / CGFloat(max(n - 1, 1))
            }
            return NSPoint(x: (c.x + radius * cos(a)).rounded(), y: (c.y + radius * sin(a)).rounded())
        }
    }

    public var centers: [NSPoint] { Self.centers(count: items.count, in: bounds.size, layout: layout) }

    /// The part of the view with buttons and labels in it (flipped coordinates), for keeping
    /// the menu on screen.
    public var contentRect: NSRect {
        centers.reduce(NSRect.null) { r, c in
            let button = NSRect(x: c.x - Self.button / 2, y: c.y - Self.button / 2, width: Self.button + 4, height: Self.button + 4)
            let label = NSRect(x: c.x - 48, y: c.y + Self.button / 2, width: 96, height: Self.labelHeight)
            return r.union(button).union(label)
        }
    }

    public func index(at p: NSPoint) -> Int? {
        centers.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= Self.button / 2 + 2 }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        index(at: convert(point, from: superview)) != nil ? self : nil  // the rest is click-through
    }

    public override func draw(_ dirtyRect: NSRect) {
        for (i, (item, c)) in zip(items, centers).enumerated() {
            let r = NSRect(x: c.x - Self.button / 2, y: c.y - Self.button / 2, width: Self.button, height: Self.button)
            RoundButton.draw(in: r, glyph: item.glyph, title: nil, enabled: item.enabled,
                             lit: hovered == i || pressed == i, pressed: pressed == i)
            RoundButton.label(item.enabled ? item.title : "\(item.title) · soon", centeredAt: c.x, top: r.maxY + 6, enabled: item.enabled)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }

    public override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Handle mouseDown ourselves: if it falls through to the borderless panel, AppKit can
    // treat it as the start of a window drag and the mouseUp never reaches us.
    public override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
        Debug.log("radial down index=\(pressed.map { items[$0].id } ?? "none")")
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        let was = pressed
        pressed = nil
        needsDisplay = true
        Debug.log("radial up index=\(i.map { items[$0].id } ?? "none") pressed=\(was.map { items[$0].id } ?? "none")")
        guard let i, i == was else { return }  // release on the button you pressed
        onSelect?(items[i])
    }
}
