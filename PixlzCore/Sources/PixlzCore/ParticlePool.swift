import CoreGraphics
import Foundation

/// Live FX particles (SPEC §8). At most 24; adding past that drops the oldest.
/// Empty means the FX layer draws nothing and needs no display link.
public struct ParticlePool: Sendable {
    public static let capacity = 24

    public struct Particle: Sendable, Equatable {
        public var effect: Effect
        public var position: CGPoint
        public var velocity: CGVector
        public var born: Date
        public var lifetime: TimeInterval

        public init(effect: Effect, position: CGPoint, velocity: CGVector = .zero, born: Date, lifetime: TimeInterval) {
            self.effect = effect
            self.position = position
            self.velocity = velocity
            self.born = born
            self.lifetime = lifetime
        }
    }

    public private(set) var particles: [Particle] = []

    public init() {}

    public var isEmpty: Bool { particles.isEmpty }

    public mutating func emit(_ p: Particle) {
        particles.append(p)
        if particles.count > Self.capacity { particles.removeFirst(particles.count - Self.capacity) }
    }

    /// Moves particles and removes expired ones.
    public mutating func step(to now: Date, dt: TimeInterval) {
        particles.removeAll { now.timeIntervalSince($0.born) >= $0.lifetime }
        for i in particles.indices {
            particles[i].position.x += particles[i].velocity.dx * dt
            particles[i].position.y += particles[i].velocity.dy * dt
        }
    }
}
