import AppKit
import Testing
@testable import PixlMemoryKit

@MainActor
@Suite struct PixlCopyTests {
    @Test func theGrumbleMatchesThePixl() {
        #expect(PixlSkins.busyLine(name: "Nox", species: "Black cat") == "Hey! Nox is busy being a black cat.")
        #expect(PixlSkins.busyLine(name: "Frogg", species: "Red-eyed tree frog") == "Hey! Frogg is busy being a red-eyed tree frog.")
        #expect(PixlSkins.busyLine(name: "Boo", species: "Bedsheet ghost") == "Hey! Boo is busy being a bedsheet ghost.")
        #expect(PixlSkins.busyLine(name: "Ink", species: "Inky octopus · deep sea").hasSuffix("being an inky octopus."))
        for skin in PixlSkins.all {   // no Pixl but Frogg calls itself a frog
            let line = PixlSkins.busyLine(name: skin.manifest.name, species: skin.manifest.species)
            #expect(skin.id == "frogg" || !line.lowercased().contains("frog"), "\(skin.id): \(line)")
        }
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
