import AppKit

/// Round pixel button, shared by the radial menu and the round choice picker.
@MainActor
enum RoundButton {
    static func draw(in r: NSRect, glyph: String?, title: String?, enabled: Bool, lit: Bool, pressed: Bool) {
        let shadow: CGFloat = pressed ? 1 : 4
        let body = pressed ? r.offsetBy(dx: 2, dy: 2) : r
        Theme.ink.setFill()
        NSBezierPath(ovalIn: r.offsetBy(dx: shadow, dy: shadow)).fill()
        (enabled ? (lit ? Theme.accent : NSColor.white) : NSColor(white: 0.88, alpha: 1)).setFill()
        NSBezierPath(ovalIn: body).fill()
        Theme.ink.setStroke()
        let ring = NSBezierPath(ovalIn: body.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = Theme.border
        ring.stroke()
        let color = enabled ? Theme.ink : Theme.muted
        if let glyph {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: color]
            let s = (glyph as NSString).size(withAttributes: a)
            (glyph as NSString).draw(at: NSPoint(x: body.midX - s.width / 2, y: body.midY - s.height / 2), withAttributes: a)
        } else if let title {
            let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(14, .bold), .foregroundColor: color]
            let s = (title as NSString).size(withAttributes: a)
            (title as NSString).draw(at: NSPoint(x: body.midX - s.width / 2, y: body.midY - s.height / 2), withAttributes: a)
        }
    }

    static func label(_ text: String, centeredAt x: CGFloat, top y: CGFloat, enabled: Bool) {
        let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(11, .bold), .foregroundColor: enabled ? Theme.ink : Theme.muted,
                                                .backgroundColor: Theme.paper]
        let s = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: x - s.width / 2, y: y), withAttributes: a)
    }
}

/// A small overlay picker that replaces NSMenu pop-ups (unreliable from a non-activating
/// panel in a menu-bar-only app). `.round`: a row of round buttons like the radial menu.
/// `.list`: a paper card with one button per option.
@MainActor
public final class ChoiceMenuView: NSView {
    public enum Style { case round, list }

    let title: String?
    let options: [String]
    let style: Style
    let onSelect: (Int) -> Void
    private var pressed: Int?

    static let diameter: CGFloat = 66
    static let gap: CGFloat = 18
    static let listWidth: CGFloat = 280
    static let rowHeight: CGFloat = 34

    public init(title: String?, options: [String], style: Style, onSelect: @escaping (Int) -> Void) {
        self.title = title
        self.options = options
        self.style = style
        self.onSelect = onSelect
        let size: NSSize
        switch style {
        case .round:
            size = NSSize(width: CGFloat(options.count) * (Self.diameter + Self.gap) + Self.gap,
                          height: Self.diameter + (title == nil ? 20 : 44))
        case .list:
            size = NSSize(width: Self.listWidth + Theme.shadowOffset,
                          height: (title == nil ? 14 : 40) + CGFloat(options.count) * (Self.rowHeight + 8) + 14 + Theme.shadowOffset)
        }
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = NSAppearance(named: .aqua)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    private var top: CGFloat { title == nil ? (style == .round ? 6 : 14) : (style == .round ? 30 : 40) }

    func rect(of i: Int) -> NSRect {
        switch style {
        case .round:
            return NSRect(x: Self.gap + CGFloat(i) * (Self.diameter + Self.gap), y: top, width: Self.diameter, height: Self.diameter)
        case .list:
            return NSRect(x: 14, y: top + CGFloat(i) * (Self.rowHeight + 8), width: Self.listWidth - 28, height: Self.rowHeight)
        }
    }

    /// Centre of option `i`, in this view's (flipped) coordinates.
    public func center(of i: Int) -> NSPoint? {
        guard options.indices.contains(i) else { return nil }
        let r = rect(of: i)
        return NSPoint(x: r.midX, y: r.midY)
    }

    func index(at p: NSPoint) -> Int? {
        options.indices.first { i in
            let r = rect(of: i)
            return style == .round ? hypot(p.x - r.midX, p.y - r.midY) <= r.width / 2 + 2 : r.contains(p)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        if style == .list {
            let card = NSRect(x: 0, y: 0, width: bounds.width - Theme.shadowOffset, height: bounds.height - Theme.shadowOffset)
            Theme.ink.setFill(); NSBezierPath(rect: card.offsetBy(dx: Theme.shadowOffset, dy: Theme.shadowOffset)).fill()
            Theme.paper.setFill(); NSBezierPath(rect: card).fill()
            Theme.ink.setStroke()
            let p = NSBezierPath(rect: card.insetBy(dx: 1.5, dy: 1.5)); p.lineWidth = Theme.border; p.stroke()
        }
        if let title {
            let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(12, .bold), .foregroundColor: style == .list ? Theme.muted : Theme.ink,
                                                    .backgroundColor: style == .list ? NSColor.clear : Theme.paper]
            let s = (title as NSString).size(withAttributes: a)
            let x = style == .round ? bounds.midX - s.width / 2 : 14
            (title as NSString).draw(at: NSPoint(x: x, y: style == .round ? 4 : 14), withAttributes: a)
        }
        for (i, option) in options.enumerated() {
            let r = rect(of: i)
            switch style {
            case .round:
                RoundButton.draw(in: r, glyph: nil, title: option, enabled: true, lit: pressed == i, pressed: pressed == i)
            case .list:
                let down = pressed == i
                Theme.ink.setFill(); NSBezierPath(rect: r.offsetBy(dx: 3, dy: 3)).fill()
                (i == 0 ? Theme.accent : NSColor.white).setFill()
                let body = down ? r.offsetBy(dx: 2, dy: 2) : r
                NSBezierPath(rect: body).fill()
                Theme.ink.setStroke()
                let p = NSBezierPath(rect: body.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
                let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(12, .bold), .foregroundColor: Theme.ink]
                let s = (option as NSString).size(withAttributes: a)
                (option as NSString).draw(at: NSPoint(x: body.minX + 12, y: body.midY - s.height / 2), withAttributes: a)
            }
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if style == .list { return bounds.contains(p) ? self : nil }
        return index(at: p) != nil ? self : nil  // round: only the buttons catch clicks
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
        Debug.log("choice down \(title ?? "") index=\(pressed.map(String.init) ?? "none")")
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        let was = pressed
        pressed = nil
        needsDisplay = true
        guard let i, i == was else { return }
        Debug.log("choice select \(title ?? "") \(options[i])")
        onSelect(i)
    }
}
