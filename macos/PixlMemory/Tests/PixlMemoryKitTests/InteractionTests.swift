import AppKit
import Foundation
import Testing
@testable import PixlMemoryKit

struct GestureTests {
    @Test func quickStillPressIsAClick() {
        let g = PointerGesture(at: CGPoint(x: 100, y: 100), time: 10)
        #expect(g.isClick(releasedAt: CGPoint(x: 102, y: 101), time: 10.2))
        #expect(g.isClick(releasedAt: CGPoint(x: 103, y: 102), time: 10.45))   // a slow trackpad press still counts
        #expect(!g.isClick(releasedAt: CGPoint(x: 102, y: 101), time: 10.6))   // that's a long press (menu)
    }

    @Test func movingFourPointsStartsAGrab() {
        var g = PointerGesture(at: .zero, time: 0)
        let r1 = g.moved(to: CGPoint(x: 4, y: 3))   // 5 pt of jitter: still a press
        #expect(!r1)
        let r2 = g.moved(to: CGPoint(x: 5, y: 4))
        #expect(r2)
        let r3 = g.moved(to: CGPoint(x: 30, y: 30))
        #expect(!r3)  // only reports the transition once
        #expect(g.dragging && !g.isClick(releasedAt: .zero, time: 0.1))
    }

    @Test func threePokesInFourSecondsAnnoyFrogg() {
        var c = PokeCounter()
        // the third poke within 4 s annoys; the counter then resets; old pokes expire
        let results = [0, 1, 2, 2.5, 10, 15].map { c.poke(at: $0) }
        #expect(results == [false, false, true, false, false, false])
    }

    @Test func slotAnimationsUseManifestHolds() {
        #expect(SlotAnimation.poke.duration == 12.0 / 12)
        let s = SlotAnimation.signature.schedule
        #expect(s.map(\.0) == ["signature_0", "signature_1", "signature_2"])
        #expect(s.map(\.1) == [0, 4.0 / 12, 6.0 / 12])
    }
}

struct ThrowTests {
    let screen = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 25, width: 1512, height: 870))

    func fly(_ f: inout ThrowFlight, max steps: Int = 2000) -> CGPoint? {
        for _ in 0..<steps { if let p = f.step(dt: 1.0 / 60) { return p } }
        return nil
    }

    @Test func dropsOntoTheWindowBelow() throws {
        let window = CGRect(x: 400, y: 500, width: 600, height: 300)
        var f = ThrowFlight(foot: CGPoint(x: 700, y: 200), velocity: .zero, scale: 2, screens: [screen], window: window, halfWidth: 70)
        let p = try #require(fly(&f))
        #expect(p.y == window.minY && p.x == 700)
    }

    @Test func missesTheWindowAndLandsOnTheGround() throws {
        let window = CGRect(x: 400, y: 500, width: 600, height: 300)
        var f = ThrowFlight(foot: CGPoint(x: 200, y: 200), velocity: .zero, scale: 2, screens: [screen], window: window, halfWidth: 70)
        let p = try #require(fly(&f))
        #expect(p.y == screen.visible.maxY)
    }

    @Test func aHardThrowBouncesOffTheEdgeAndStaysOnScreen() throws {
        var f = ThrowFlight(foot: CGPoint(x: 1300, y: 600), velocity: CGVector(dx: 9000, dy: -800), scale: 2,
                            screens: [screen], window: nil, halfWidth: 70)
        let p = try #require(fly(&f))
        #expect(p.x <= screen.visible.maxX - 70 && p.x >= 70)
        #expect(p.y == screen.visible.maxY)
    }
}

@MainActor
struct MenuTests {
    @Test func radialButtonsGoClockwiseFromTheTop() {
        let size = RadialMenuView.size
        let c = RadialMenuView.centers(count: 6, in: size)
        #expect(c[0].x == (size.width / 2).rounded() && c[0].y < size.height / 2)  // 12 o'clock (flipped view)
        #expect(c[1].x > size.width / 2 && c[1].y < size.height / 2)               // then right
        #expect(c[3].y > size.height / 2)                                          // 6 o'clock
        let view = RadialMenuView(items: (0..<6).map { RadialMenuView.Item(id: "\($0)", title: "\($0)", glyph: "•") })
        #expect(view.index(at: c[4]) == 4)
        #expect(view.index(at: NSPoint(x: size.width / 2, y: size.height / 2)) == nil)  // Frogg's spot is click-through
    }

    @Test func settingsRoundTripAndSanitise() throws {
        let d = try #require(UserDefaults(suiteName: "pixl-test-\(UUID())"))
        var s = PixlSettings()
        s.name = "Sir Hops"; s.scale = 3; s.distractingApps = ["Slack"]
        s.save(d)
        #expect(PixlSettings.load(d) == s)
        s.scale = 7; s.name = "   "
        s.save(d)
        let loaded = PixlSettings.load(d)
        #expect(loaded.scale == 2 && loaded.name == "Frogg")
    }

    @Test func miniMenuLaysOut() {
        let v = MiniMenuView(settings: PixlSettings(), status: ServiceStatus(service: "running", model: "z-ai/glm-5.3-flash",
                                                                            wallet: "not set up"))
        v.fit()
        #expect(v.frame.width == MiniMenuView.width && v.frame.height > 300)
    }

    @Test func grabFramesHangFromTheirPin() throws {
        let art = FroggArt.shared
        for name in ["grab_0", "grab_1"] {
            let f = try #require(art.frames[name])
            let pin = try #require(f.pin)
            #expect(art.isOpaque(name, x: pin[0], y: pin[1]), "\(name) pin isn't on the toe pad")
            let v = FroggView(scale: 2, frameName: name)
            let p = try #require(v.pinPoint(name))
            #expect(v.hitsArt(at: p))
        }
        for name in ["signature_0", "signature_1", "signature_2", "rest_0", "rest_2", "grab_2", "perch_2"] {
            #expect(art.image(name) != nil)
        }
    }
}

@MainActor
struct AppearanceTests {
    /// The cream-and-ink panels must stay light: in dark mode, system controls would
    /// otherwise draw white text on the cream card.
    @Test func panelsForceTheLightAppearance() {
        let mini = MiniMenuView(settings: PixlSettings(), status: ServiceStatus(service: "running"))
        #expect(mini.appearance?.name == .aqua)
        let r = PolishView(.error(.serviceDown, app: nil))
        #expect(r.appearance?.name == .aqua)
    }
}
