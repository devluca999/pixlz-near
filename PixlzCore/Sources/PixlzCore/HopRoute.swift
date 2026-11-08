import CoreGraphics
import Foundation

// Shaped hops for moving between windows (SPEC §4.5, §7.3). World coordinates: pt, y down.

extension HopPlan {
    /// A hop that takes `duration` seconds: the gravity is chosen to fit. `apexHeight` is pt
    /// above the higher endpoint, as in `init(from:to:apexHeight:gravity:)`.
    public init(from start: CGPoint, to end: CGPoint, apexHeight: Double, duration: TimeInterval) {
        precondition(apexHeight > 0 && duration > 0)
        let apexY = min(start.y, end.y) - apexHeight
        let rise = Double(start.y - apexY), fall = Double(end.y - apexY)
        // duration = √(2·rise/g) + √(2·fall/g)  ⇒  g = ((√(2·rise) + √(2·fall)) / duration)²
        let g = pow(((2 * rise).squareRoot() + (2 * fall).squareRoot()) / duration, 2)
        self.init(from: start, to: end, apexHeight: apexHeight, gravity: g)
    }

    /// Seconds from take-off to the top of the arc.
    public var timeToApex: TimeInterval { -velocity.dy / gravity }
}

/// A route of one to three hops from where the Pixl stands to a new spot.
public struct HopRoute: Sendable, Equatable {
    public struct Tuning: Sendable, Equatable {
        public var shortDuration: TimeInterval = 0.35   // a short hop
        public var longDuration: TimeInterval = 0.8     // across a whole screen
        public var shortDistance: CGFloat = 80          // pt; at or below this, shortDuration
        public var apexFraction: CGFloat = 0.2          // apex ≈ 20% of the horizontal distance (15–25%)
        public var minApex: CGFloat = 10                // apx; scaled by the Pixl's scale
        public var chainOver: CGFloat = 600             // pt; longer hops become 2–3 chained hops
        public var landingPause: TimeInterval = 0.08    // between chained hops
        public init() {}
    }

    public let legs: [HopPlan]
    public let pause: TimeInterval
    /// Every sampled point of every leg keeps the sprite under the menu bar and out of the keep-out body.
    public let clear: Bool

    public var duration: TimeInterval { legs.map(\.duration).reduce(0, +) + pause * Double(max(legs.count - 1, 0)) }
    public var end: CGPoint { legs.last?.end ?? .zero }

    /// Flight time for one hop of length `distance`, growing from short to long like a square root.
    public static func duration(distance: CGFloat, screenWidth: CGFloat, tuning t: Tuning = Tuning()) -> TimeInterval {
        let span = max(screenWidth - t.shortDistance, 1)
        let f = min(max((distance - t.shortDistance) / span, 0), 1)
        return t.shortDuration + (t.longDuration - t.shortDuration) * Double(f).squareRoot()
    }

    /// - Parameters:
    ///   - bounds: the display's visible frame (the arc stays under its top: the menu bar).
    ///   - sprite: the Pixl's size in pt (feet at the bottom centre).
    ///   - keepOut: the focused window (SPEC §6.4): the arc may cross only its top 2 pt band.
    ///   - world: if given, chained hops land on the platform under each stop (else on the straight line).
    public static func plan(from a: CGPoint, to b: CGPoint, bounds: CGRect, sprite: CGSize, scale: CGFloat,
                            keepOut: CGRect? = nil, world: WorldMap? = nil, tuning t: Tuning = Tuning()) -> HopRoute {
        let distance = hypot(b.x - a.x, b.y - a.y)
        let count = distance <= t.chainOver ? 1 : (distance <= 2 * t.chainOver ? 2 : 3)
        var stops = [a]
        for i in 1..<count {
            let f = CGFloat(i) / CGFloat(count)
            let x = a.x + (b.x - a.x) * f
            let lineY = a.y + (b.y - a.y) * f
            // land on whatever is under the straight line at that x (a window top, else the ground)
            let y = world?.firstPlatformBelow(CGPoint(x: x, y: lineY))?.point.y ?? lineY
            stops.append(CGPoint(x: x, y: y))
        }
        stops.append(b)
        var legs: [HopPlan] = []
        var clear = true
        for (p, q) in zip(stops, stops.dropFirst()) {
            let (leg, ok) = shapedLeg(from: p, to: q, bounds: bounds, sprite: sprite, scale: scale, keepOut: keepOut, tuning: t)
            legs.append(leg)
            clear = clear && ok
        }
        return HopRoute(legs: legs, pause: t.landingPause, clear: clear)
    }

    static func shapedLeg(from a: CGPoint, to b: CGPoint, bounds: CGRect, sprite: CGSize, scale: CGFloat,
                          keepOut: CGRect?, tuning t: Tuning) -> (HopPlan, Bool) {
        let dx = abs(b.x - a.x)
        let minApex = t.minApex * scale
        let room = min(a.y, b.y) - sprite.height - bounds.minY  // headroom under the menu bar
        let maxApex = max(room, 1)
        let natural = min(max(dx * t.apexFraction, minApex), maxApex)
        let duration = Self.duration(distance: hypot(b.x - a.x, b.y - a.y), screenWidth: bounds.width, tuning: t)
        // Raise the arc until it clears the keep-out body (SPEC §7.3), within the headroom
        // and at most 3× the natural height or 1.5× the sprite. If nothing clears (e.g. a fullscreen-sized window),
        // keep the natural arc: a giant arc in the same flight time would look like a teleport.
        var apex = natural
        for _ in 0..<6 {
            let plan = HopPlan(from: a, to: b, apexHeight: Double(apex), duration: duration)
            if isClear(plan, bounds: bounds, sprite: sprite, keepOut: keepOut) { return (plan, true) }
            let next = min(apex * 1.35, maxApex, max(natural * 3, sprite.height * 1.5))
            if next <= apex { break }
            apex = next
        }
        return (HopPlan(from: a, to: b, apexHeight: Double(natural), duration: duration), false)
    }

    /// The sprite's box at each sampled point: under the menu bar, and touching the keep-out
    /// rect only in its top 2 pt band (where perching is allowed, SPEC §6.4).
    public static func isClear(_ plan: HopPlan, bounds: CGRect, sprite: CGSize, keepOut: CGRect?) -> Bool {
        let body = keepOut.map { CGRect(x: $0.minX, y: $0.minY + 2, width: $0.width, height: max($0.height - 2, 0)) }
        return plan.samples(24).allSatisfy { p in
            let box = CGRect(x: p.x - sprite.width / 2, y: p.y - sprite.height, width: sprite.width, height: sprite.height)
            return box.minY >= bounds.minY - 0.5 && !(body.map { box.intersects($0.insetBy(dx: 0.5, dy: 0.5)) } ?? false)
        }
    }
}

/// Squash and stretch for hops (scale factors applied about the feet). Values keep the
/// area roughly constant; `quantized` snaps them to whole sprite pixels so pixel art stays crisp.
public enum SquashStretch {
    public enum Phase: Sendable, Equatable {
        case neutral
        case coil(Double)     // 0…1 through the crouch
        case flight(Double)   // 0…1 through the air; `apex` is where the top is
        case land(Double)     // 0…1 through the landing squash
        case settle(Double)   // 0…1 through the settle bounces
    }

    /// (sx, sy). `apex` is the fraction of the flight at the top of the arc.
    public static func scale(_ phase: Phase, apex: Double = 0.5) -> CGSize {
        let sy: Double
        switch phase {
        case .neutral: sy = 1
        case .coil(let t): sy = 1 - 0.14 * ease(t)                        // crouch: shorter, wider
        case .flight(let t):
            if t < apex {
                sy = 1 + 0.14 * (1 - ease(t / max(apex, 0.01)))          // stretch on take-off, easing to neutral at the apex
            } else {
                sy = 1 + 0.06 * ease((t - apex) / max(1 - apex, 0.01))   // slight stretch while falling
            }
        case .land(let t): sy = 1 - 0.2 * sin(Double.pi * min(max(t, 0), 1))   // squash in and out
        case .settle(let t):
            let c = min(max(t, 0), 1)
            sy = 1 + 0.07 * sin(2 * Double.pi * 1.5 * c) * (1 - c)      // 1–2 small bounces, dying out
        }
        let sx = 1 + (1 - sy) * 0.85                                       // near area-preserving
        return CGSize(width: sx, height: sy)
    }

    static func ease(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)  // smoothstep
    }

    /// Snaps a scale to whole art pixels for a sprite `size` (in art pixels), never below 1 pixel.
    public static func quantized(_ s: CGSize, sprite size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1, height: 1) }
        let w = max((size.width * s.width).rounded(), 1), h = max((size.height * s.height).rounded(), 1)
        return CGSize(width: w / size.width, height: h / size.height)
    }
}
