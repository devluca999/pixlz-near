import CoreGraphics
import Testing
@testable import PixlMemoryKit

@Suite struct LaserChaseTests {
    let screen = CGRect(x: 0, y: 0, width: 1500, height: 900)

    func run(_ g: inout LaserChase, from t0: Double, seconds: Double, dot: (Double) -> CGPoint) -> [LaserChase.Event] {
        var events: [LaserChase.Event] = []
        var t = t0
        while t < t0 + seconds {
            t += 1.0 / 60
            if let e = g.step(dt: 1.0 / 60, at: t, dot: dot(t)) { events.append(e) }
        }
        return events
    }

    @Test func aStillDotGetsCaughtQuickly() {
        var g = LaserChase(cat: CGPoint(x: 100, y: 800), at: 0, bounds: screen)
        let events = run(&g, from: 0, seconds: 2) { _ in CGPoint(x: 700, y: 500) }
        #expect(events.contains(.pounced) && events.contains(.caught(1)))
    }

    @Test func aDotThatKeepsMovingFastIsHardToCatch() {
        var g = LaserChase(cat: CGPoint(x: 750, y: 450), at: 0, bounds: screen)
        // a quick hand: a big circle at ~800 pt/s
        _ = run(&g, from: 0, seconds: 10) { t in CGPoint(x: 750 + 400 * cos(t * 2), y: 450 + 400 * sin(t * 2)) }
        var still = LaserChase(cat: CGPoint(x: 750, y: 450), at: 0, bounds: screen)
        _ = run(&still, from: 0, seconds: 10) { _ in CGPoint(x: 300, y: 300) }
        #expect(g.catches < still.catches)
    }

    @Test func itCreepsWhenCloseAndRestsAfterACatch() {
        var g = LaserChase(cat: CGPoint(x: 0, y: 0), at: 0, bounds: screen)
        _ = g.step(dt: 1.0 / 60, at: 0.01, dot: CGPoint(x: 150, y: 0))
        #expect(g.phase == .stalk)
        _ = run(&g, from: 0.01, seconds: 1) { _ in CGPoint(x: 150, y: 0) }
        #expect(g.catches == 1)
    }

    @Test func itEndsAfterTwentySecondsAndStaysOnScreen() {
        var g = LaserChase(cat: CGPoint(x: 10, y: 10), at: 0, bounds: screen)
        let events = run(&g, from: 0, seconds: 21) { _ in CGPoint(x: -500, y: 2000) }
        #expect(events.last == .over(catches: g.catches) && g.finished)
        #expect(screen.contains(g.cat))
    }
}
