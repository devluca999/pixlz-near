import AppKit
import Foundation
import Testing
@testable import PixlMemoryKit

@MainActor
@Suite struct PixlCopyTests {
    @Test func theGrumbleMatchesThePixl() {
        #expect(PixlSkins.busyLine(name: "Nox", busy: nil, species: "Black cat") == "Hey! Nox is busy being a black cat.")
        #expect(PixlSkins.busyLine(name: "Frogg", busy: nil, species: "Red-eyed tree frog") == "Hey! Frogg is busy being a red-eyed tree frog.")
        #expect(PixlSkins.busyLine(name: "Boo", busy: nil, species: "Bedsheet ghost") == "Hey! Boo is busy being a bedsheet ghost.")
        #expect(PixlSkins.busyLine(name: "Ink", busy: nil, species: "Inky octopus · deep sea").hasSuffix("being an inky octopus."))
        for skin in PixlSkins.all {   // no Pixl but Frogg calls itself a frog
            let line = PixlSkins.busyLine(name: skin.manifest.name, busy: skin.manifest.ui?.busy, species: skin.manifest.species)
            #expect(skin.id == "frogg" || !line.lowercased().contains("frog"), "\(skin.id): \(line)")
        }
    }

    @Test func eachPixlHasItsOwnGrumble() {
        let boo = PixlSkins.skin("ghost")!.manifest
        #expect(PixlSkins.busyLine(name: boo.name, busy: boo.ui?.busy, species: boo.species) == "Hey! Boo is busy being ghastly.")
        let lines = Set(PixlSkins.all.map { $0.manifest.ui?.busy ?? "" })
        #expect(lines.count == PixlSkins.all.count && !lines.contains(""))
    }

    @Test func theNameFollowsTheCurrentPixl() {
        let (id, name) = (PixlSkins.currentID, PixlSkins.displayName)
        defer { PixlSkins.currentID = id; PixlSkins.displayName = name }
        PixlSkins.currentID = "cat"; PixlSkins.displayName = nil
        #expect(PixlSkins.name == "Nox")
        PixlSkins.displayName = "Midnight"
        #expect(PixlSkins.name == "Midnight")
    }

    @Test func shortHintsInMenusAreNotCutOff() {
        let rows = [ListMenuView.Row(id: "game", title: "Mischief: Fly snap", icon: "sparkle", trailing: "best 7"),
                    ListMenuView.Row(id: "hide", title: "Hide for now", icon: nil, trailing: "⌃⌥H")]
        let list = ListMenuView(rows: rows, look: .init(glass: false, variant: .dark, dim: 0.94))
        let hints = list.rowViews.flatMap { $0.subviews.compactMap { $0 as? NSTextField } }.filter { $0.font?.isFixedPitch == true }
        #expect(hints.count == 2)
        for h in hints { #expect(!h.isHidden && h.frame.width >= h.fittingSize.width - 0.5, "\(h.stringValue) cut to \(h.frame.width)") }
    }
}

@MainActor
@Suite struct PixlNameTests {
    @Test func eachPixlKeepsItsOwnName() {
        var s = PixlSettings()
        s.switchSkin(to: "widow", default: "Silk")
        s.name = "Charlotte"; s.rememberName(default: "Silk")
        s.switchSkin(to: "cat", default: "Nox")
        #expect(s.name == "Nox")                         // not Charlotte
        s.switchSkin(to: "widow", default: "Silk")
        #expect(s.name == "Charlotte")                   // she gets her name back
        s.name = "Silk"; s.rememberName(default: "Silk")
        #expect(s.names == nil)                          // back to the default: nothing to remember
    }

    @Test func oldSettingsKeepTheirCustomNameOnThePixlTheyWereSavedWith() throws {
        let d = try #require(UserDefaults(suiteName: "pixl-test-\(UUID())"))
        d.set(Data(#"{"scale":2,"mischief":"normal","distractingApps":[],"hideInFullscreen":true,"perchOnWindows":true,"skin":"widow","name":"Charlotte"}"#.utf8), forKey: PixlSettings.key)
        var s = PixlSettings.load(d)
        #expect(s.name == "Charlotte" && s.names == ["widow": "Charlotte"])
        s.switchSkin(to: "ghost", default: "Boo")
        #expect(s.name == "Boo")
    }
}
