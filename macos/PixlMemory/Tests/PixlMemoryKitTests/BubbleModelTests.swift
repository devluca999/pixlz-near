import AppKit
import CoreGraphics
import Testing
@testable import PixlMemoryKit

struct LegibilityTests {
    @Test func contrastMatchesWCAGReferenceValues() {
        #expect(abs(Contrast.ratio(.white, .black) - 21) < 0.01)
        #expect(abs(Contrast.ratio(RGB(hex: "#777777"), .white) - 4.48) < 0.02)
        #expect(Contrast.ratio(Legibility.ink, Legibility.paper) > 13)  // the paper fallback is always legible
    }

    @Test func worstCaseDimKeepsTextAt4_5Everywhere() {
        for v in [Legibility.Variant.light, .dark] {
            let a = Legibility.requiredAlpha(v, backdrop: 0...1)
            #expect(a > 0.3 && a < 1)
            for l in stride(from: 0.0, through: 1.0, by: 0.05) {  // every backdrop, black to white
                let r = Legibility.ratio(v, alpha: a, backdrop: Contrast.grey(luminance: l))
                #expect(r >= 4.5, "\(v) at backdrop \(l): \(r)")
            }
            #expect(Legibility.worstContrast(v, alpha: a - 0.02, backdrop: 0...1) < 4.5)  // and it's the minimum
        }
    }

    @Test func designFillsAreRaisedWhenTheyWouldFail() {
        // C8 label pill: white at 62% over a black backdrop is fine; the bubble glass (18%) is not, for text.
        #expect(Legibility.worstContrast(.light, alpha: 0.62, backdrop: 0...1) >= 4.5)
        #expect(Legibility.worstContrast(.light, alpha: 0.18, backdrop: 0...1) < 4.5)
        #expect(Legibility.requiredAlpha(.light, backdrop: 0...1, floor: 0.62) == 0.62)  // floor kept when it passes
    }

    @Test func pickerUsesTheBackdropWhenItsKnown() {
        let bright = Legibility.pick(backdrop: 0.8...1, prefersDark: true)   // white doc
        #expect(bright.variant == .light && bright.alpha < 0.2)
        let dark = Legibility.pick(backdrop: 0...0.05, prefersDark: false)   // dark editor
        #expect(dark.variant == .dark && dark.alpha < 0.3)
        let unknown = Legibility.pick(backdrop: 0...1, prefersDark: true)    // busy photo / unknown
        #expect(Legibility.worstContrast(unknown.variant, alpha: unknown.alpha, backdrop: 0...1) >= 4.5)
    }
}

struct BubbleModelTests {
    @Test func slotsFollowTheDesign() {
        #expect(BubbleMenuModel.slots(selection: false, peer: nil, walletSub: "0.95 Ⓝ").map(\.id) == ["ask", "memory", "wallet", "more"])
        #expect(BubbleMenuModel.slots(selection: true, peer: "iPhone", walletSub: nil).map(\.id) == ["polish", "memory", "wallet", "send", "more"])
        #expect(BubbleMenuModel.slots(selection: false, peer: nil, walletSub: "4.20 NEAR")[2].accessibilityLabel == "Wallet, 4.20 NEAR")
    }

    @Test func arcIs32DegreesApartAboveTheHead() {
        let head = CGPoint(x: 500, y: 500)
        let pts = BubbleMenuModel.arc(count: 4, head: head, radius: 88)
        #expect(pts.allSatisfy { abs(hypot($0.x - head.x, $0.y - head.y) - 88) < 0.001 })
        #expect(pts.allSatisfy { $0.y < head.y })                         // above (y down)
        #expect(pts.first!.x < pts.last!.x)                                // left to right
        let a0 = atan2(pts[0].y - head.y, pts[0].x - head.x), a1 = atan2(pts[1].y - head.y, pts[1].x - head.x)
        #expect(abs((a1 - a0) * 180 / .pi - 32) < 0.001)
        #expect(BubbleMenuModel.radius(scale: 2) == 88 && BubbleMenuModel.radius(scale: 3) == 104)
    }

    @Test func placementFlipsToStayOnScreenAndOffTheSelection() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)
        // plenty of room: up
        #expect(BubbleMenuModel.place(count: 4, head: CGPoint(x: 700, y: 500), radius: 88, screen: screen, avoid: []).direction == .up)
        // under the menu bar: not up
        let top = BubbleMenuModel.place(count: 4, head: CGPoint(x: 700, y: 60), radius: 88, screen: screen, avoid: [])
        #expect(top.direction != .up && top.offset == .zero)
        // the selection sits right above the head: go elsewhere, and never cover it
        let selection = CGRect(x: 560, y: 330, width: 300, height: 120)
        let p = BubbleMenuModel.place(count: 4, head: CGPoint(x: 700, y: 500), radius: 88, screen: screen, avoid: [selection])
        #expect(p.direction != .up)
        #expect(p.centers.map(BubbleMenuModel.footprint).allSatisfy { $0.intersection(selection).isNull })
        // a corner: everything on screen
        let corner = BubbleMenuModel.place(count: 5, head: CGPoint(x: 1500, y: 880), radius: 88, screen: screen, avoid: [])
        #expect(corner.centers.map(BubbleMenuModel.footprint).allSatisfy { screen.insetBy(dx: -0.5, dy: -0.5).contains($0) })
    }

    @Test func openCloseAndPopFollowTheDesignCurves() throws {
        #expect(BubbleMenuModel.open(0) == nil)
        let mid = try #require(BubbleMenuModel.open(0.45 * 0.32))
        #expect(abs(mid.s - 1.14) < 0.001 && mid.q == 1)                  // overshoot at 45%
        let dip = try #require(BubbleMenuModel.open(0.7 * 0.32))
        #expect(abs(dip.s - 0.95) < 0.001)                                  // dip at 70%
        #expect(BubbleMenuModel.open(0.32) == .rest)
        #expect(abs(BubbleMenuModel.close(0.25 * 0.17)!.s - 1.06) < 0.001)  // swell first
        #expect(BubbleMenuModel.close(0.17) == nil)
        #expect(BubbleMenuModel.pop(0.13) == nil && BubbleMenuModel.pop(0.05)!.s > 1)
        #expect(BubbleMenuModel.openDelay(3) == 0.135)
        #expect(BubbleMenuModel.closeDelay(0, of: 4) == 0.09 && BubbleMenuModel.closeDelay(3, of: 4) == 0)  // reverse
        #expect(abs(BubbleMenuModel.openDuration(count: 5) - 0.5) < 1e-9)
    }

    @Test func hoverAndPressStates() {
        let rest = BubbleMenuModel.hoverPress(hover: 0, press: 0, paper: false)
        #expect(rest.scale == 1 && rest.lift == 0)
        let hover = BubbleMenuModel.hoverPress(hover: 1, press: 0, paper: false)
        #expect(abs(hover.scale - 1.1) < 1e-9 && hover.lift == -3)
        let pressed = BubbleMenuModel.hoverPress(hover: 0, press: 1, paper: false)
        #expect(abs(pressed.scale - 0.9) < 1e-9)
        let paper = BubbleMenuModel.hoverPress(hover: 0, press: 1, paper: true)
        #expect(abs(paper.scale - 0.96) < 1e-9 && paper.lift == 2)
        #expect(BubbleMenuModel.approach(0, to: 1, dt: 0.06) == 0.5)
    }
}

@MainActor
struct IconTests {
    @Test func everyIconIs12x12AndRenders() {
        for name in BubbleIcons.names {
            #expect(BubbleIcons.grids[name]!.count == 12 && BubbleIcons.grids[name]!.allSatisfy { $0.count == 12 }, "\(name)")
            #expect(BubbleIcons.image(name, dark: false)?.size == NSSize(width: 24, height: 24))
        }
        #expect(Set(BubbleIcons.names).isSuperset(of: ["ask", "polish", "memory", "wallet", "send", "more", "settings", "hide"]))
        #expect(BubbleIcons.image("nope", dark: false) == nil)
    }
}
