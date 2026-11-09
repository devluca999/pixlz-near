import CoreGraphics
import Testing
@testable import PixlMemoryKit

@Suite struct SluggLapTests {
    let screen = CGRect(x: 0, y: 25, width: 1600, height: 975)
    // a window filling the top of the screen: he used to stop high on the wall here
    func world(foot: CGPoint, surface: Surface = .floor) -> RoamWorld {
        RoamWorld(screens: [screen], active: CGRect(x: 0, y: 25, width: 1600, height: 900), foot: foot, sprite: CGSize(width: 136, height: 62), surface: surface)
    }
    func hop(_ a: CGPoint, _ b: CGPoint) -> Choreography { Choreography([.hold(at: b, frame: "idle_0", mirrored: false, duration: 0.3)]) }

    @Test func aLapGoesUpOverTheTopAndDownTheFarSide() throws {
        var p = RoamPlanner(style: .slider, seed: 3)
        let made = p.outing(named: "lap", world(foot: CGPoint(x: 1300, y: screen.maxY)))
        let o = try #require(made)
        guard case .lap(let legs, _, let end) = o else { Issue.record("not a lap: \(o)"); return }
        #expect(legs.map(\.surface) == [.floor, .rightWall, .ceiling, .leftWall, .floor])
        #expect(legs[2].to.x < 200)                 // across the whole top, upside down
        #expect(end.x < screen.midX && end.y == screen.maxY)
    }

    @Test func fromHighOnAWallHeKeepsGoingOverTheTop() throws {
        var p = RoamPlanner(style: .slider, seed: 5)
        let w = world(foot: CGPoint(x: screen.maxX, y: 200), surface: .rightWall)
        var laps = 0
        for _ in 0..<30 { if case .lap? = p.next(w) { laps += 1 } }
        #expect(laps > 10)
        let made = p.outing(named: "lap", w)
        let o = try #require(made)
        guard case .lap(let legs, _, _) = o else { return }
        #expect(legs.first?.surface == .rightWall && legs.first?.to.y == screen.minY + 31)
    }

    @Test func sometimesHeFallsAndTheShellLandsOnHim() throws {
        var p = RoamPlanner(style: .slider, seed: 11)
        let w = world(foot: CGPoint(x: 1300, y: screen.maxY))
        var falls = 0, clean = 0
        for _ in 0..<60 {
            guard case .lap(let legs, let fallAt, let end)? = p.outing(named: "lap", w) else { continue }
            guard let x = fallAt else { clean += 1; continue }
            falls += 1
            let c = RoamPlanner.choreography(.lap(legs: legs, fallAt: x, end: end), from: w.foot, style: .slider, hanging: nil, hop: hop)
            // drops in his bare body, lies there for the shell, lands, then crawls on to the end
            let drop = c.segments.firstIndex { if case .drop = $0 { return true }; return false }
            #expect(drop != nil)
            if let i = drop, case .drop(let a, let b, let frame, _, _) = c.segments[i] {
                #expect(frame == RoamPlanner.bareBody)
                #expect(abs(a.x - x) < 1 && b.y == screen.maxY)
            }
            let last = c.pose(at: c.duration).pose.foot
            #expect(abs(last.x - end.x) < 0.5 && abs(last.y - end.y) < 0.5, "\(last) vs \(end)")
            #expect(!c.segments.contains { if case .travel(_, _, _, _, .leftWall, _, _, _, _) = $0 { return true }; return false })   // never reached the far wall
        }
        #expect(falls > 10 && clean > 20)           // about a third of laps
    }
}
