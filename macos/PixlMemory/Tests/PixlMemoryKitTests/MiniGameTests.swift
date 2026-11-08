import CoreGraphics
import Foundation
import Testing
@testable import PixlMemoryKit

struct MiniGameTests {
    let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)
    let pixl = CGPoint(x: 700, y: 800)

    /// Plays a whole game: `catches(target)` decides whether the user clicks it, and when.
    func play(seed: UInt64, catches: (CatchGame.Target) -> TimeInterval?) -> (CatchGame, [CatchGame.Event]) {
        var g = CatchGame(seed: seed)
        g.start(at: 100, around: pixl, bounds: screen)
        var events: [CatchGame.Event] = []
        var pending: (Int, TimeInterval)?
        var t = 100.0
        while t < 125 {
            if let (id, at) = pending, t >= at { _ = g.hit(id, at: t); pending = nil }
            if let e = g.tick(t) {
                events.append(e)
                if case .spawn(let target) = e, let delay = catches(target) { pending = (target.id, t + delay) }
                if case .over = e { break }
            }
            t += 1.0 / 60
        }
        return (g, events)
    }

    @Test func catchingEverythingScoresEveryTarget() {
        let (g, events) = play(seed: 7) { _ in 0.3 }
        let spawned = events.filter { if case .spawn = $0 { true } else { false } }.count
        #expect(g.finished && g.score == spawned && g.missed == 0 && spawned > 15)
        #expect(events.last == CatchGame.Event.over(score: g.score, missed: 0))
    }

    @Test func tooSlowMissesAndTargetsGetShorterLived() {
        let (g, events) = play(seed: 7) { _ in nil }
        #expect(g.score == 0 && g.missed > 5)
        let lives = events.compactMap { if case .spawn(let t) = $0 { t.life } else { nil } }
        #expect(lives.first! > lives.last! && lives.first! <= CatchGame.firstLife && lives.last! >= CatchGame.lastLife)
        // a click after the target vanished doesn't count
        var g2 = CatchGame(seed: 1)
        g2.start(at: 0, around: pixl, bounds: screen)
        var target: CatchGame.Target?
        var t = 0.0
        while target == nil { if case .spawn(let x)? = g2.tick(t) { target = x }; t += 0.01 }
        let late = g2.hit(target!.id, at: target!.dies + 0.01)
        let wrong = g2.hit(999, at: target!.born + 0.1)
        #expect(!late && !wrong)
    }

    @Test func targetsPopUpAroundThePixlOnScreenNeverOnIt() {
        let (_, events) = play(seed: 42) { _ in 0.2 }
        let spots = events.compactMap { if case .spawn(let t) = $0 { t.center } else { nil } }
        #expect(!spots.isEmpty)
        for p in spots {
            #expect(screen.insetBy(dx: 15, dy: 15).contains(p))
            #expect(hypot(p.x - pixl.x, p.y - (pixl.y - 40)) >= 60)   // never on top of the Pixl
        }
        #expect(play(seed: 42) { _ in 0.2 }.1 == events)   // seeded: the same game every time
    }

    @MainActor
    @Test func everyPixlHasAGameWithArt() throws {
        for skin in PixlSkins.all {
            let g = try #require(skin.ui.game, "\(skin.id) has no game")
            #expect(GameArt.image(g.target) != nil, "\(skin.id): no art for \(g.target)")
        }
    }
}
