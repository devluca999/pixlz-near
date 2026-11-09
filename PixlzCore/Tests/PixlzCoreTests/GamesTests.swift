import CoreGraphics
import Foundation
import Testing
@testable import PixlzCore

@Suite struct ChaseGameTests {
    let screen = CGRect(x: 0, y: 25, width: 1600, height: 1000)

    func game(at head: CGPoint = CGPoint(x: 300, y: 600), round: TimeInterval = 60, invite: Bool = false) -> ChaseGame {
        ChaseGame(head: head, heading: 0, bounds: screen, scale: 2, body: 60, round: round, invite: invite, now: 0)
    }

    /// Runs at 60 Hz from `from` to `to` with the cursor given by `cursor(t)`; returns every event.
    func run(_ g: inout ChaseGame, from: Double, to: Double, cursor: (Double) -> CGPoint) -> [(Double, ChaseGame.Event)] {
        var out: [(Double, ChaseGame.Event)] = []
        var t = from
        while t <= to {
            for e in g.step(now: t, cursor: cursor(t)) { out.append((t, e)) }
            t += 1.0 / 60
        }
        return out
    }

    @Test func aParkedCursorGetsCaught() {
        var g = game()
        let events = run(&g, from: 0, to: 60) { _ in CGPoint(x: 600, y: 600) }
        #expect(events.contains { $0.1 == .gotcha })
        #expect(g.phase == .won)
        // 300 pt at 14→ px/s × 2, slowed 15 % once parked: roughly 12 s, well inside the round
        let t = events.first { $0.1 == .gotcha }!.0
        #expect(t > 8 && t < 16)
    }

    @Test func keepingAwaySurvivesTheRound() {
        // a wide desk; the cursor starts 500 pt ahead and keeps drifting away at 40 pt/s
        var g = ChaseGame(head: CGPoint(x: 300, y: 600), bounds: CGRect(x: 0, y: 25, width: 5000, height: 1000), scale: 2, body: 60, now: 0)
        let events = run(&g, from: 0, to: 61) { t in CGPoint(x: 800 + 40 * t, y: 600 + 20 * sin(t)) }
        #expect(events.last?.1 == .survived)
        #expect(g.phase == .survived)
        #expect(g.score(61).seconds == 60)
    }

    @Test func speedRampsOverTheRoundAndWithBonks() {
        var g = game()
        let far = CGPoint(x: 1500, y: 900)
        #expect(abs(g.crawlSpeed(0, cursor: far) - 28) < 0.01)          // 14 px/s × 2
        #expect(abs(g.crawlSpeed(60, cursor: far) - 44) < 0.01)         // 22 px/s × 2
        _ = g.step(now: 0.01, cursor: far)
        let r1 = g.bonk(now: 1)
        #expect(r1)
        #expect(abs(g.crawlSpeed(1, cursor: far) / g.crawlSpeed(1, cursor: far) - 1) < 0.001)
        let fast = g.crawlSpeed(1, cursor: far)
        var fresh = game()
        _ = fresh.step(now: 0.01, cursor: far)
        #expect(abs(fast / fresh.crawlSpeed(1, cursor: far) - 1.08) < 0.001)   // +8 % per bonk
        // close boost: within two body lengths
        #expect(abs(fresh.crawlSpeed(1, cursor: CGPoint(x: 400, y: 600)) / fresh.crawlSpeed(1, cursor: far) - 1.2) < 0.001)
    }

    @Test func bonkShellThenCooldown() {
        var g = game()
        let far = CGPoint(x: 1500, y: 600)
        _ = run(&g, from: 0, to: 1) { _ in far }
        let r2 = g.bonk(now: 1)
        #expect(r2)
        #expect(g.bonks == 1)
        let r3 = g.bonk(now: 1.5)
        #expect(!r3)                                       // in the shell: no double bonk
        let pos = g.head
        var events = run(&g, from: 1.02, to: 3.9) { _ in far }
        #expect(g.head == pos)                                           // no crawling in the shell
        events += run(&g, from: 3.92, to: 4.6) { _ in far }
        #expect(events.contains { $0.1 == .cameOut })                    // 3 s shell + 0.4 s wobble
        let out = events.first { $0.1 == .cameOut }!.0
        #expect(out > 4.3 && out < 4.45)
        let r4 = g.bonk(now: out + 1.0)
        #expect(!r4)                                 // 1.5 s cooldown
        _ = run(&g, from: out + 0.02, to: out + 1.6) { _ in far }
        let r5 = g.bonk(now: out + 1.6)
        #expect(r5)
        #expect(g.bonks == 2)
    }

    @Test func shellTimeShortensOverTheRound() {
        var g = ChaseGame(head: CGPoint(x: 300, y: 600), bounds: CGRect(x: 0, y: 25, width: 5000, height: 1000), scale: 2, body: 60, now: 0)
        let far = CGPoint(x: 4500, y: 600)
        _ = run(&g, from: 0, to: 59) { t in CGPoint(x: 4500, y: 600 + 30 * sin(t)) }
        let r6 = g.bonk(now: 59)
        #expect(r6)
        guard case .shell(let until) = g.phase else { Issue.record("not in shell"); return }
        #expect(abs((until - 59) - (3.0 + (2.2 - 3.0) * 59 / 60)) < 0.001)
        _ = far
    }

    @Test func turnsBeforeMoving() {
        // facing right, cursor behind him: the first half second is nearly all turning
        var g = ChaseGame(head: CGPoint(x: 800, y: 600), heading: 0, bounds: screen, scale: 2, body: 60, now: 0)
        _ = run(&g, from: 0, to: 0.5) { _ in CGPoint(x: 300, y: 600) }
        #expect(g.head.x > 795)                                          // hardly moved
        #expect(abs(g.heading) > 0.3)                                    // but turned
    }

    @Test func waitsAtTheEdgeForACursorInTheMenuBarOrACorner() {
        var g = game(at: CGPoint(x: 1300, y: 300))
        let menuBar = CGPoint(x: 1400, y: 10)
        let events = run(&g, from: 0, to: 40) { _ in menuBar }
        #expect(!events.contains { $0.1 == .gotcha })
        #expect(g.waiting)
        #expect(g.head.y >= screen.minY + 40)
        #expect(g.unreachable(CGPoint(x: 1590, y: 1020)))               // bottom-right corner
        #expect(!g.unreachable(CGPoint(x: 800, y: 1020)))               // bottom edge, mid: reachable
    }

    @Test func dangerRisesWithinOneBodyLength() {
        let g = game()
        #expect(g.danger(cursor: CGPoint(x: 600, y: 600)) == 0)
        #expect(g.danger(cursor: CGPoint(x: 330, y: 600)) > 0.4)
    }

    @Test func interruptEndsAtOnceWithoutAScore() {
        var g = game()
        _ = run(&g, from: 0, to: 5) { _ in CGPoint(x: 1500, y: 600) }
        let r7 = g.interrupt(now: 5)
        #expect(r7 == .interrupted)
        #expect(g.phase == .interrupted)
        let r8 = g.step(now: 6, cursor: .zero)
        #expect(r8.isEmpty)
        let r9 = g.bonk(now: 6)
        #expect(!r9)
        let r10 = g.interrupt(now: 7)
        #expect(r10 == nil)
    }

    @Test func anInviteIsAcceptedByAClickAndDeclinedByMovingAwayOrWaiting() {
        var a = game(invite: true)
        _ = a.step(now: 0.5, cursor: CGPoint(x: 700, y: 600))
        _ = a.bonk(now: 1)                                               // the click accepts
        #expect(a.phase == .chase)
        var b = game(invite: true)
        _ = b.step(now: 0.2, cursor: CGPoint(x: 700, y: 600))
        let r11 = b.step(now: 0.4, cursor: CGPoint(x: 1000, y: 600))
        #expect(r11 == [.declined])
        var c = game(invite: true)
        _ = c.step(now: 0.2, cursor: CGPoint(x: 700, y: 600))
        let r12 = c.step(now: 2.1, cursor: CGPoint(x: 700, y: 600))
        #expect(r12 == [.declined])
    }
}

@Suite struct SnapGameTests {
    func run(_ g: inout SnapGame, from: Double, to: Double, cursor: (Double) -> CGPoint) -> [(Double, SnapGame.Event)] {
        var out: [(Double, SnapGame.Event)] = []
        var t = from
        while t <= to {
            for e in g.step(now: t, fly: SnapGame.fly(cursor: cursor(t), scale: g.scale)) { out.append((t, e)) }
            if g.phase.isOver { break }
            t += 1.0 / 120
        }
        return out
    }

    @Test func theTimingSheet() {
        let g = SnapGame(seed: 1, scale: 2, now: 0)
        #expect(g.tellLength(at: 0) == 0.70)
        #expect(g.tellLength(at: 25) == 0.50)
        #expect(g.tellLength(at: 59.9) == 0.28)
        #expect(g.strikeLength(at: 5) == 0.090)
        #expect(g.strikeLength(at: 55) == 0.070)
        #expect(g.recoveryLength(at: 0) == 0.60)
        #expect(g.recoveryLength(at: 55) == 0.35)
        #expect(g.feintChance(at: 15) == 0)
        #expect(g.feintChance(at: 25) == 0.10)
        #expect(g.feintChance(at: 55) == 0.30)
        #expect(g.gap(at: 0) == 2.2)
        #expect(abs(g.gap(at: 60) - 1.1) < 1e-9)
    }

    @Test func standingStillGetsCaughtByTheFirstStrike() {
        var g = SnapGame(seed: 7, scale: 2, now: 0)
        let events = run(&g, from: 0, to: 10) { _ in CGPoint(x: 900, y: 400) }
        #expect(events.map(\.1).contains(.caught))
        guard case .caught = g.phase else { Issue.record("not caught: \(g.phase)"); return }
        // first tell at 2.2 s, 0.7 s long, then a 90 ms strike
        let t = events.first { $0.1 == .caught }!.0
        #expect(abs(t - (2.2 + 0.7 + 0.09)) < 0.02)
        #expect(g.dodges == 0)
    }

    @Test func movingAfterTheTellEndsIsADodge() {
        var g = SnapGame(seed: 7, scale: 2, now: 0)
        // jump 100 pt the moment each strike starts: always aimed where the fly was
        var aimAt: Double = -1
        var events: [(Double, SnapGame.Event)] = []
        var t = 0.0, side = false
        while t <= 61, !g.phase.isOver {
            let cursor = CGPoint(x: side ? 1000 : 900, y: 400)
            for e in g.step(now: t, fly: SnapGame.fly(cursor: cursor, scale: 2)) {
                events.append((t, e))
                if case .strike = e { side.toggle(); aimAt = t }
            }
            t += 1.0 / 120
        }
        #expect(aimAt > 0)
        #expect(g.phase == .survived)
        #expect(g.dodges >= 20)
        #expect(events.last?.1 == .survived)
    }

    @Test func noFeintsBeforeTwentySecondsThenSomeButAtMostAboutAThird() {
        var g = SnapGame(seed: 42, scale: 2, now: 0)
        var tells: [(Double, Bool)] = []
        var t = 0.0, side = false
        while t <= 61, !g.phase.isOver {
            for e in g.step(now: t, fly: SnapGame.fly(cursor: CGPoint(x: side ? 1000 : 900, y: 400), scale: 2)) {
                if case .tell(let f) = e { tells.append((t, f)) }
                if case .strike = e { side.toggle() }
            }
            t += 1.0 / 120
        }
        #expect(!tells.filter { $0.0 < 20 }.contains { $0.1 })
        let late = tells.filter { $0.0 >= 20 }
        let rate = Double(late.filter(\.1).count) / Double(max(late.count, 1))
        #expect(rate > 0 && rate <= 0.45)
    }

    @Test func aFeintIsFollowedByAStrike400msLater() {
        var g = SnapGame(seed: 42, scale: 2, now: 0)
        var lastFeint: Double?, gapAfter: Double?
        var t = 0.0, side = false
        while t <= 61, !g.phase.isOver, gapAfter == nil {
            for e in g.step(now: t, fly: SnapGame.fly(cursor: CGPoint(x: side ? 1000 : 900, y: 400), scale: 2)) {
                if e == .feinted { lastFeint = t }
                if case .strike = e { side.toggle(); if let f = lastFeint { gapAfter = t - f } }
            }
            t += 1.0 / 240
        }
        #expect(gapAfter.map { abs($0 - 0.4) < 0.01 } == true)
    }

    @Test func strikesComeFasterLateInTheRound() {
        var g = SnapGame(seed: 3, scale: 2, now: 0)
        var tells: [Double] = []
        var t = 0.0, side = false
        while t <= 61, !g.phase.isOver {
            for e in g.step(now: t, fly: SnapGame.fly(cursor: CGPoint(x: side ? 1000 : 900, y: 400), scale: 2)) {
                if case .tell = e { tells.append(t) }
                if case .strike = e { side.toggle() }
            }
            t += 1.0 / 120
        }
        let gaps = zip(tells, tells.dropFirst()).map { $1 - $0 }
        let early = gaps.prefix(4).reduce(0, +) / 4, late = gaps.suffix(4).reduce(0, +) / 4
        #expect(late < early * 0.75)
    }

    @Test func theSameSeedReplaysTheSameRound() {
        func replay(_ seed: UInt64) -> [String] {
            var g = SnapGame(seed: seed, scale: 2, now: 0)
            var out: [String] = []
            var t = 0.0, side = false
            while t <= 61, !g.phase.isOver {
                for e in g.step(now: t, fly: SnapGame.fly(cursor: CGPoint(x: side ? 1000 : 900, y: 400), scale: 2)) {
                    out.append("\(Int(t * 1000)) \(e)")
                    if case .strike = e { side.toggle() }
                }
                t += 1.0 / 120
            }
            return out
        }
        #expect(replay(99) == replay(99))
        #expect(replay(99) != replay(100))
    }

    @Test func theFlySitsUpRightOfTheCursorAndTheHitRadiusScales() {
        let f = SnapGame.fly(cursor: CGPoint(x: 100, y: 100), scale: 2)
        #expect(f.x > 100 && f.y < 100)
        let g = SnapGame(seed: 1, scale: 2, now: 0)
        #expect(g.hits(aim: CGPoint(x: 0, y: 0), fly: CGPoint(x: 19, y: 0)))
        #expect(!g.hits(aim: CGPoint(x: 0, y: 0), fly: CGPoint(x: 21, y: 0)))
    }

    @Test func interruptAndInvite() {
        var g = SnapGame(seed: 1, scale: 2, now: 0)
        _ = g.step(now: 1, fly: .zero)
        let r13 = g.interrupt(now: 1.5)
        #expect(r13 == .interrupted)
        let r14 = g.step(now: 3, fly: .zero)
        #expect(r14.isEmpty)
        var i = SnapGame(seed: 1, scale: 2, invite: true, now: 0)
        let r15 = i.step(now: 2.1, fly: .zero)
        #expect(r15 == [.declined])
        var j = SnapGame(seed: 1, scale: 2, invite: true, now: 0)
        j.accept(now: 1)
        #expect(j.startedAt == 1)
    }
}

@Suite struct GameRecordsTests {
    @Test func keepsTheBestPerPet() {
        var r = GameRecords()
        let r16 = r.offer(GameScore(seconds: 40, count: 2), for: "slugg", byCount: false)
        #expect(r16)
        let r17 = r.offer(GameScore(seconds: 30, count: 9), for: "slugg", byCount: false)
        #expect(!r17)
        let r18 = r.offer(GameScore(seconds: 60, count: 0), for: "slugg", byCount: false)
        #expect(r18)
        let r19 = r.offer(GameScore(seconds: 20, count: 5), for: "frogg", byCount: true)
        #expect(r19)
        let r20 = r.offer(GameScore(seconds: 60, count: 4), for: "frogg", byCount: true)
        #expect(!r20)
        #expect(r.best["slugg"]?.seconds == 60)
        #expect(r.best["frogg"]?.count == 5)
    }
}
