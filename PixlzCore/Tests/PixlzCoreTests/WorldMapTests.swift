import CoreGraphics
import Foundation
import Testing
@testable import PixlzCore

/// 1440×900 display, 25 pt menu bar, Dock at the bottom from x 400 to 1040, 70 pt tall.
let mainDisplay = DisplayInfo(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 805),
    dockFrame: CGRect(x: 400, y: 830, width: 640, height: 70))

let frogg = try! PixlManifest.load(from: repoAssets.appendingPathComponent("frogg/pixl.json"))
let frogg2x = PixlGeometry(manifest: frogg, scale: 2)

/// A (front) 100–700 × 200–600; B behind 400–1100 × 100–600; C behind both, fully covered by A.
let layered = [
    WindowInfo(id: 1, frame: CGRect(x: 100, y: 200, width: 600, height: 400)),
    WindowInfo(id: 2, frame: CGRect(x: 400, y: 100, width: 700, height: 500)),
    WindowInfo(id: 3, frame: CGRect(x: 500, y: 300, width: 200, height: 100)),
]

@Suite struct WorldMapTests {
    @Test func surfacesFromLayeredWindows() {
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: layered))
        #expect(map.platform(.ground(display: 1))?.intervals == [0...400, 1040...1440])
        #expect(map.platform(.ground(display: 1))?.y == 900)
        #expect(map.platform(.dockTop(display: 1))?.y == 830)
        #expect(map.platform(.menuBarUnderside(display: 1))?.y == 25)
        #expect(map.platform(.windowTop(window: 1))?.intervals == [100...700])
        #expect(map.platform(.windowTop(window: 2))?.intervals == [400...1100])
        #expect(map.platform(.windowTop(window: 3)) == nil)
        let bLeft = map.sides.first { $0.window == 2 && $0.side == .left }
        #expect(bLeft?.intervals == [100...200])
    }

    @Test func partiallyCoveredTopSplits() {
        let windows = [
            WindowInfo(id: 1, frame: CGRect(x: 300, y: 150, width: 200, height: 300)),
            WindowInfo(id: 2, frame: CGRect(x: 100, y: 200, width: 800, height: 300)),
        ]
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: windows))
        #expect(map.platform(.windowTop(window: 2))?.intervals == [100...300, 500...900])
    }

    @Test func groundOnlyModeSkipsWindows() {
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: layered, groundOnly: true))
        #expect(map.platforms.map(\.kind).count == 3)
        #expect(map.sides.isEmpty)
    }

    @Test func landingFindsFirstSurfaceCrossed() {
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: layered))
        #expect(map.landing(from: CGPoint(x: 300, y: 150), to: CGPoint(x: 300, y: 250))?.surface == .windowTop(window: 1))
        #expect(map.landing(from: CGPoint(x: 300, y: 210), to: CGPoint(x: 300, y: 250)) == nil)
        #expect(map.firstPlatformBelow(CGPoint(x: 1200, y: 50))?.surface == .ground(display: 1))
        #expect(map.firstPlatformBelow(CGPoint(x: 700, y: 650))?.surface == .dockTop(display: 1))
        #expect(map.firstPlatformBelow(CGPoint(x: 800, y: 50))?.surface == .windowTop(window: 2))
        // The menu bar underside is for hanging, never for landing.
        #expect(map.landing(from: CGPoint(x: 300, y: 0), to: CGPoint(x: 300, y: 100)) == nil)
    }

    @Test func platformVanishes() {
        let before = WorldMap(WorldInput(displays: [mainDisplay], windows: layered))
        let spot = Spot(surface: .windowTop(window: 2), point: CGPoint(x: 900, y: 100))
        #expect(before.supports(spot))
        let after = WorldMap(WorldInput(displays: [mainDisplay], windows: Array(layered.prefix(1))))
        #expect(!after.supports(spot))
    }

    @Test func keepOutAllowsOnlyTheTopBand() {
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: layered, focusedWindowID: 1))
        #expect(map.isLegal(hitbox: frogg2x.hitbox(at: CGPoint(x: 300, y: 200))))   // perched on its title bar
        #expect(!map.isLegal(hitbox: frogg2x.hitbox(at: CGPoint(x: 300, y: 203))))
        #expect(!map.isLegal(hitbox: frogg2x.hitbox(at: CGPoint(x: 300, y: 400))))
        #expect(map.isLegal(hitbox: frogg2x.hitbox(at: CGPoint(x: 1300, y: 900))))
    }

    @Test func escapeGoesToNearestLegalSpot() throws {
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: layered, focusedWindowID: 1))
        let inside = CGPoint(x: 150, y: 400)
        let spot = try #require(map.nearestLegalSpot(to: inside, geometry: frogg2x))
        #expect(map.isLegal(hitbox: frogg2x.hitbox(at: spot.point)))
        #expect(spot.surface == .windowTop(window: 1))  // 200 pt up beats 500 pt down
    }

    @Test func noEscapeWhenFocusedWindowFillsTheScreen() {
        let big = WindowInfo(id: 9, frame: mainDisplay.visibleFrame)
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: [big], focusedWindowID: 9))
        #expect(map.nearestLegalSpot(to: CGPoint(x: 700, y: 500), geometry: frogg2x) == nil)
    }

    @Test func hopTargetsRespectRangeRiseAndKeepOut() {
        let low = WindowInfo(id: 4, frame: CGRect(x: 200, y: 760, width: 150, height: 100))
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: [low]))
        let start = Spot(surface: .ground(display: 1), point: CGPoint(x: 120, y: 900))
        let targets = map.hopTargets(from: start, geometry: frogg2x)
        let kinds = Set(targets.map(\.0))
        #expect(kinds.contains(.windowTop(window: 4)))       // 140 pt up, within 180
        #expect(!kinds.contains(.dockTop(display: 1)))       // 280 pt away
        let ground = targets.first { $0.0 == .ground(display: 1) }?.1
        #expect(ground == 0...300)

        // The same window, focused: its top band is allowed, so it's still reachable,
        // but a hop across its body to the ground on the far side is not.
        let wide = WindowInfo(id: 5, frame: CGRect(x: 150, y: 600, width: 200, height: 300))
        let focused = WorldMap(WorldInput(displays: [mainDisplay], windows: [wide], focusedWindowID: 5))
        let far = focused.arcIsClear(from: CGPoint(x: 120, y: 900), to: CGPoint(x: 380, y: 900), geometry: frogg2x, bounds: mainDisplay.frame)
        #expect(!far)
    }

    @Test func perchRouteClimbsAVisibleSide() throws {
        let w = WindowInfo(id: 5, frame: CGRect(x: 300, y: 500, width: 400, height: 300))
        let map = WorldMap(WorldInput(displays: [mainDisplay], windows: [w]))
        let routes = map.perchRoutes(from: Spot(surface: .ground(display: 1), point: CGPoint(x: 250, y: 900)), geometry: frogg2x)
        let left = try #require(routes.first { $0.side == .left })
        #expect(left.window == 5)
        #expect(left.top == CGPoint(x: 301, y: 500))
        #expect((500...800).contains(left.cling.y))

        var walker = frogg2x
        walker.manifest.sticky = false
        #expect(map.perchRoutes(from: Spot(surface: .ground(display: 1), point: CGPoint(x: 250, y: 900)), geometry: walker).isEmpty)
    }

    @Test func rebuildIsUnder50msWith200Windows() {
        var rng = SeededRandom(seed: 1)
        let windows = (0..<200).map { i in
            WindowInfo(id: i, frame: CGRect(
                x: .random(in: 0...1200, using: &rng), y: .random(in: 25...700, using: &rng),
                width: .random(in: 200...900, using: &rng), height: .random(in: 150...600, using: &rng)))
        }
        let input = WorldInput(displays: [mainDisplay], windows: windows, focusedWindowID: 3)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = WorldMap(input) }
        #expect(elapsed < .milliseconds(50), "\(elapsed)")
    }
}
