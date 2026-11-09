import CoreGraphics
import Foundation
import Testing
@testable import PixlMemoryKit

@MainActor struct MiniGameTests {
    let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)
    let pixl = CGPoint(x: 700, y: 800)

    @Test func everyPixlHasAGameWithArt() throws {
        for skin in PixlSkins.all {
            let g = try #require(skin.ui.game, "\(skin.id) has no game")
            #expect(GameArt.image(g.target) != nil, "\(skin.id): no art for \(g.target)")
        }
    }
}
