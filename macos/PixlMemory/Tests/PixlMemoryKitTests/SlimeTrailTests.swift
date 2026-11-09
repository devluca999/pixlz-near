import Testing
import CoreGraphics
@testable import PixlMemoryKit

/// The slime trail (C11): two pixels thick, solid at the tail and dithering away, gone 2 s after a stop.
@Suite struct SlimeTrailTests {
    let line = (0...58).map { CGPoint(x: 100 + $0, y: 400) }   // one body length along the floor, tail first

    @Test func solidAtTheTailAndThinningAway() {
        let px = SlimeTrail.pixels(path: line, normal: (0, -1), age: 0)
        let base = px.filter { $0.tone == 2 }
        let near = base.filter { $0.x < 118 }.count, far = base.filter { $0.x > 140 }.count
        #expect(near >= 17)          // the first third: every pixel
        #expect(far < near)          // the last third: dithered (on one straight row the 4×4 dither keeps every other pixel)
        // the lighter row sits on the open side (above the floor), only in the first 70 %
        #expect(px.filter { $0.tone == 3 }.allSatisfy { $0.y == 399 && $0.x < 142 })
        // glints near the tail only
        #expect(px.filter { $0.tone == 5 }.allSatisfy { $0.x < 125 })
        #expect(Set(px.map(\.y)).isSubset(of: [399, 400]))
    }

    @Test func stepsDownEveryHalfSecondAndIsGoneByTwo() {
        let counts = (0...4).map { SlimeTrail.pixels(path: line, normal: (0, -1), age: $0).count }
        #expect(counts[0] > counts[1] && counts[1] > counts[2] && counts[2] > counts[3])
        #expect(counts[4] == 0)
        // no glints once it's fading
        #expect(SlimeTrail.pixels(path: line, normal: (0, -1), age: 1).allSatisfy { $0.tone != 5 })
    }

    @Test func onAWallItRunsUpTheWallWithItsLightRowOffIt() {
        let up = (0...40).map { CGPoint(x: 800, y: 600 - $0) }
        let px = SlimeTrail.pixels(path: up, normal: (-1, 0), age: 0)
        #expect(Set(px.map(\.x)).isSubset(of: [799, 800]))
        #expect(px.filter { $0.tone == 3 }.allSatisfy { $0.x == 799 })
    }

    @Test func itIsGreen() {
        for pal in [SlimeTrail.green, SlimeTrail.racer] {
            let c = RGB(hex: pal[2])
            #expect(c.g > c.r && c.g > c.b, "\(pal[2]) is green")
        }
    }
}
