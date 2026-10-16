import CoreGraphics
import Foundation

// World coordinates throughout PixlzCore: points, y grows downward, origin at the top-left of the
// primary display (the same convention as CGWindowList and the Accessibility API). The Pixl's
// position is its anchor (foot) point. The AppKit layer converts to and from Cocoa's y-up space.

/// Physics constants from SPEC §4.5, in pt for a given scale.
public struct PhysicsConfig: Sendable, Equatable {
    /// pt/s².
    public var gravity: Double
    /// pt/s.
    public var terminalVelocity: Double
    /// pt/s. Applied to the release velocity of a throw.
    public var maxThrowSpeed: Double = 3000
    public var restitution: Double = 0.4
    /// Ground friction stops a sliding Pixl within this many seconds.
    public var slideStopTime: Double = 1

    public init(species: SpeciesPhysics, scale: Double) {
        gravity = species.gravity * scale
        terminalVelocity = 1500 * scale
    }
}

/// A solved hop: a parabola from `start` to `end` peaking `apexHeight` above the higher of the two.
public struct HopPlan: Sendable, Equatable {
    public let start: CGPoint
    public let end: CGPoint
    public let velocity: CGVector
    public let gravity: Double
    public let duration: TimeInterval

    /// - Parameter apexHeight: pt above the higher endpoint. Must be > 0.
    public init(from start: CGPoint, to end: CGPoint, apexHeight: Double, gravity: Double) {
        precondition(apexHeight > 0 && gravity > 0)
        self.start = start
        self.end = end
        self.gravity = gravity
        let apexY = min(start.y, end.y) - apexHeight
        let vy = -(2 * gravity * (start.y - apexY)).squareRoot()
        let rise = -vy / gravity
        let fall = (2 * (end.y - apexY) / gravity).squareRoot()
        duration = rise + fall
        velocity = CGVector(dx: (end.x - start.x) / duration, dy: vy)
    }

    public var apex: CGPoint { position(at: -velocity.dy / gravity) }

    public func position(at t: TimeInterval) -> CGPoint {
        let t = min(max(t, 0), duration)
        return CGPoint(x: start.x + velocity.dx * t, y: start.y + velocity.dy * t + 0.5 * gravity * t * t)
    }

    /// Points along the arc, for clearance checks (SPEC §7.3).
    public func samples(_ count: Int = 16) -> [CGPoint] {
        (0...count).map { position(at: duration * Double($0) / Double(count)) }
    }
}

/// A free body: falls, flies after a throw, bounces off the screen bounds.
public struct Body: Sendable, Equatable {
    public var position: CGPoint
    public var velocity: CGVector

    public init(position: CGPoint, velocity: CGVector = .zero) {
        self.position = position
        self.velocity = velocity
    }

    /// Release velocity of a throw: cursor displacement over the last 100 ms, capped (SPEC §4.5).
    /// `samples` are (time, cursor position) pairs in any order.
    public static func throwVelocity(samples: [(TimeInterval, CGPoint)], at now: TimeInterval, cap: Double) -> CGVector {
        let recent = samples.filter { now - $0.0 <= 0.1 }.sorted { $0.0 < $1.0 }
        guard let first = recent.first, let last = recent.last, last.0 > first.0 else { return .zero }
        let dt = last.0 - first.0
        var v = CGVector(dx: (last.1.x - first.1.x) / dt, dy: (last.1.y - first.1.y) / dt)
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        if speed > cap { v = CGVector(dx: v.dx * cap / speed, dy: v.dy * cap / speed) }
        return v
    }

    /// Integrates one step in the air. Bounces off the left/right edges of `bounds` and its top
    /// (the menu bar) with restitution. Landing is the world map's job (`WorldMap.landing`).
    public mutating func stepAirborne(dt: TimeInterval, config: PhysicsConfig, bounds: CGRect) {
        velocity.dy = min(velocity.dy + config.gravity * dt, config.terminalVelocity)
        position.x += velocity.dx * dt
        position.y += velocity.dy * dt
        if position.x < bounds.minX {
            position.x = bounds.minX + (bounds.minX - position.x) * config.restitution
            velocity.dx = -velocity.dx * config.restitution
        } else if position.x > bounds.maxX {
            position.x = bounds.maxX - (position.x - bounds.maxX) * config.restitution
            velocity.dx = -velocity.dx * config.restitution
        }
        if position.y < bounds.minY {
            position.y = bounds.minY
            velocity.dy = -velocity.dy * config.restitution
        }
    }

    /// Integrates one step sliding on the ground after a landing. Returns true once stopped.
    /// Deceleration is set so the landing speed reaches zero within `slideStopTime`.
    public mutating func stepSliding(dt: TimeInterval, landingSpeed: Double, config: PhysicsConfig, bounds: CGRect) -> Bool {
        velocity.dy = 0
        let decel = abs(landingSpeed) / config.slideStopTime
        let speed = max(0, abs(velocity.dx) - decel * dt)
        velocity.dx = velocity.dx < 0 ? -speed : speed
        position.x = min(max(position.x + velocity.dx * dt, bounds.minX), bounds.maxX)
        return speed == 0
    }
}
