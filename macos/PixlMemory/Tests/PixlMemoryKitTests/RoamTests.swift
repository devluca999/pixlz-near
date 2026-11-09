import CoreGraphics
import Testing
@testable import PixlMemoryKit
import PixlzCore

@Suite struct RoamTests {
    // a 1470×920 laptop screen (below the menu bar, above the Dock)
    let screen = CGRect(x: 0, y: 30, width: 1470, height: 890)
    let editor = CGRect(x: 300, y: 300, width: 800, height: 500)    // the window you're using
    let caret = CGRect(x: 640, y: 520, width: 2, height: 18)
    let sprite = CGSize(width: 140, height: 120)

    func world(foot: CGPoint? = nil, code: Bool = false, hanging: CGPoint? = nil) -> RoamWorld {
        RoamWorld(screens: [screen], active: editor, others: [CGRect(x: 1150, y: 200, width: 300, height: 400)],
                  folders: [CGRect(x: 60, y: 120, width: 64, height: 64), CGRect(x: 60, y: 240, width: 64, height: 64)],
                  avoid: [caret], cursor: CGPoint(x: 900, y: 650), foot: foot ?? CGPoint(x: 700, y: 300),
                  sprite: sprite, codeContext: code, hanging: hanging)
    }

    func hop(_ a: CGPoint, _ b: CGPoint) -> Choreography {
        Choreography([.hold(at: a, frame: "move_0", mirrored: false, duration: 0.1), .settle(at: b, duration: 0.2)])
    }

    @Test(arguments: RoamStyle.allCases)
    func everyStyleFindsOutingsThatKeepClearOfYourWork(_ style: RoamStyle) {
        var p = RoamPlanner(style: style, seed: 42)
        var found = 0
        for _ in 0..<60 {
            guard let o = p.next(world()) else { continue }
            found += 1
            let end = RoamPlanner.choreography(o, from: world().foot, style: style, hanging: nil, hop: hop)
            let pose = end.pose(at: end.duration).pose
            let body = RoamPlanner.body(foot: pose.foot, sprite: sprite, surface: pose.surface).insetBy(dx: 6, dy: 6)
            #expect(screen.insetBy(dx: -2, dy: -2).contains(body), "\(style) \(o.name) ends off screen")
            #expect(!caret.insetBy(dx: -16, dy: -16).intersects(body), "\(style) \(o.name) covers the caret")
            #expect(!editor.insetBy(dx: 0, dy: 4).intersects(body), "\(style) \(o.name) sits on the window's content")
        }
        #expect(found > 40)
    }

    @Test func silkWalksToTheSideClimbsCrawlsTheCeilingAndDrops() {
        var p = RoamPlanner(style: .crawler, seed: 7)
        let w = world(foot: CGPoint(x: 1000, y: screen.maxY))   // on the floor, right half
        let o = p.crawlTour(w)
        guard case .crawl(let legs, let dangle)? = o else { Issue.record("no crawl: \(String(describing: o))"); return }
        #expect(legs.map(\.surface) == [.floor, .rightWall, .ceiling])
        #expect(legs[1].from.x == screen.maxX && legs[1].to.y < legs[1].from.y)   // up the right wall
        #expect(legs[2].to.y == screen.minY)                                      // along the top
        #expect((dangle ?? 0) > 0)
        let c = RoamPlanner.choreography(o!, from: w.foot, style: .crawler, hanging: nil, hop: hop)
        let end = c.pose(at: c.duration).pose
        #expect(end.surface == .hanging && end.thread?.y == screen.minY)
        #expect(end.foot.y + sprite.height <= editor.minY)                        // hangs above your window
        // mid-climb the art is turned to the wall
        #expect((0..<Int(c.duration * 10)).contains { c.pose(at: Double($0) / 10).pose.surface == .rightWall })
    }

    @Test(arguments: RoamStyle.allCases)
    func withAMaximizedWindowItStillGetsAboutAlongTheBottomEdge(_ style: RoamStyle) {
        var w = world(foot: CGPoint(x: 1300, y: screen.maxY))
        w.active = screen; w.others = []; w.folders = []
        w.avoid = [CGRect(x: 200, y: 880, width: 2, height: 18)]   // the prompt, bottom left
        var p = RoamPlanner(style: style, seed: 5)
        let outings = (0..<40).compactMap { _ in p.next(w) }
        #expect(!outings.isEmpty)
        for o in outings {
            let c = RoamPlanner.choreography(o, from: w.foot, style: style, hanging: nil, hop: hop)
            let end = c.pose(at: c.duration).pose
            let body = RoamPlanner.body(foot: end.foot, sprite: sprite, surface: end.surface)
            #expect(abs(body.midX - 201) > 260 || abs(body.midY - 889) > 220, "\(style) \(o.name) sits by the prompt")
        }
    }

    @Test func silkNeverHangsOverAWindowThatFillsTheTop() {
        let tall = CGRect(x: 0, y: screen.minY, width: 1100, height: screen.height)   // a terminal, top to bottom, left side
        for seed in 0..<30 {
            var p = RoamPlanner(style: .crawler, seed: UInt64(seed))
            var w = world(foot: CGPoint(x: 1300, y: screen.maxY))
            w.active = tall; w.avoid = []
            guard let o = p.crawlTour(w) else { continue }
            let c = RoamPlanner.choreography(o, from: w.foot, style: .crawler, hanging: nil, hop: hop)
            let end = c.pose(at: c.duration).pose
            let body = RoamPlanner.body(foot: end.foot, sprite: sprite, surface: .hanging).insetBy(dx: 6, dy: 6)
            #expect(!tall.insetBy(dx: 0, dy: 4).intersects(body), "seed \(seed) hangs over the terminal at \(end.foot)")
        }
    }

    @Test func withNoRoomToHangSilkRestsHighOnTheWallThenClimbsDown() {
        var w = world(foot: CGPoint(x: 1300, y: screen.maxY))
        w.active = screen.insetBy(dx: 0, dy: 0); w.avoid = [CGRect(x: 200, y: 880, width: 2, height: 18)]
        var p = RoamPlanner(style: .crawler, seed: 2)
        guard case .crawl(let legs, nil)? = p.crawlTour(w) else { Issue.record("no wall climb"); return }
        #expect(legs.last?.surface == .rightWall && legs.last!.to.y < screen.minY + 300)
        let c = RoamPlanner.choreography(.crawl(legs: legs, dangle: nil), from: w.foot, style: .crawler, hanging: nil, hop: hop)
        let end = c.pose(at: c.duration).pose
        #expect(end.surface == .rightWall)
        // next time: down the wall and off along the floor
        w.foot = end.foot; w.surface = .rightWall
        var outing: Outing?
        for _ in 0..<10 { outing = p.next(w); if case .crawl? = outing { break } }
        guard case .crawl(let down, _)? = outing else { Issue.record("didn't climb down"); return }
        #expect(down.first?.surface == .rightWall && down.last?.surface == .floor)
    }

    @Test func hangingSilkClimbsUpMovesAndDropsAgain() {
        let anchor = CGPoint(x: 400, y: screen.minY)
        var p = RoamPlanner(style: .crawler, seed: 3)
        let w = world(foot: CGPoint(x: 400, y: screen.minY + 80), hanging: anchor)
        var outing: Outing?
        for _ in 0..<20 { if case .climbAndMove? = (outing = p.next(w), outing).1 { break } }
        guard case .climbAndMove(let to, _)? = outing else { Issue.record("no climb"); return }
        let c = RoamPlanner.choreography(outing!, from: w.foot, style: .crawler, hanging: anchor, hop: hop)
        #expect(c.pose(at: 0.01).pose.thread == anchor)                // starts on the old thread
        #expect(abs(to.x - anchor.x) > 100)
        #expect(c.pose(at: c.duration).pose.thread == to)              // ends on a new one
    }

    @Test func inACodeAppItReadsAlongMoreOften() {
        func glances(code: Bool) -> Int {
            var p = RoamPlanner(style: .hopper, seed: 11)
            return (0..<300).filter { _ in if case .glance? = p.next(world(code: code)) { return true } else { return false } }.count
        }
        #expect(glances(code: true) > glances(code: false) * 3 / 2)
    }

    @Test func readingAlongSitsOnTheWindowTopBesideTheCaretLookingAtIt() {
        var p = RoamPlanner(style: .hopper, seed: 1)
        guard case .glance(let at, let lookLeft)? = p.glanceNow(world()) else { Issue.record("no glance"); return }
        #expect(at.y == editor.minY)
        #expect(abs(at.x - caret.midX) < sprite.width && abs(at.x - caret.midX) > 20)
        #expect(lookLeft == (caret.midX < at.x))
    }

    @Test func movesTurnTheArtAndFadeTheGhost() {
        let c = Choreography([
            .travel(from: .zero, to: CGPoint(x: 100, y: 0), frames: ["a", "b"], fps: 4, surface: .ceiling, mirrored: false, bob: 0, alpha: 0.7, duration: 1),
            .dangle(anchor: CGPoint(x: 100, y: 0), from: 0, to: 60, duration: 1),
        ])
        #expect(c.pose(at: 0.1).pose.frame == "a" && c.pose(at: 0.3).pose.frame == "b")
        #expect(c.pose(at: 0.5).pose.surface == .ceiling && abs(c.pose(at: 0.5).pose.alpha - 0.7) < 0.01)
        let hang = c.pose(at: 2).pose
        #expect(hang.thread == CGPoint(x: 100, y: 0) && hang.foot.y == 60)
        #expect(Surface.rightWall.bodyCenter(foot: CGPoint(x: 10, y: 50), height: 20) == CGPoint(x: 0, y: 50))
        #expect(Surface.ceiling.bodyCenter(foot: CGPoint(x: 10, y: 50), height: 20) == CGPoint(x: 10, y: 60))
    }

    @Test func eachPixlHasItsOwnStyle() {
        #expect(RoamStyle.of(id: "widow", movement: "hop") == .crawler)
        #expect(RoamStyle.of(id: "ghost", movement: "float") == .drifter)
        #expect(RoamStyle.of(id: "cat", movement: "hop") == .prowler)
        #expect(RoamStyle.of(id: "shiba", movement: "hop") == .trotter)
        #expect(RoamStyle.of(id: "frogg", movement: "hop") == .hopper)
    }
}
