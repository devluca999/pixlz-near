import CoreGraphics
import Testing
@testable import PixlMemoryKit

@Suite struct SluggPathTests {
    let screen = CGRect(x: 0, y: 25, width: 1600, height: 975)        // floor at y 1000
    let sprite = CGSize(width: 128, height: 62)
    let onFloor = CGRect(x: 600, y: 300, width: 600, height: 700)     // stands on the floor
    let floating = CGRect(x: 200, y: 200, width: 400, height: 400)   // doesn't reach it

    func crawls(_ steps: [SluggPath.Step]) -> [CrawlLeg] { steps.compactMap { if case .crawl(let l) = $0 { return l }; return nil } }
    func drops(_ steps: [SluggPath.Step]) -> Int { steps.filter { if case .drop = $0 { return true }; return false }.count }

    @Test func alongTheFloorIsOneCrawl() {
        let p = SluggPath.plan(from: CGPoint(x: 100, y: 1000), to: CGPoint(x: 400, y: 1000), screen: screen, windows: [onFloor], sprite: sprite)
        #expect(crawls(p.steps).map(\.surface) == [.floor])
        #expect(drops(p.steps) == 0)
    }

    @Test func upOntoAWindowByItsSideNeverAHop() {
        let p = SluggPath.plan(from: CGPoint(x: 100, y: 1000), to: CGPoint(x: 900, y: 300), screen: screen, windows: [onFloor], sprite: sprite)
        #expect(crawls(p.steps).map(\.surface) == [.floor, .rightWall, .floor])
        #expect(crawls(p.steps)[1].from.x == onFloor.minX)          // up its real left side
        #expect(p.end == CGPoint(x: 900, y: 300))
        #expect(drops(p.steps) == 0)
    }

    @Test func offAWindowDownItsSide() {
        let p = SluggPath.plan(from: CGPoint(x: 1100, y: 300), to: CGPoint(x: 1450, y: 1000), screen: screen, windows: [onFloor], sprite: sprite)
        #expect(crawls(p.steps).map(\.surface) == [.floor, .leftWall, .floor, .floor])
        #expect(crawls(p.steps)[1].from.x == onFloor.maxX)
        #expect(drops(p.steps) == 0)
    }

    @Test func aFloatingWindowHeLetsGoAtItsBottomCornerAndCantClimbIt() {
        let off = SluggPath.plan(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 900, y: 1000), screen: screen, windows: [floating], sprite: sprite)
        #expect(drops(off.steps) == 1)
        if case .drop(let a, _)? = off.steps.first(where: { if case .drop = $0 { return true }; return false }) { #expect(a.y == floating.maxY) }
        let on = SluggPath.plan(from: CGPoint(x: 900, y: 1000), to: CGPoint(x: 400, y: 200), screen: screen, windows: [floating], sprite: sprite)
        #expect(on.end == CGPoint(x: 400, y: 1000))                   // waits on the floor below it
        #expect(drops(on.steps) == 0)
    }

    @Test func fromAWallHeCrawlsDownFirst() {
        let p = SluggPath.plan(from: CGPoint(x: 1600, y: 400), to: CGPoint(x: 800, y: 1000), screen: screen, windows: [], sprite: sprite, surface: .rightWall)
        #expect(crawls(p.steps).first?.surface == .rightWall)
        #expect(drops(p.steps) == 0)
    }

    @Test func escapingHeHeadsForTheNearerSide() {
        var w = RoamWorld(screens: [screen], foot: CGPoint(x: 300, y: 1000), sprite: sprite)
        w.displays = [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
        let wall = w.nearerWall()!
        #expect(wall.right == false && wall.x == 0)
        let legs = SluggPath.escape(from: w.foot, wall: wall, screen: screen, sprite: sprite, height: 260)
        #expect(legs.map(\.surface) == [.floor, .leftWall])
        #expect(legs[0].to.x < 300 && legs[1].to.y < legs[1].from.y)
    }

    @Test func theSeamBetweenTwoDisplaysIsntAWall() {
        var w = RoamWorld(screens: [screen], foot: CGPoint(x: 1400, y: 1000), sprite: sprite)
        w.displays = [CGRect(x: 0, y: 0, width: 1600, height: 1000), CGRect(x: 1600, y: 0, width: 1920, height: 1080)]
        #expect(w.wallX(right: true) == nil)
        #expect(w.nearerWall()?.right == false)                      // so he goes left, to a real edge
        // the Dock on the left: the display's own edge, not the Dock's
        var d = RoamWorld(screens: [CGRect(x: 48, y: 25, width: 1552, height: 975)], foot: CGPoint(x: 300, y: 1000), sprite: sprite)
        d.displays = [CGRect(x: 0, y: 0, width: 1600, height: 1000)]
        #expect(d.wallX(right: false) == 0)
    }
}
