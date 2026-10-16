import CoreGraphics
import Foundation
import Testing
@testable import PixlzCore

@Suite struct SlotPlayerTests {
    @Test func noneLoopPlaysOnceThenFinishes() {
        var p = SlotPlayer(slot: .poke, spec: SlotSpec(holds: [2, 4, 6], loop: .none))
        #expect(p.ticksUntilNextChange == 2)
        let changed = p.advance(ticks: 2)
        #expect(changed && p.frame == 1)
        p.advance(ticks: 4); #expect(p.frame == 2)
        #expect(p.ticksUntilNextChange == 6)
        p.advance(ticks: 6)
        #expect(p.isFinished && p.frame == 2)
        #expect(p.ticksUntilNextChange == nil)
    }

    @Test func allLoopCyclesAndOneBigAdvanceMatchesManySmall() {
        let spec = SlotSpec(holds: [6, 2, 8], loop: .all)
        var a = SlotPlayer(slot: .idle, spec: spec), b = a
        a.advance(ticks: 37)
        for _ in 0..<37 { b.advance() }
        #expect(a == b)
        #expect(a.cycles == 2 && a.frame == 0 && a.elapsed == 5)   // 16 + 16 + 5
        #expect(!a.isFinished)
    }

    @Test func idleWakesOnlyOnFrameChanges() {
        var p = SlotPlayer(slot: .idle, spec: SlotSpec(holds: [6, 2, 8], loop: .all))
        var wakeups = 0, ticks = 0
        while ticks < 160 {
            let n = p.ticksUntilNextChange!
            p.advance(ticks: n); ticks += n; wakeups += 1
        }
        #expect(wakeups == 30)  // 3 per 16-tick pass, not 160
    }

    @Test func physicsHeldFrameWaitsForRelease() {
        var p = SlotPlayer(slot: .move, spec: SlotSpec(holds: [3, 0, 3], loop: .none))
        p.advance(ticks: 3)
        #expect(p.frame == 1 && p.ticksUntilNextChange == nil)
        p.advance(ticks: 100)
        #expect(p.frame == 1)
        p.release()
        #expect(p.frame == 2 && p.ticksUntilNextChange == 3)
        p.advance(ticks: 3)
        #expect(p.isFinished)
    }

    @Test func lastLoopHoldsUntilEnd() {
        var p = SlotPlayer(slot: .rest, spec: SlotSpec(holds: [6, 6, 12], loop: .last))
        p.advance(ticks: 12)
        #expect(p.frame == 2 && p.ticksUntilNextChange == nil)
        p.end()
        #expect(p.isFinished)
    }

    @Test func middleLoopEndsThroughFrameTwo() {
        var p = SlotPlayer(slot: .grab, spec: SlotSpec(holds: [2, 6, 3], loop: .middle))
        p.advance(ticks: 50)
        #expect(p.frame == 1 && !p.isFinished)
        p.end()
        #expect(p.frame == 2 && p.ticksUntilNextChange == 3)
        p.advance(ticks: 3)
        #expect(p.isFinished)
    }
}

@Suite struct RandomTests {
    @Test func sameSeedSameSequence() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42), c = SeededRandom(seed: 43)
        let sa = (0..<5).map { _ in a.next() }, sb = (0..<5).map { _ in b.next() }
        #expect(sa == sb)
        #expect(sa != (0..<5).map { _ in c.next() })
    }

    @Test func weightedIndexRespectsWeights() {
        var rng = SeededRandom(seed: 7)
        var counts = [0, 0, 0]
        for _ in 0..<10_000 { counts[rng.weightedIndex([1, 0, 3])!] += 1 }
        #expect(counts[1] == 0)
        #expect((2300...2700).contains(counts[0]))
        #expect(rng.weightedIndex([0, -1]) == nil)
    }
}

@Suite struct PhysicsTests {
    let config = PhysicsConfig(
        species: SpeciesPhysics(gravity: 900, hopApex: [18, 30], hopDistance: [40, 90], walkSpeed: 0), scale: 2)

    @Test func hopLandsWhereplannedAndPeaksAtApex() {
        for (end, apex) in [(CGPoint(x: 260, y: 500), 40.0), (CGPoint(x: 100, y: 380), 36), (CGPoint(x: 300, y: 620), 60)] {
            let start = CGPoint(x: 200, y: 500)
            let hop = HopPlan(from: start, to: end, apexHeight: apex, gravity: config.gravity)
            let land = hop.position(at: hop.duration)
            #expect(abs(land.x - end.x) < 1e-6 && abs(land.y - end.y) < 1e-6)
            #expect(abs(hop.apex.y - (min(start.y, end.y) - apex)) < 1e-6)
            #expect(hop.samples().allSatisfy { $0.y >= hop.apex.y - 1e-6 })
        }
    }

    @Test func fallReachesTerminalVelocity() {
        var b = Body(position: CGPoint(x: 100, y: 0))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 100_000)
        for _ in 0..<600 { b.stepAirborne(dt: 1.0 / 60, config: config, bounds: bounds) }
        #expect(abs(b.velocity.dy - config.terminalVelocity) < 1e-9, "\(Double(b.velocity.dy) - config.terminalVelocity)")
    }

    @Test func throwVelocityUsesLast100msAndCaps() {
        let samples: [(TimeInterval, CGPoint)] = [
            (0.00, CGPoint(x: 0, y: 0)), (0.85, CGPoint(x: 100, y: 0)),
            (0.90, CGPoint(x: 110, y: 0)), (0.95, CGPoint(x: 120, y: 0)),
        ]
        let v = Body.throwVelocity(samples: samples, at: 0.95, cap: 3000)
        #expect(abs(v.dx - 200) < 1e-6 && v.dy == 0)
        let fast = Body.throwVelocity(samples: [(0, .zero), (0.05, CGPoint(x: 300, y: 400))], at: 0.05, cap: 3000)
        #expect(abs((fast.dx * fast.dx + fast.dy * fast.dy).squareRoot() - 3000) < 1e-6)
    }

    @Test func bouncesOffEdgesWithRestitution() {
        var b = Body(position: CGPoint(x: 5, y: 300), velocity: CGVector(dx: -1000, dy: 0))
        b.stepAirborne(dt: 0.01, config: config, bounds: CGRect(x: 0, y: 25, width: 800, height: 600))
        #expect(abs(b.velocity.dx - 400) < 1e-6)
        #expect(b.position.x >= 0)
    }

    @Test func slideStopsWithinOneSecond() {
        var b = Body(position: CGPoint(x: 100, y: 500), velocity: CGVector(dx: 2400, dy: 0))
        var t = 0.0
        while !b.stepSliding(dt: 1.0 / 60, landingSpeed: 2400, config: config, bounds: CGRect(x: 0, y: 0, width: 10_000, height: 600)) {
            t += 1.0 / 60
        }
        #expect(t <= 1.0)
    }
}
