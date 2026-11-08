import AppKit
import PixlzCore
import Testing
@testable import PixlMemoryKit

@MainActor
struct SkinTests {
    @Test func everySkinShipsAndIsValid() {
        #expect(PixlSkins.all.map(\.id) == ["frogg", "cat", "shiba", "ghost", "widow"])
        for skin in PixlSkins.all {
            #expect(ManifestValidator.validate(skin.manifest).isEmpty, "\(skin.id): \(ManifestValidator.validate(skin.manifest))")
            #expect(skin.manifest.id == skin.id)
        }
    }

    @Test func everySkinHasEveryRequiredFrame() {
        let motion = [MotionFrames.notice, MotionFrames.coil, MotionFrames.rise, MotionFrames.fall, MotionFrames.land,
                      MotionFrames.settle, MotionFrames.hang, MotionFrames.dropLand, MotionFrames.startle]
        #expect(PixlSkins.requiredFrames.count == 9 * 3 + 6)
        for skin in PixlSkins.all {
            for name in PixlSkins.requiredFrames + motion + [skin.ui.menuFace] {
                #expect(skin.art.frames[name] != nil, "\(skin.id) is missing \(name)")
                #expect(skin.art.image(name) != nil, "\(skin.id): \(name) doesn't render")
            }
        }
    }

    @Test func grabFramesHangFromAPinInsideTheSprite() throws {
        for skin in PixlSkins.all {
            for name in ["grab_0", "grab_1"] {
                let f = try #require(skin.art.frames[name])
                let pin = try #require(f.pin, "\(skin.id) \(name) has no pin")
                #expect((0..<f.w).contains(pin[0]) && (0..<f.h).contains(pin[1]), "\(skin.id) \(name) pin \(pin) outside \(f.w)×\(f.h)")
                #expect(skin.art.isOpaque(name, x: pin[0], y: pin[1]) || pin[1] <= 2, "\(skin.id) \(name): the cursor holds thin air")
            }
        }
    }

    @Test func eachSkinCarriesItsOwnCharacter() throws {
        var accents = Set<String>()
        for skin in PixlSkins.all {
            let ui = try #require(skin.manifest.ui)
            #expect(ui.accent.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil)
            accents.insert(ui.accent)
            #expect(!ui.signature.isEmpty && !ui.personality.isEmpty && ui.askPlaceholder.contains(skin.manifest.name))
            let d = try #require(ui.decal, "\(skin.id) has no menu detail")
            #expect(!d.grid.isEmpty && DecalArt.image(d, accent: ui.accent, look: .init(glass: false, variant: .light, dim: 1)) != nil)
            #expect(ui.glassBody == (skin.id == "ghost"))   // C10: Liquid Glass body is the ghost's alone
        }
        #expect(accents.count == PixlSkins.all.count)
    }

    @Test func switchingSkinsChangesTheArtAndCharacter() {
        let before = PixlSkins.currentID
        defer { PixlSkins.currentID = before }
        PixlSkins.currentID = "cat"
        #expect(FroggArt.shared === PixlSkins.skin("cat")!.art && PixlData.ui.signature == "Slow blink")
        PixlSkins.currentID = "nonsense"
        #expect(PixlSkins.current.id == "frogg")   // an unknown saved id falls back to Frogg
    }

    @Test func settingsSavedBeforeSkinsStillLoad() throws {
        let d = try #require(UserDefaults(suiteName: "pixl-skin-\(UUID())"))
        d.set(Data(#"{"name":"Sir Hops","scale":3,"perchOnWindows":true,"hideInFullscreen":true,"mischief":"normal","distractingApps":[]}"#.utf8), forKey: PixlSettings.key)
        let s = PixlSettings.load(d)
        #expect(s.name == "Sir Hops" && s.scale == 3 && s.skinID == "frogg")
    }

    @Test func pickerTilesFireAndAreLabelled() throws {
        let picker = SkinPickerView(selected: "frogg", look: .init(glass: false, variant: .light, dim: 1))
        var picked: [String] = []
        picker.onPick = { picked.append($0) }
        let w = Click.host(picker)
        defer { w.close() }
        Click.click(picker, at: try #require(picker.center(of: picker.index(of: "ghost")!)))
        #expect(picked == ["ghost"] && picker.selected == "ghost")
        let labels = (picker.accessibilityChildren() as? [NSView])?.compactMap { $0.accessibilityLabel() } ?? []
        #expect(labels.contains("Boo, Bedsheet ghost") && labels.count == 5)
    }
}
