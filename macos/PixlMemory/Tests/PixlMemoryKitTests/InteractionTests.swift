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
    @Test func settingsRoundTripAndSanitise() throws {
        let d = try #require(UserDefaults(suiteName: "pixl-test-\(UUID())"))
        var s = PixlSettings()
        s.name = "Sir Hops"; s.scale = 3; s.distractingApps = ["Slack"]; s.rememberName(default: "Frogg")
        s.save(d)
        #expect(PixlSettings.load(d) == s)
        s.scale = 7; s.name = "   "; s.names = nil
        s.save(d)
        let loaded = PixlSettings.load(d)
        #expect(loaded.scale == 6 && loaded.name == "Frogg")   // clamped to the largest size
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

@MainActor
@Suite struct SettingsC12Tests {
    func view(_ s: PixlSettings = PixlSettings(), open: MiniMenuView.Section? = nil) -> MiniMenuView {
        let v = MiniMenuView(settings: s, status: ServiceStatus(service: "running", model: "z-ai/glm-5.3-flash", highlights: 12), statusLine: "Frogg is practicing his croak.", open: open)
        v.fit()
        return v
    }

    @Test func itIsLabelledSettingsWithTheNewHierarchy() {
        let v = view()
        #expect(v.accessibilityLabel() == "Settings")
        let labels = v.descendants(of: NSTextField.self).map(\.stringValue)
        for s in ["Settings", "PET", "SIZE", "BEHAVIOR"] { #expect(labels.contains(s), "\(s)") }
        #expect(labels.contains("Frogg is practicing his croak.") && labels.contains("Tree frog, the red-eyed kind"))
        let rows = v.descendants(of: DisclosureRow.self).map { $0.accessibilityLabel() ?? "" }
        #expect(rows == ["Focus", "Shortcuts", "Privacy & Memory", "Energy", "Wallet"])
        #expect(v.descendants(of: DisclosureRow.self).allSatisfy { !$0.open })   // collapsed by default
        #expect(v.descendants(of: ChoiceCard.self).map { $0.accessibilityLabel()?.components(separatedBy: ":").first ?? "" } == ["Calm", "Roam", "Chaos"])
        #expect(v.descendants(of: SizeCard.self).map(\.value) == [2, 3, 4, 5])
        #expect(v.descendants(of: PetCard.self).count == PixlSkins.all.count)
    }

    @Test func changesApplyAtOnce() {
        var got: [PixlSettings] = []
        var app = PixlSettings()
        let v = view()
        v.onEdit = { edit in edit(&app); got.append(app) }
        v.descendants(of: ChoiceCard.self)[2].onPress?()   // Chaos
        #expect(got.last?.behavior == "chaos" && got.last?.roams == true && got.last?.chaos == true)
        v.descendants(of: SizeCard.self)[3].onPress?()     // XL
        #expect(got.last?.scale == 5)
        let toggle = v.descendants(of: PixelToggle.self).first { $0.accessibilityLabel() == "Let me wake them by hovering" }!
        toggle.accessibilityPerformPress()
        #expect(got.last?.hoverWakes == true)
    }

    /// M4: the panel sends only what changed, so a panel opened before an arrival (or a rename
    /// elsewhere) can't write the old values back.
    @Test func editsAreDeltasSoAStalePanelCantUndoOtherChanges() {
        let v = view()   // shows Frogg
        var app = PixlSettings()
        app.name = "Nox"
        app.skin = "cat"
        v.onEdit = { $0(&app) }
        v.descendants(of: SizeCard.self)[3].onPress?()
        #expect(app.scale == 5 && app.name == "Nox" && app.skin == "cat")
        // ending an edit of the name field without changing it sends nothing
        v.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                object: v.descendants(of: NSTextField.self).first { $0.accessibilityLabel() == "Name" }))
        #expect(app.name == "Nox")
    }

    @Test func fromTheMemoryBubbleItOpensAtPrivacyWithTheRealModel() {
        let v = view(open: .privacy)
        let privacy = v.descendants(of: DisclosureRow.self).first { $0.accessibilityLabel() == "Privacy & Memory" }!
        #expect(privacy.open && !privacy.content.isHidden)
        let text = v.descendants(of: NSTextField.self).map(\.stringValue).joined(separator: " ")
        #expect(text.contains("z-ai/glm-5.3-flash") && !text.contains("Llama"))
        #expect(text.contains("12, kept encrypted on this Mac"))
    }

    @Test func slugsAlternateSkinsShowSelected() {
        let before = PixlSkins.currentID
        defer { PixlSkins.currentID = before }
        PixlSkins.currentID = "slugg"
        var s = PixlSettings(); s.skin = "slugg"; s.looks = ["slugg": "racer"]
        let v = view(s)
        let sw = v.descendants(of: SwatchCard.self)
        #expect(sw.map(\.option.id) == ["default", "dapper", "racer"])
        #expect(sw.first { $0.selected }?.option.id == "racer")
        #expect(sw.filter { $0.option.locked == true }.allSatisfy { !$0.isAccessibilityEnabled() })
    }
}
