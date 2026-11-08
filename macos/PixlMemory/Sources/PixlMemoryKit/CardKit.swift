import AppKit

// The pieces every Pixl card is built from, after the C10 "Menus & Bubbles" design:
// one material (Solid for every Pixl, Liquid Glass for the ghost), text on plates, a header
// with a grip, a pixel icon, the title and a plain ×, chip buttons and chip fields.

/// Colours of one material, straight from C10's MAT table (ui-kit.js).
public struct MaterialTokens: @unchecked Sendable {  // immutable colours
    public let fill, outline, halo, shadow, highlight, lowlight: NSColor
    public let text, text2, chip, line, border: NSColor
    /// Glass only: the plate text sits on (80 % paper / 78 % ink), so it reads over anything.
    public let plate: NSColor?
    /// Solid only: the 2 px ordered-dither grain.
    public let grain: NSColor?

    static func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    public static let solidLight = MaterialTokens(
        fill: c(255, 251, 242, 0.94), outline: c(27, 42, 26), halo: c(255, 251, 242, 0.9), shadow: c(27, 42, 26),
        highlight: c(255, 255, 255, 0.9), lowlight: c(27, 42, 26, 0.08), text: c(27, 42, 26), text2: c(74, 84, 71),
        chip: c(27, 42, 26, 0.07), line: c(27, 42, 26, 0.2), border: c(27, 42, 26), plate: nil, grain: c(27, 42, 26, 0.07))
    public static let solidDark = MaterialTokens(
        fill: c(22, 24, 31, 0.94), outline: c(242, 238, 226), halo: c(8, 9, 12, 0.9), shadow: c(0, 0, 0),
        highlight: c(255, 255, 255, 0.12), lowlight: c(0, 0, 0, 0.35), text: c(255, 251, 242), text2: c(190, 195, 206),
        chip: c(255, 251, 242, 0.08), line: c(255, 251, 242, 0.2), border: c(0, 0, 0), plate: nil, grain: c(255, 251, 242, 0.05))
    public static let glassLight = MaterialTokens(
        fill: c(255, 255, 255, 0.2), outline: c(255, 255, 255, 0.9), halo: c(20, 24, 40, 0.45), shadow: .clear,
        highlight: c(255, 255, 255, 0.9), lowlight: .clear, text: c(27, 42, 26), text2: c(60, 68, 58),
        chip: c(27, 42, 26, 0.08), line: c(27, 42, 26, 0.2), border: c(27, 42, 26), plate: c(255, 253, 248, 0.8), grain: nil)
    public static let glassDark = MaterialTokens(
        fill: c(30, 34, 48, 0.32), outline: c(255, 255, 255, 0.5), halo: c(0, 0, 0, 0.45), shadow: .clear,
        highlight: c(255, 255, 255, 0.45), lowlight: .clear, text: c(255, 251, 242), text2: c(200, 205, 215),
        chip: c(255, 251, 242, 0.08), line: c(255, 251, 242, 0.2), border: c(0, 0, 0), plate: c(18, 20, 28, 0.78), grain: nil)

    /// For views that only know their appearance (buttons, fields).
    public static func forAppearance(_ a: NSAppearance, glass: Bool = false) -> MaterialTokens {
        let dark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return glass ? (dark ? .glassDark : .glassLight) : (dark ? .solidDark : .solidLight)
    }
}

extension SurfaceView.Look {
    public var tokens: MaterialTokens {
        glass ? (variant == .dark ? .glassDark : .glassLight) : (variant == .dark ? .solidDark : .solidLight)
    }
}

/// The Pixl's accent, and the text colour that reads on it (ink or paper, whichever is ≥ 4.5:1).
@MainActor
public enum Accent {
    public static var color: NSColor { let c = RGB(hex: PixlData.ui.accent); return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
    public static var onAccent: NSColor {
        let a = RGB(hex: PixlData.ui.accent)
        return Contrast.ratio(a, Legibility.ink) >= Contrast.ratio(a, Legibility.paper) ? MaterialTokens.solidLight.text : MaterialTokens.c(255, 251, 242)
    }
}

/// A rounded plate under a run of text. On glass it's the 80 % paper that makes text legible
/// over any backdrop; on the solid material it's transparent (the fill already is ≥ 94 %).
@MainActor
final class PlateView: NSView {
    let look: SurfaceView.Look
    init(look: SurfaceView.Look) { self.look = look; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let plate = look.tokens.plate else { return }
        plate.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    /// Wraps `content` in a plate with padding.
    static func wrap(_ content: NSView, look: SurfaceView.Look, padding: NSEdgeInsets) -> PlateView {
        let p = PlateView(look: look)
        content.translatesAutoresizingMaskIntoConstraints = false
        p.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: p.leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: p.trailingAnchor, constant: -padding.right),
            content.topAnchor.constraint(equalTo: p.topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: p.bottomAnchor, constant: -padding.bottom),
        ])
        return p
    }
}

/// Six dots: "you can drag this" (C10 `.grip`).
@MainActor
final class GripView: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: NSRect(x: 0, y: 0, width: 6, height: 12)) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 12) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        for y in stride(from: 0, to: 12, by: 4) { for x in [0, 4] { NSRect(x: x, y: y + 1, width: 2, height: 2).fill() } }
    }
}

/// A text field on a chip: rounded, a 2 pt line that turns into the Pixl's accent while you
/// type (no system blue ring), an optional pixel icon, placeholder in the muted text colour.
@MainActor
public final class PixlField: NSView, NSTextFieldDelegate {
    public let field = FieldText()
    public var onReturn: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var onChange: ((String) -> Void)?
    let look: SurfaceView.Look
    var focused = false { didSet { needsDisplay = true } }

    public final class FieldText: NSTextField {
        var onFocus: ((Bool) -> Void)?
        public override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { onFocus?(true) }
            return ok
        }
        public override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocus?(false)
        }
    }

    public init(placeholder: String, icon: String?, look: SurfaceView.Look, label: String) {
        self.look = look
        super.init(frame: .zero)
        let t = look.tokens
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = t.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: t.text2, .font: NSFont.systemFont(ofSize: 14)])
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(label)
        field.onFocus = { [weak self] f in self?.focused = f }
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        var leading: CGFloat = 12
        if let icon, let img = BubbleIcons.image(icon, dark: look.variant == .dark, scale: 1.5) {
            let iv = NSImageView(image: img)
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([iv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), iv.centerYAnchor.constraint(equalTo: centerYAnchor)])
            leading = 34
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }
    public var stringValue: String { get { field.stringValue } set { field.stringValue = newValue } }

    public override func draw(_ dirtyRect: NSRect) {
        let t = look.tokens
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        (look.glass ? (t.plate ?? t.chip) : t.chip).setFill()
        p.fill()
        p.lineWidth = 2
        (focused ? Accent.color : t.line).setStroke()
        p.stroke()
    }

    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    public func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onReturn?(); return onReturn != nil }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return onEscape != nil }
        return false
    }
}

/// A small mono caption ("FROM YOUR HIGHLIGHTS"), in the muted text colour.
@MainActor
func caption(_ s: String, look: SurfaceView.Look) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = Theme.mono(9, .bold)
    f.textColor = look.tokens.text2
    return f
}
