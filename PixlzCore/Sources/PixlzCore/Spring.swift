import Foundation

/// A damped spring (mass–spring–damper), solved in closed form so any time can be sampled
/// directly: a dropped frame never makes the motion jump (positions come from elapsed time).
///
/// `value(at:)` is the position of a unit mass pulled toward `target`, starting at `from`
/// with velocity `velocity` (units per second).
public struct DampedSpring: Sendable, Equatable {
    public var stiffness: Double   // k
    public var damping: Double     // c
    public var mass: Double        // m

    public init(stiffness: Double, damping: Double, mass: Double = 1) {
        precondition(stiffness > 0 && damping >= 0 && mass > 0)
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    /// Natural angular frequency ω₀ = √(k/m).
    public var omega: Double { (stiffness / mass).squareRoot() }
    /// Damping ratio ζ = c / (2√(km)). Below 1 it overshoots; 1 is critically damped.
    public var dampingRatio: Double { damping / (2 * (stiffness * mass).squareRoot()) }

    /// A spring with a given ζ and ω₀ (mass 1).
    public init(dampingRatio zeta: Double, omega w0: Double) {
        self.init(stiffness: w0 * w0, damping: 2 * zeta * w0, mass: 1)
    }

    /// Position at time `t` (seconds; clamped at 0).
    public func value(from x0: Double, to target: Double, velocity v0: Double = 0, at t: Double) -> Double {
        let t = max(t, 0)
        let w0 = omega, z = dampingRatio
        let x = x0 - target  // displacement
        if z < 1 {
            let wd = w0 * (1 - z * z).squareRoot()
            let a = x, b = (v0 + z * w0 * x) / wd
            return target + exp(-z * w0 * t) * (a * cos(wd * t) + b * sin(wd * t))
        } else if z == 1 {
            return target + exp(-w0 * t) * (x + (v0 + w0 * x) * t)
        } else {
            let s = (z * z - 1).squareRoot()
            let r1 = -w0 * (z - s), r2 = -w0 * (z + s)
            let c2 = (v0 - r1 * x) / (r2 - r1), c1 = x - c2
            return target + c1 * exp(r1 * t) + c2 * exp(r2 * t)
        }
    }

    /// Seconds until the displacement envelope stays within `epsilon` of a unit step.
    public func settleTime(epsilon: Double = 0.02) -> Double {
        let z = min(dampingRatio, 1)
        return -log(epsilon) / (max(z, 0.01) * omega)
    }

    // MARK: presets for Frogg's squash and stretch (vertical scale; 1 = neutral)

    /// Landing: ζ ≈ 0.28 gives ~40% first overshoot, so a 0.75 squash springs to ~1.1, then
    /// ~0.97, then rests at 1.0, settling in about 0.35 s.
    public static let landing = DampedSpring(dampingRatio: 0.28, omega: 26)
    /// The crouch before take-off: quick and nearly critically damped (no wobble).
    public static let crouch = DampedSpring(dampingRatio: 0.9, omega: 38)
    /// The "whoa" wobble when the Space changes under Frogg.
    public static let wobble = DampedSpring(dampingRatio: 0.22, omega: 34)
}
