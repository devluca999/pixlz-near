import CoreGraphics
import Testing
@testable import PixlMemoryKit

/// Slugg is never on nothing: whatever he's on (a window, a screen edge) has to still be there.
@Suite struct SluggSupportTests {
    let screen = CGRect(x: 0, y: 25, width: 1600, height: 975)        // floor at y 1000, top at 25
    let win = CGRect(x: 600, y: 300, width: 600, height: 400)          // top 300, bottom 700, sides 600 and 1200

    func ok(_ foot: CGPoint, _ s: Surface, windows: [CGRect]? = nil) -> Bool {
        SluggSupport.supported(foot: foot, surface: s, screens: [screen], windows: windows ?? [win])
    }

    @Test func theFloorAndAWindowTopHoldHim() {
        #expect(ok(CGPoint(x: 100, y: 1000), .floor))
        #expect(ok(CGPoint(x: 900, y: 300), .floor))
    }

    @Test func aWindowTopThatMovedOrClosedDoesNot() {
        #expect(!ok(CGPoint(x: 900, y: 300), .floor, windows: []))                                   // closed
        #expect(!ok(CGPoint(x: 900, y: 300), .floor, windows: [win.offsetBy(dx: 0, dy: 120)]))       // moved down
        #expect(!ok(CGPoint(x: 1400, y: 300), .floor))                                               // past its end
    }

    @Test func wallsAreAWindowsSideOrTheScreensEdge() {
        #expect(ok(CGPoint(x: 600, y: 500), .rightWall))          // the window on his right: its left side
        #expect(ok(CGPoint(x: 1200, y: 500), .leftWall))          // its right side
        #expect(ok(CGPoint(x: 1600, y: 500), .rightWall))         // the screen's right edge
        #expect(ok(CGPoint(x: 0, y: 500), .leftWall))
        #expect(!ok(CGPoint(x: 600, y: 900), .rightWall))         // below the window's bottom: nothing there
        #expect(!ok(CGPoint(x: 600, y: 500), .rightWall, windows: [win.offsetBy(dx: 200, dy: 0)]))
    }

    @Test func theCeilingIsTheScreensTopOrAWindowsUnderside() {
        #expect(ok(CGPoint(x: 800, y: 25), .ceiling))
        #expect(ok(CGPoint(x: 800, y: 700), .ceiling))
        #expect(!ok(CGPoint(x: 800, y: 400), .ceiling))
    }

    @Test func aDropOrACornerIsNotASurfaceToCheck() {
        let c = Choreography([
            .travel(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), frames: ["crawl_0"], fps: 7, surface: .floor, mirrored: false, bob: 0, alpha: 1, duration: 1),
            .drop(from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 200), frame: "crawl_0", mirrored: false, duration: 0.5),
        ])
        #expect(c.crawlSurface(at: 0.5) == .floor)
        #expect(c.crawlSurface(at: 1.2) == nil)
        #expect(c.crawlSurface(at: 9) == nil)
    }

    /// Every crawl pose of a real path, with his real corner loops, counts as supported: the
    /// watch must never make him drop on an ordinary crawl.
    @MainActor @Test func ordinaryPathsAreSupportedAllTheWay() {
        let art = PixlSkins.skin("slugg")!.art, scale: CGFloat = 2
        let sprite = CGSize(width: art.size("idle_0").width * scale, height: art.size("idle_0").height * scale)
        let floating = CGRect(x: 200, y: 200, width: 400, height: 300)
        let cases: [(CGPoint, CGPoint, Surface)] = [
            (CGPoint(x: 100, y: 1000), CGPoint(x: 900, y: 300), .floor),     // up onto a window
            (CGPoint(x: 900, y: 300), CGPoint(x: 1450, y: 1000), .floor),    // off it, down its side
            (CGPoint(x: 900, y: 300), CGPoint(x: 100, y: 1000), .floor),     // off it the other way
            (CGPoint(x: 400, y: 200), CGPoint(x: 1400, y: 1000), .floor),    // off one that doesn't reach the floor
            (CGPoint(x: 1600, y: 600), CGPoint(x: 300, y: 1000), .rightWall),// down the screen's edge first
        ]
        for (a, b, surface) in cases {
            let p = SluggPath.plan(from: a, to: b, screen: screen, windows: [win, floating], sprite: sprite, surface: surface)
            let c = SluggPath.choreography(p.steps, from: a, gait: nil, wrap: { SluggMotion.wrap($0, $1, art: art, scale: scale) })
            var t = 0.0, bad: [String] = []
            while t < c.duration {
                if let s = c.crawlSurface(at: t) {
                    let f = c.pose(at: t).pose.foot
                    if !SluggSupport.supported(foot: f, surface: s, screens: [screen], windows: [win, floating]) { bad.append("\(s)@\(Int(f.x)),\(Int(f.y))") }
                }
                t += 0.05
            }
            #expect(bad.isEmpty, "\(a) → \(b): unsupported crawl poses \(bad.prefix(5))")
        }
    }
}
