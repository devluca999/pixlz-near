import AppKit
import PixlzCore
import Testing
@testable import PixlMemoryKit

@MainActor
struct SkinTests {
    @Test func everySkinShipsAndIsValid() {
        #expect(PixlSkins.all.map(\.id) == ["frogg", "cat", "shiba", "ghost", "widow", "slugg"])
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
        #expect(labels.contains("Boo, Sheety ghost") && labels.count == PixlSkins.all.count)
    }
}

@MainActor
@Suite struct PixlCatalogTests {
    @Test func everyPixlHasANameDescriptionIdlePreviewAndASkin() throws {
        let expected = ["frogg": ("Frogg", "Tree frog, the red-eyed kind"), "cat": ("Katt", "Friendly feline"),
                        "shiba": ("Mochi", "Shiba Inu, professional zoomer"), "ghost": ("Boo", "Sheety ghost"),
                        "widow": ("Silky", "Black widow, mostly harmless"), "slugg": ("Slugg", "Definitely a slug")]
        for skin in PixlSkins.all {
            let m = skin.manifest, ui = try #require(m.ui, "\(skin.id) has no ui")
            #expect(m.name == expected[skin.id]?.0, "\(skin.id) name \(m.name)")
            #expect(ui.description == expected[skin.id]?.1, "\(skin.id) description")
            // its own idle animation, from its manifest: the idle slot's three frames
            #expect(m.slots[.idle]?.holds.count == 3)
            for f in ["idle_0", "idle_1", "idle_2"] { #expect(skin.art.image(f) != nil, "\(skin.id) \(f)") }
            let skins = try #require(ui.skins, "\(skin.id) has no skins")
            #expect(skins.first?.id == "default" && !skins.isEmpty)
            #expect(Set(skins.map(\.id)).count == skins.count)
        }
        let slugg = try #require(PixlSkins.skin("slugg")?.manifest.ui?.skins)
        #expect(slugg.map(\.name) == ["Default", "Leopard grey", "Neon nudibranch", "Dapper", "Humbug"])
        #expect(slugg.filter { $0.locked == true }.map(\.id) == ["dapper", "humbug"])
    }

    @Test func locomotionLoopsAndPondLayersShip() throws {
        let cat = try #require(PixlSkins.skin("cat")).art, shiba = try #require(PixlSkins.skin("shiba")).art
        let slugg = try #require(PixlSkins.skin("slugg")).art, frogg = try #require(PixlSkins.skin("frogg")).art
        for i in 0..<8 { #expect(cat.image("walk_\(i)") != nil && slugg.image("crawl_\(i)") != nil) }
        for i in 0..<6 { #expect(cat.image("trot_\(i)") != nil && cat.image("climb_\(i)") != nil && shiba.image("trot_\(i)") != nil) }
        for i in 0..<8 { #expect(slugg.image("crawl_\(i)_body") != nil && slugg.image("crawl_\(i)_shell") != nil) }
        #expect(frogg.image("pond_4") != nil)
        let pond = try #require(PondArt.shared)
        #expect(pond.frames.count == 12 && pond.loop == 4...7)
        for f in pond.frames { #expect(f.mask.count == pond.height && f.mask.allSatisfy { $0.count == pond.width }) }
    }
}
