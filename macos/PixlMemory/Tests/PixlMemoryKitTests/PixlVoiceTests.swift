import Testing
import PixlzCore
@testable import PixlMemoryKit

@MainActor
@Suite struct PixlVoiceTests {
    func ui(_ id: String) -> PixlUI? { PixlSkins.skin(id)?.manifest.ui }

    @Test func booIsShyAndOnlySaysEllipses() {
        for _ in 0..<20 {
            #expect(PixlVoice.ellipses.contains(PixlVoice.chatter("Hi, I'm Boo!", ui: ui("ghost"))))
            #expect(PixlVoice.ellipses.contains(PixlVoice.busy(name: "Boo", ui: ui("ghost"), species: "Bedsheet ghost")))
            #expect(PixlVoice.ellipses.contains(PixlVoice.doing(ui: ui("ghost"))))
        }
        #expect(PixlVoice.chatter("Hi, I'm Silk!", ui: ui("widow")) == "Hi, I'm Silk!")
    }

    @Test func statusLinesVaryAndPlayOnTheCharacter() {
        let silk = Set((0..<60).map { _ in PixlVoice.doing(ui: ui("widow")) })
        #expect(silk.count > 3 && silk.contains("Weaving…"))
        #expect(silk.allSatisfy { $0.first!.isUppercase && $0.hasSuffix("…") })
        let nox = Set((0..<60).map { _ in PixlVoice.busy(name: "Nox", ui: ui("cat"), species: "Black cat") })
        #expect(nox.count > 3 && nox.allSatisfy { $0.hasPrefix("Hey! Nox is busy ") && !$0.contains("frog") })
        for skin in PixlSkins.all { #expect((skin.manifest.ui?.status?.count ?? 0) >= 6, "\(skin.id) needs status lines") }
    }
}
