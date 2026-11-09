import Foundation
import Testing
import PixlzCore
@testable import PixlMemoryKit

/// SPEC §11.6: voice, status and notices are separate channels.
@MainActor
@Suite struct TextChannelTests {
    func ui(_ id: String) -> PixlUI? { PixlSkins.skin(id)?.manifest.ui }

    @Test func voiceBubblesOnlyUseThePixlsOwnSoundsAndNeverRepeatBackToBack() {
        for skin in PixlSkins.all {
            let ui = skin.manifest.ui
            let sounds = VoicePicker.allSounds(ui: ui)
            #expect(sounds.count >= 4, "\(skin.id) needs a sound set in pixl.json")
            var picker = VoicePicker()
            var last: String?
            for i in 0..<200 {
                let line = picker.pick(SoundEvent.allCases[i % SoundEvent.allCases.count], ui: ui)
                #expect(sounds.contains(line), "\(skin.id) said \"\(line)\", not one of its sounds")
                #expect(line != last, "\(skin.id) said \"\(line)\" twice in a row")
                last = line
            }
        }
        #expect(VoicePicker.allSounds(ui: ui("frogg")).isSuperset(of: ["ribbit!", "rrbt?", "RIBBIT!"]))
        #expect(VoicePicker.allSounds(ui: ui("ghost")).isSubset(of: ["...", "…", "……", "…?", "…!", "!", "boo", "boo?", "boo!", "boo…"]))
    }

    @Test func theAppOnlyPutsSoundsInSpeechBubbles() throws {
        // the app's only speech bubble is voiceBubble, called from speak (and the self-test)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/PixlMemory")
        let files = try FileManager.default.contentsOfDirectory(at: dir.standardized, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(!source.contains("func say("), "say(...) is gone: use speak (voice), notify (notices) or statusLine")
        #expect(source.components(separatedBy: "BubbleView(").count - 1 == 1, "only voiceBubble builds a speech bubble")
        let calls = source.components(separatedBy: "voiceBubble(").count - 1
        #expect(calls == 4, "voiceBubble: its definition, speak, exclaim (game voice lines) and the self-test (\(calls))")
    }

    @Test func everyNoticeIsPlainEnglish() {
        let notices = Notice.catalog(name: "Frogg")
        #expect(notices.count > 40)
        for n in notices {
            let t = n.text
            #expect(!t.isEmpty && t.count <= 200, "\(t)")
            #expect(t.first!.isUppercase || t.first!.isNumber, "starts with a capital: [\(t)]")
            #expect(".…!?".contains(t.last!) || t.last!.isNumber, "ends like a sentence: [\(t)]")
            #expect(!t.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "no emoji: \(t)")
            #expect(BubbleIcons.image(n.icon, dark: false) != nil, "icon \(n.icon)")
        }
    }

    @Test func statusIsThirdPersonNarrationWithoutPronouns() {
        let frogg = ui("frogg")
        let idle = (0..<8).map { PixlStatus.line(name: "Frogg", activity: .idle($0), ui: frogg) }
        #expect(idle.contains("Frogg is practicing a croak."))
        #expect(idle.allSatisfy { $0.hasPrefix("Frogg is ") && $0.hasSuffix(".") && !$0.contains("{") })
        #expect(PixlStatus.line(name: "Kiti", activity: .idle(7), ui: ui("cat")) == "Kiti is guarding the warm spot.")
        #expect(PixlStatus.line(name: "Frogg", activity: .outing("pond"), ui: frogg) == "Frogg is taking a dip in the pond.")
        #expect(PixlStatus.line(name: "Kiti", activity: .asleep, ui: ui("cat")) == "Kiti is asleep.")
        // status never borrows a sound
        let sounds = PixlSkins.all.flatMap { VoicePicker.allSounds(ui: $0.manifest.ui) }
        let words = Set(idle.flatMap { $0.lowercased().split { !$0.isLetter }.map(String.init) })
        #expect(words.isDisjoint(with: Set(sounds.map { $0.lowercased() })))
    }

    @Test func noStatusLineNeedsAPronoun() {
        let pronouns: Set<String> = ["he", "she", "his", "her", "hers", "him", "they", "their", "them", "its"]
        for skin in PixlSkins.all {
            for i in 0..<(skin.manifest.ui?.status?.count ?? 0) {
                let line = PixlStatus.line(name: "X", activity: .idle(i), ui: skin.manifest.ui)
                let words = Set(line.lowercased().split { !$0.isLetter }.map(String.init))
                #expect(words.isDisjoint(with: pronouns), "\(skin.id): \(line)")
            }
        }
    }
}
