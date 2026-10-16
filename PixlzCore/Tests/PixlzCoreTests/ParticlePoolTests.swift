import CoreGraphics
import Foundation
import Testing
@testable import PixlzCore

@Suite struct ParticlePoolTests {
    @Test func capsAt24DroppingOldest() {
        var pool = ParticlePool()
        let t = Date(timeIntervalSince1970: 0)
        for i in 0..<30 {
            pool.emit(.init(effect: .dust, position: CGPoint(x: Double(i), y: 0), born: t, lifetime: 1))
        }
        #expect(pool.particles.count == 24)
        #expect(pool.particles.first?.position.x == 6)
    }

    @Test func expiresAndMoves() {
        var pool = ParticlePool()
        let t = Date(timeIntervalSince1970: 0)
        pool.emit(.init(effect: .puff, position: .zero, velocity: CGVector(dx: 10, dy: -20), born: t, lifetime: 0.5))
        pool.emit(.init(effect: .heart, position: .zero, born: t, lifetime: 4))
        pool.step(to: t.addingTimeInterval(0.1), dt: 0.1)
        #expect(pool.particles[0].position == CGPoint(x: 1, y: -2))
        pool.step(to: t.addingTimeInterval(0.5), dt: 0.4)
        #expect(pool.particles.map(\.effect) == [.heart])
        pool.step(to: t.addingTimeInterval(4), dt: 3.5)
        #expect(pool.isEmpty)
    }
}
