import CoreGraphics
import Foundation
import Testing
@testable import PixlzCore

struct SpringTests {
    /// Local extrema of `f` sampled every millisecond over [0, duration].
    func peaks(_ f: (Double) -> Double, duration: Double) -> [(t: Double, v: Double)] {
        let xs = stride(from: 0.0, through: duration, by: 0.001).map { ($0, f($0)) }
        return zip(zip(xs, xs.dropFirst()), xs.dropFirst(2)).compactMap { pair, c in
            let (a, b) = pair
            return (b.1 > a.1 && b.1 >= c.1) || (b.1 < a.1 && b.1 <= c.1) ? (b.0, b.1) : nil
        }
    }

    @Test func startsWhereToldAndSettlesOnTarget() {
        for s in [DampedSpring.landing, .crouch, .wobble, DampedSpring(dampingRatio: 1, omega: 20), DampedSpring(dampingRatio: 1.6, omega: 20)] {
            #expect(abs(s.value(from: 0.75, to: 1, at: 0) - 0.75) < 1e-12)
            #expect(abs(s.value(from: 0.75, to: 1, at: 5) - 1) < 1e-6)
        }
    }

    @Test func initialVelocityIsHonoured() {
        let s = DampedSpring(stiffness: 300, damping: 10)
        let h = 1e-6
        for v0 in [-4.0, 0, 3.2] {
            let v = (s.value(from: 1, to: 1, velocity: v0, at: h) - s.value(from: 1, to: 1, velocity: v0, at: 0)) / h
            #expect(abs(v - v0) < 1e-3)
        }
    }

    @Test func dampingRatioAndFrequencyRoundTrip() {
        let s = DampedSpring(dampingRatio: 0.3, omega: 25)
        #expect(abs(s.dampingRatio - 0.3) < 1e-12 && abs(s.omega - 25) < 1e-12)
        let m = DampedSpring(stiffness: 800, damping: 40, mass: 2)  // ω₀ = √400, ζ = 40 / (2·√1600)
        #expect(abs(m.omega - 20) < 1e-12 && abs(m.dampingRatio - 0.5) < 1e-12)
    }

    @Test func criticalAndOverDampedNeverOvershoot() {
        for z in [1.0, 1.4, 3] {
            let s = DampedSpring(dampingRatio: z, omega: 30)
            let values = stride(from: 0.0, through: 1, by: 0.002).map { s.value(from: 0, to: 1, at: $0) }
            #expect(values.allSatisfy { $0 <= 1 + 1e-9 })
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })  // monotonic
        }
    }

    /// The landing squash: 0.75 → ~1.1 → ~0.97 → 1.0 over about 0.35 s, 1–2 overshoots.
    @Test func landingSquashSpringsBackWithOneOrTwoOvershoots() throws {
        let sy = { (t: Double) in Double(SquashStretch.landing(t).height) }
        #expect(abs(sy(0) - 0.75) < 1e-9)
        let p = peaks(sy, duration: SquashStretch.landingTime)
        let first = try #require(p.first)
        #expect(first.v > 1.07 && first.v < 1.13)                       // ~1.1
        #expect(first.t > 0.08 && first.t < 0.16)
        let second = try #require(p.dropFirst().first)
        #expect(second.v > 0.95 && second.v < 0.99)                     // ~0.97
        let visible = p.filter { abs($0.v - 1) > 0.01 }                  // overshoots you can see (≥ 1 art px at 3×)
        #expect(visible.count >= 2 && visible.count <= 3)
        #expect(abs(sy(0.35) - 1) < 0.02)                                // settled by ~0.35 s
        #expect(sy(SquashStretch.landingTime) == 1)                      // exactly neutral at the end
        // near area-preserving: wide when short
        #expect(SquashStretch.landing(0).width > 1.15)
    }

    @Test func crouchGoesDownWithoutWobbleAndWobbleReturnsToNeutral() {
        let c = stride(from: 0.0, through: 0.15, by: 0.005).map { Double(SquashStretch.crouch($0).height) }
        #expect(c.first == 1 && c.last! < 0.82 && c.allSatisfy { $0 >= 0.8 - 0.01 && $0 <= 1 })
        #expect(SquashStretch.wobble(0.02).height > 1.03)                // stretches up first
        #expect(abs(SquashStretch.wobble(0.4).height - 1) < 0.01)
    }

    @Test func settleTimeMatchesTheEnvelope() {
        let s = DampedSpring.landing
        let t = s.settleTime(epsilon: 0.02)
        #expect(t > 0.3 && t < 0.7)
        #expect(stride(from: t, through: t + 0.5, by: 0.01).allSatisfy { abs(s.value(from: 0, to: 1, at: $0) - 1) <= 0.02 + 1e-9 })
    }
}

struct CrossDisplayRouteTests {
    let sprite = CGSize(width: 140, height: 100)
    // y down. Built-in 1512×870 visible (menu bar 25); an external 1920×1050 to its right, top aligned.
    let left = CGRect(x: 0, y: 25, width: 1512, height: 870)
    let right = CGRect(x: 1512, y: 25, width: 1920, height: 1050)

    @Test func sameDisplayBehavesLikeBefore() {
        let a = CGPoint(x: 200, y: 600), b = CGPoint(x: 700, y: 600)
        let r = HopRoute.plan(from: a, to: b, displays: [left, right], sprite: sprite, scale: 2)
        let old = HopRoute.plan(from: a, to: b, bounds: left, sprite: sprite, scale: 2)
        #expect(r == old && r.popAfter == nil)
    }

    @Test func oneArcAcrossWhenItStaysOnBothScreens() throws {
        let a = CGPoint(x: 1300, y: 700), b = CGPoint(x: 1800, y: 700)
        let r = HopRoute.plan(from: a, to: b, displays: [left, right], sprite: sprite, scale: 2)
        #expect(r.popAfter == nil && r.legs.count == 1)
        let leg = try #require(r.legs.first)
        #expect(HopRoute.staysOnScreen(leg, displays: [left, right], sprite: sprite))
        #expect(leg.apex.y - sprite.height >= max(left.minY, right.minY) - 0.5)  // head under both menu bars
        #expect(leg.start == a && leg.end == b)
    }

    /// Different heights, bottom aligned: the short display's top is far below the tall one's.
    /// Hopping from low on the short display to high on the tall one, the arc would leave the
    /// union over the gap above the short display, so it goes edge → pop → in.
    @Test func popsThroughWhenNoArcStaysOnScreen() throws {
        let tall = CGRect(x: 0, y: 25, width: 1512, height: 1400)        // y 25…1425
        let short = CGRect(x: 1512, y: 1025, width: 1280, height: 400)   // y 1025…1425
        let a = CGPoint(x: 1900, y: 1300), b = CGPoint(x: 300, y: 200)
        let r = HopRoute.plan(from: a, to: b, displays: [tall, short], sprite: sprite, scale: 2)
        let pop = try #require(r.popAfter)
        let out = r.legs[pop], into = r.legs[pop + 1]
        #expect(out.start == a && r.legs.last?.end == b)
        #expect(abs(out.end.x - (short.minX + sprite.width / 2)) < 0.5)   // leaves at the shared edge
        #expect(abs(into.start.x - (tall.maxX - sprite.width / 2)) < 0.5) // arrives at the other side of it
        for leg in r.legs { #expect(HopRoute.staysOnScreen(leg, displays: [tall, short], sprite: sprite)) }
    }

    @Test func scaledDisplaysAndOffsetsUseGlobalPoints() throws {
        // A Retina built-in (points already) and a 1× external placed above and offset: vertical crossing.
        let below = CGRect(x: 0, y: 1105, width: 1512, height: 870)
        let above = CGRect(x: 300, y: 25, width: 2560, height: 1055)
        let a = CGPoint(x: 700, y: 1900), b = CGPoint(x: 900, y: 600)
        let r = HopRoute.plan(from: a, to: b, displays: [below, above], sprite: sprite, scale: 2)
        #expect(r.legs.first?.start == a && r.legs.last?.end == b)
        for leg in r.legs { #expect(HopRoute.staysOnScreen(leg, displays: [below, above], sprite: sprite)) }
        if let pop = r.popAfter {
            #expect(abs(r.legs[pop].end.y - (below.minY + sprite.height + 20)) < 0.5)  // leaves through the top edge (20 pt headroom)
            #expect(abs(r.legs[pop + 1].start.y - above.maxY) < 0.5)          // in at the bottom of the upper display
        }
    }
}
