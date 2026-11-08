import AppKit

/// The radial menu (SPEC §11.2): round pixel buttons around Frogg, clockwise from the top.
/// The middle is transparent, so Frogg stays visible and clickable underneath.
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

    public let items: [Item]
    public var onSelect: ((Item) -> Void)?
    public static let radius: CGFloat = 104
    public static let button: CGFloat = 54
    public static let size = NSSize(width: 2 * radius + button + 70, height: 2 * radius + button + 40)
    private var hovered: Int?
    private var pressed: Int?

    public init(items: [Item]) {
        self.items = items
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    /// Button centres, clockwise from 12 o'clock, in a flipped (y-down) view.
    public static func centers(count: Int, in size: NSSize) -> [NSPoint] {
        let c = NSPoint(x: size.width / 2, y: size.height / 2)
        return (0..<count).map { i in
            let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(max(count, 1))
            return NSPoint(x: (c.x + radius * cos(a)).rounded(), y: (c.y + radius * sin(a)).rounded())
        }
    }

    public func index(at p: NSPoint) -> Int? {
        Self.centers(count: items.count, in: bounds.size).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= Self.button / 2 + 2 }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        index(at: convert(point, from: superview)) != nil ? self : nil  // the rest is click-through
    }

    public override func draw(_ dirtyRect: NSRect) {
        let centers = Self.centers(count: items.count, in: bounds.size)
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
