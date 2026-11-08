import AppKit

/// Design tokens from design/tokens/colors.css and SPEC §11.5–11.6.
public enum Theme {
    public static let ink = NSColor(srgbRed: 0x1B / 255, green: 0x2A / 255, blue: 0x1A / 255, alpha: 1)
    public static let paper = NSColor(srgbRed: 0xFF / 255, green: 0xFB / 255, blue: 0xF2 / 255, alpha: 1)
    public static let accent = NSColor(srgbRed: 0x7C / 255, green: 0xD9 / 255, blue: 0x3A / 255, alpha: 1)
    public static let muted = NSColor(srgbRed: 0x5D / 255, green: 0x6B / 255, blue: 0x5C / 255, alpha: 1)
    public static let verified = NSColor(srgbRed: 0x2B / 255, green: 0x8A / 255, blue: 0x3E / 255, alpha: 1)
    public static let partial = NSColor(srgbRed: 0xE6 / 255, green: 0x77 / 255, blue: 0x00 / 255, alpha: 1)
    public static let failed = NSColor(srgbRed: 0xC9 / 255, green: 0x2A / 255, blue: 0x2A / 255, alpha: 1)
    public static let insertBG = NSColor(srgbRed: 0xD3 / 255, green: 0xF9 / 255, blue: 0xD8 / 255, alpha: 1)
    public static let deleteBG = NSColor(srgbRed: 0xFF / 255, green: 0xE3 / 255, blue: 0xE3 / 255, alpha: 1)

    public static let border: CGFloat = 3
    public static let shadowOffset: CGFloat = 6

    public static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Paper card with a 3 pt ink border and a hard offset shadow (SPEC §11.5).
    public static func drawCard(_ rect: NSRect, fill: NSColor = paper, shadow: CGFloat = shadowOffset) {
        let body = rect.insetBy(dx: border / 2, dy: border / 2)
        let shadowRect = body.offsetBy(dx: shadow, dy: -shadow)
        if shadow > 0 {
            ink.setFill()
            NSBezierPath(rect: shadowRect).fill()
        }
        fill.setFill()
        NSBezierPath(rect: body).fill()
        ink.setStroke()
        let p = NSBezierPath(rect: body)
        p.lineWidth = border
        p.stroke()
    }
}
