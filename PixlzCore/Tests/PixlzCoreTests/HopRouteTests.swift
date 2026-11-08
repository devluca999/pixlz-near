import CoreGraphics
import Foundation
import Testing
@testable import PixlzCore

struct HopRouteTests {
    let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)  // visible frame, y down
    let sprite = CGSize(width: 140, height: 100)                 // Frogg at 2×

    @Test func durationFitsTheRequestedTime() {
        for (a, b, d) in [(CGPoint(x: 100, y: 500), CGPoint(x: 300, y: 500), 0.4),
                          (CGPoint(x: 100, y: 700), CGPoint(x: 600, y: 300), 0.6),
                          (CGPoint(x: 100, y: 300), CGPoint(x: 400, y: 800), 0.5)] {
            let p = HopPlan(from: a, to: b, apexHeight: 60, duration: d)
            #expect(abs(p.duration - d) < 1e-9)
            #expect(abs(p.position(at: p.duration).x - b.x) < 1e-6 && abs(p.position(at: p.duration).y - b.y) < 1e-6)
            #expect(abs(p.apex.y - (min(a.y, b.y) - 60)) < 1e-6)
        }
    }

    @Test func flightTimeGrowsFromShortToAcrossTheScreen() {
        #expect(HopRoute.duration(distance: 40, screenWidth: 1512) == 0.35)
        let mid = HopRoute.duration(distance: 500, screenWidth: 1512)
        #expect(mid > 0.5 && mid < 0.8)
        #expect(abs(HopRoute.duration(distance: 1512, screenWidth: 1512) - 0.8) < 1e-9)
        #expect(HopRoute.duration(distance: 4000, screenWidth: 1512) == 0.8)
    }

    @Test func apexIsAboutAFifthOfTheHorizontalDistance() throws {
        let r = HopRoute.plan(from: CGPoint(x: 200, y: 600), to: CGPoint(x: 600, y: 600), bounds: screen, sprite: sprite, scale: 2)
        let leg = try #require(r.legs.first)
        let apex = 600 - leg.apex.y
        #expect(r.legs.count == 1 && r.clear)
        #expect(apex >= 0.15 * 400 && apex <= 0.25 * 400)
    }

    @Test func shortHopsStillLeaveTheGround() throws {
        let r = HopRoute.plan(from: CGPoint(x: 200, y: 600), to: CGPoint(x: 230, y: 600), bounds: screen, sprite: sprite, scale: 2)
        let leg = try #require(r.legs.first)
        #expect(600 - leg.apex.y >= 20)  // minApex 10 apx × 2
        #expect(abs(leg.duration - 0.35) < 1e-9)
    }

    @Test func neverArcsIntoTheMenuBar() {
        // a window near the top of the screen: little headroom
        let r = HopRoute.plan(from: CGPoint(x: 100, y: 140), to: CGPoint(x: 700, y: 140), bounds: screen, sprite: sprite, scale: 2)
        for leg in r.legs {
            for p in leg.samples(48) { #expect(p.y - sprite.height >= screen.minY - 0.5) }
        }
    }

    @Test func longHopsChainIntoTwoOrThreeLegsThatConnect() {
        let a = CGPoint(x: 100, y: 800), b = CGPoint(x: 900, y: 800)
        let two = HopRoute.plan(from: a, to: b, bounds: screen, sprite: sprite, scale: 2)
        #expect(two.legs.count == 2)
        let three = HopRoute.plan(from: a, to: CGPoint(x: 1450, y: 400), bounds: screen, sprite: sprite, scale: 2)
        #expect(three.legs.count == 3)
        for r in [two, three] {
            #expect(r.legs.first?.start == a)
            for (x, y) in zip(r.legs, r.legs.dropFirst()) { #expect(x.end == y.start) }
            #expect(r.legs.allSatisfy { $0.duration <= 0.8 + 1e-9 })
        }
        #expect(three.end == CGPoint(x: 1450, y: 400))
        #expect(three.duration < 3 * 0.8)
    }

    @Test func chainedHopsLandOnThePlatformUnderEachStop() {
        // window tops at y 300 (left), 400 (middle), 300 (right): the middle stop lands on the middle window
        let windows = [CGRect(x: 0, y: 300, width: 300, height: 400), CGRect(x: 500, y: 400, width: 400, height: 300),
                       CGRect(x: 1100, y: 300, width: 400, height: 400)].enumerated().map { WindowInfo(id: $0 + 1, frame: $1) }
        let world = WorldMap(WorldInput(displays: [DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: screen)],
                                        windows: windows))
        let r = HopRoute.plan(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 1300, y: 300), bounds: screen, sprite: sprite, scale: 2, world: world)
        #expect(r.legs.count == 2)
        #expect(r.legs[0].end == CGPoint(x: 700, y: 400))
        // without a world map the stop sits on the straight line
        let plain = HopRoute.plan(from: CGPoint(x: 100, y: 300), to: CGPoint(x: 1300, y: 300), bounds: screen, sprite: sprite, scale: 2)
        #expect(plain.legs[0].end == CGPoint(x: 700, y: 300))
    }

    @Test func raisesTheArcToClearTheFocusedWindow() throws {
        // From the ground beside a focused window, onto its top (one leg): the default arc
        // (a fifth of the 200 pt horizontal distance) cuts through the window's body;
        // the route raises it until it clears.
        let window = CGRect(x: 500, y: 400, width: 600, height: 400)
        let a = CGPoint(x: 360, y: 895), b = CGPoint(x: 560, y: 402)
        let naive = HopPlan(from: a, to: b, apexHeight: 40, duration: 0.5)
        #expect(!HopRoute.isClear(naive, bounds: screen, sprite: sprite, keepOut: window))
        let r = HopRoute.plan(from: a, to: b, bounds: screen, sprite: sprite, scale: 2, keepOut: window)
        let leg = try #require(r.legs.first)
        #expect(r.legs.count == 1 && r.clear)
        #expect(HopRoute.isClear(leg, bounds: screen, sprite: sprite, keepOut: window))
        #expect(b.y - leg.apex.y > 100)  // raised well above the default 40 pt
    }

    @Test func reportsWhenNoArcCanClear() {
        // The target is inside the keep-out body: nothing clears; the route still exists, flagged.
        let window = CGRect(x: 0, y: 100, width: 1512, height: 700)
        let r = HopRoute.plan(from: CGPoint(x: 100, y: 895), to: CGPoint(x: 500, y: 600), bounds: screen, sprite: sprite, scale: 2, keepOut: window)
        #expect(!r.clear && r.legs.count == 1)
        // ...and keeps the natural arc instead of a screen-high one (seen live with a fullscreen window)
        #expect(600 - r.legs[0].apex.y <= 0.25 * 400 + 1)
        let fullscreen = HopRoute.plan(from: CGPoint(x: 900, y: 895), to: CGPoint(x: 700, y: 895), bounds: screen, sprite: sprite, scale: 2,
                                       keepOut: CGRect(x: 0, y: 25, width: 1512, height: 870))
        #expect(!fullscreen.clear && 895 - fullscreen.legs[0].apex.y <= 0.25 * 200 + 1)
    }
}

struct SquashStretchTests {
    @Test func phasesHaveTheRightShape() {
        let s = SquashStretch.self
        #expect(s.scale(.neutral) == CGSize(width: 1, height: 1))
        let coil = s.scale(.coil(1))
        #expect(coil.height < 0.9 && coil.width > 1.1)                // crouch: shorter, wider
        let takeoff = s.scale(.flight(0.02), apex: 0.45)
        #expect(takeoff.height > 1.1 && takeoff.width < 0.95)         // stretch rising
        let top = s.scale(.flight(0.45), apex: 0.45)
        #expect(abs(top.height - 1) < 0.01)                           // near neutral at the apex
        let falling = s.scale(.flight(0.95), apex: 0.45)
        #expect(falling.height > 1.02 && falling.height < 1.08)       // slight stretch falling
        let squash = s.scale(.land(0.5))
        #expect(squash.height < 0.85 && squash.width > 1.12)          // landing squash
        #expect(abs(s.scale(.land(1)).height - 1) < 1e-9)
        #expect(abs(s.scale(.settle(1)).height - 1) < 1e-9)           // settles back to neutral
    }

    @Test func settleIsOneOrTwoSmallBounces() {
        let ys = stride(from: 0.0, through: 1.0, by: 0.01).map { SquashStretch.scale(.settle($0)).height }
        #expect(ys.allSatisfy { abs($0 - 1) <= 0.07 })
        var crossings = 0
        for (a, b) in zip(ys, ys.dropFirst()) where (a - 1) * (b - 1) < 0 { crossings += 1 }
        #expect((2...4).contains(crossings))
    }

    @Test func areaStaysRoughlyConstant() {
        for phase: SquashStretch.Phase in [.coil(1), .flight(0), .flight(1), .land(0.5)] {
            let s = SquashStretch.scale(phase, apex: 0.5)
            #expect(abs(s.width * s.height - 1) < 0.08)
        }
    }

    @Test func quantizedToWholeArtPixels() {
        let size = CGSize(width: 70, height: 50)
        let q = SquashStretch.quantized(CGSize(width: 1.117, height: 0.861), sprite: size)
        #expect((size.width * q.width).rounded() == size.width * q.width)
        #expect((size.height * q.height).rounded() == size.height * q.height)
        #expect(q == CGSize(width: 78.0 / 70, height: 43.0 / 50))
        #expect(SquashStretch.quantized(CGSize(width: 0.001, height: 0.001), sprite: size) == CGSize(width: 1.0 / 70, height: 1.0 / 50))
    }
}
