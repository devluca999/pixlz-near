import Testing
import CoreGraphics
@testable import PixlMemoryKit

/// Slugg's soft body (C11/C13): its own poses on walls and beneath edges, and corner loops that
/// start on the surface it leaves and end on the one it goes onto, head first.
@MainActor
@Suite struct SluggMotionTests {
    var art: FroggArt { PixlSkins.skin("slugg")!.art }

    @Test func everyLoopShipsWithItsAnchorAndShellLayer() {
        for (name, n) in [("crawl", 8), ("climb", 8), ("under", 6), ("wrapin", 8), ("wrapout", 8)] {
            for i in 0..<n {
                let f = art.frames["\(name)_\(i)"]
                #expect(f?.anchor?.count == 2, "\(name)_\(i)")
                #expect(art.frames["\(name)_\(i)_body"] != nil && art.frames["\(name)_\(i)_shell"] != nil, "\(name)_\(i) layers")
                // a loop shares one box, so the foot never jitters
                #expect(f?.w == art.frames["\(name)_0"]?.w && f?.h == art.frames["\(name)_0"]?.h)
            }
        }
        for f in ["vault_0", "vault_1", "vault_2", "seal_0", "seal_1", "seal_2"] { #expect(art.image(f) != nil, "\(f)") }
    }

    @Test func wallsAndTheUndersideUseItsOwnPoses() {
        let has: (String) -> Bool = { self.art.frames[$0]?.anchor != nil }
        // up the right wall: as drawn; down it: head down, wall still on the right
        #expect(SluggMotion.native(frame: "crawl_3", surface: .rightWall, mirrored: true, turns: 0, has: has)! == ("climb_3", ArtTurn(0)))
        #expect(SluggMotion.native(frame: "crawl_3", surface: .rightWall, mirrored: false, turns: 0, has: has)! == ("climb_3", ArtTurn(2, flip: true)))
        #expect(SluggMotion.native(frame: "crawl_3", surface: .leftWall, mirrored: true, turns: 0, has: has)! == ("climb_3", ArtTurn(0, flip: true)))
        // resting on a wall: head up
        #expect(SluggMotion.native(frame: "idle_0", surface: .rightWall, mirrored: false, turns: 0, has: has)! == ("climb_0", ArtTurn(0)))
        // under an edge: the art heads left; heading right flips it
        #expect(SluggMotion.native(frame: "crawl_7", surface: .ceiling, mirrored: true, turns: 0, has: has)! == ("under_1", ArtTurn(0)))
        #expect(SluggMotion.native(frame: "crawl_7", surface: .ceiling, mirrored: false, turns: 0, has: has)! == ("under_1", ArtTurn(0, flip: true)))
        // on the floor only the crawl is anchored; idle draws as before
        #expect(SluggMotion.native(frame: "idle_0", surface: .floor, mirrored: false, turns: 0, has: has) == nil)
        // other Pixls have no such frames: nothing changes for them
        let frogg = PixlSkins.skin("frogg")!.art
        #expect(SluggMotion.native(frame: "crawl_0", surface: .rightWall, mirrored: true, turns: 0, has: { frogg.frames[$0]?.anchor != nil }) == nil)
    }

    /// Every corner: the loop starts on the first leg's line, behind the corner the way it came,
    /// and ends on the second leg's line, ahead the way it goes.
    @Test(arguments: [
        // (a, b): floor → walls, walls → ceiling, ceiling → walls, walls → floor (down), up and over, over and down
        (CrawlLeg(from: .init(x: 100, y: 1000), to: .init(x: 1600, y: 1000), surface: .floor), CrawlLeg(from: .init(x: 1600, y: 1000), to: .init(x: 1600, y: 400), surface: .rightWall)),
        (CrawlLeg(from: .init(x: 900, y: 1000), to: .init(x: 0, y: 1000), surface: .floor), CrawlLeg(from: .init(x: 0, y: 1000), to: .init(x: 0, y: 400), surface: .leftWall)),
        (CrawlLeg(from: .init(x: 1600, y: 900), to: .init(x: 1600, y: 30), surface: .rightWall), CrawlLeg(from: .init(x: 1600, y: 30), to: .init(x: 800, y: 30), surface: .ceiling)),
        (CrawlLeg(from: .init(x: 0, y: 900), to: .init(x: 0, y: 30), surface: .leftWall), CrawlLeg(from: .init(x: 0, y: 30), to: .init(x: 800, y: 30), surface: .ceiling)),
        (CrawlLeg(from: .init(x: 800, y: 30), to: .init(x: 0, y: 30), surface: .ceiling), CrawlLeg(from: .init(x: 0, y: 30), to: .init(x: 0, y: 900), surface: .leftWall)),
        (CrawlLeg(from: .init(x: 800, y: 30), to: .init(x: 1600, y: 30), surface: .ceiling), CrawlLeg(from: .init(x: 1600, y: 30), to: .init(x: 1600, y: 900), surface: .rightWall)),
        (CrawlLeg(from: .init(x: 1600, y: 400), to: .init(x: 1600, y: 1000), surface: .rightWall), CrawlLeg(from: .init(x: 1600, y: 1000), to: .init(x: 900, y: 1000), surface: .floor)),
        (CrawlLeg(from: .init(x: 0, y: 400), to: .init(x: 0, y: 1000), surface: .leftWall), CrawlLeg(from: .init(x: 0, y: 1000), to: .init(x: 900, y: 1000), surface: .floor)),
        (CrawlLeg(from: .init(x: 500, y: 1000), to: .init(x: 500, y: 300), surface: .rightWall), CrawlLeg(from: .init(x: 500, y: 300), to: .init(x: 700, y: 300), surface: .floor)),
        (CrawlLeg(from: .init(x: 900, y: 1000), to: .init(x: 900, y: 300), surface: .leftWall), CrawlLeg(from: .init(x: 900, y: 300), to: .init(x: 700, y: 300), surface: .floor)),
        (CrawlLeg(from: .init(x: 700, y: 300), to: .init(x: 500, y: 300), surface: .floor), CrawlLeg(from: .init(x: 500, y: 300), to: .init(x: 500, y: 1000), surface: .rightWall)),
        (CrawlLeg(from: .init(x: 700, y: 300), to: .init(x: 900, y: 300), surface: .floor), CrawlLeg(from: .init(x: 900, y: 300), to: .init(x: 900, y: 1000), surface: .leftWall)),
    ])
    func cornersStartBehindAndEndAhead(_ legs: (CrawlLeg, CrawlLeg)) throws {
        let (a, b) = legs
        let w = try #require(SluggMotion.wrap(a, b, art: art, scale: 2))
        func sgn(_ v: CGFloat) -> CGFloat { v > 0 ? 1 : v < 0 ? -1 : 0 }
        let dirA = CGPoint(x: sgn(a.to.x - a.from.x), y: sgn(a.to.y - a.from.y))
        let dirB = CGPoint(x: sgn(b.to.x - b.from.x), y: sgn(b.to.y - b.from.y))
        // start: on a's line, before the corner along a
        let s = CGPoint(x: w.start.x - w.at.x, y: w.start.y - w.at.y)
        #expect(abs(dirA.x == 0 ? s.x : s.y) < 4, "start off a's line: \(s)")
        #expect((dirA.x == 0 ? s.y * dirA.y : s.x * dirA.x) < -10, "start not behind the corner: \(s)")
        // end: on b's line, after the corner along b
        let e = CGPoint(x: w.end.x - w.at.x, y: w.end.y - w.at.y)
        #expect(abs(dirB.x == 0 ? e.x : e.y) < 4, "end off b's line: \(e)")
        #expect((dirB.x == 0 ? e.y * dirB.y : e.x * dirB.x) > 10, "end not ahead of the corner: \(e)")
    }

    @Test func theChoreographyWrapsEachCornerOnce() {
        let legs = [CrawlLeg(from: .init(x: 300, y: 1000), to: .init(x: 1000, y: 1000), surface: .floor),
                    CrawlLeg(from: .init(x: 1000, y: 1000), to: .init(x: 1000, y: 400), surface: .rightWall),
                    CrawlLeg(from: .init(x: 1000, y: 400), to: .init(x: 1200, y: 400), surface: .floor)]
        let c = RoamPlanner.choreography(.crawl(legs: legs, dangle: nil), from: .init(x: 300, y: 1000), style: .slider, hanging: nil,
                                         wrap: { SluggMotion.wrap($0, $1, art: art, scale: 2) }, hop: { a, _ in Choreography([.settle(at: a, duration: 0.1)]) })
        var kinds: [String] = []
        for case .wrap(let w, _) in c.segments { kinds.append(String(w.frames[0].prefix(while: { $0 != "_" }))) }
        #expect(kinds == ["wrapin", "wrapout"])
        // no hop anywhere: it crawls the whole way
        #expect(!c.segments.contains { if case .flight = $0 { true } else { false } })
    }
}
