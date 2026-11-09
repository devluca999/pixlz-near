import AppKit
import Testing
@testable import PixlMemoryKit

/// Hovered rows must stay readable in every theme, for every Pixl's accent.
@MainActor
@Suite struct HoverContrastTests {
    func rgb(_ c: NSColor) -> (RGB, Double) {
        let s = c.usingColorSpace(.sRGB)!
        return (RGB(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)), Double(s.alphaComponent))
    }
    func over(_ top: NSColor, _ base: RGB) -> RGB {
        let (t, a) = rgb(top)
        return RGB(t.r * a + base.r * (1 - a), t.g * a + base.g * (1 - a), t.b * a + base.b * (1 - a))
    }

    @Test func hoveredRowsAreLegibleInEveryThemeForEveryPixl() {
        let before = PixlSkins.currentID
        defer { PixlSkins.currentID = before }
        for skin in PixlSkins.all {
            PixlSkins.currentID = skin.id
            for glass in [false, true] {
                for variant in [Legibility.Variant.light, .dark] {
                    let look = SurfaceView.Look(glass: glass, variant: variant, dim: 0.94)
                    let base = glass ? Legibility.fill(variant) : rgb(look.tokens.fill).0
                    let text = rgb(look.textColor).0
                    for pressed in [false, true] {
                        let bg = over(look.rowFill(pressed: pressed), base)
                        let r = Contrast.ratio(text, bg)
                        #expect(r >= 4.5, "\(skin.id) \(glass ? "glass" : "solid")/\(variant) pressed=\(pressed): \(String(format: "%.2f", r)):1")
                    }
                }
            }
        }
    }
}
