import Foundation

/// WCAG 2.x contrast for text on the translucent surfaces (C8 glass). sRGB components in 0…1.
public struct RGB: Equatable, Sendable {
    public var r, g, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public init(hex: String) {
        let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
    public static let white = RGB(1, 1, 1)
    public static let black = RGB(0, 0, 0)
}

public enum Contrast {
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func encode(_ l: Double) -> Double { l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055 }

    public static func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `fill` at `alpha` over `backdrop`, blended in sRGB the way AppKit composites.
    public static func over(_ fill: RGB, alpha a: Double, backdrop: RGB) -> RGB {
        RGB(fill.r * a + backdrop.r * (1 - a), fill.g * a + backdrop.g * (1 - a), fill.b * a + backdrop.b * (1 - a))
    }

    /// The grey whose relative luminance is `l`.
    public static func grey(luminance l: Double) -> RGB {
        let v = encode(min(max(l, 0), 1))
        return RGB(v, v, v)
    }
}

/// Picks the light or dark surface and the backdrop dim (fill opacity) so text stays at
/// 4.5:1 or better over every backdrop luminance in `backdrop`. With no way to see the
/// screen (no Screen Recording, SPEC D12), callers pass the full 0…1 range: the worst case.
public enum Legibility {
    public enum Variant: Sendable, Equatable { case light, dark }

    public static let minimum = 4.5
    public static let ink = RGB(hex: "#1B2A1A")
    public static let paper = RGB(hex: "#FFFBF2")
    /// C8 glass fills: light frost and night glass.
    public static func fill(_ v: Variant) -> RGB { v == .light ? .white : RGB(hex: "#1C202E") }
    public static func text(_ v: Variant) -> RGB { v == .light ? ink : paper }

    /// Worst contrast of `v`'s text on its fill at `alpha` across the backdrop range
    /// (contrast is monotonic in backdrop luminance, so the ends are the worst cases).
    public static func worstContrast(_ v: Variant, alpha: Double, backdrop: ClosedRange<Double>) -> Double {
        [backdrop.lowerBound, backdrop.upperBound].map { l in
            ratio(v, alpha: alpha, backdrop: Contrast.grey(luminance: l))
        }.min()!
    }

    static func ratio(_ v: Variant, alpha: Double, backdrop: RGB) -> Double {
        Contrast.ratio(text(v), Contrast.over(fill(v), alpha: alpha, backdrop: backdrop))
    }

    /// Smallest fill opacity (to 0.01) at or above `floor` that meets the minimum.
    public static func requiredAlpha(_ v: Variant, backdrop: ClosedRange<Double>, floor: Double = 0) -> Double {
        var a = max(floor, 0)
        while a < 1, worstContrast(v, alpha: a, backdrop: backdrop) < minimum { a = min(1, a + 0.01) }
        return (a * 100).rounded() / 100
    }

    /// The variant needing less dim; ties within 0.08 go to the system appearance.
    public static func pick(backdrop: ClosedRange<Double>, prefersDark: Bool, floor: Double = 0) -> (variant: Variant, alpha: Double) {
        let light = requiredAlpha(.light, backdrop: backdrop, floor: floor)
        let dark = requiredAlpha(.dark, backdrop: backdrop, floor: floor)
        if abs(light - dark) <= 0.08 { return prefersDark ? (.dark, dark) : (.light, light) }
        return light < dark ? (.light, light) : (.dark, dark)
    }
}
