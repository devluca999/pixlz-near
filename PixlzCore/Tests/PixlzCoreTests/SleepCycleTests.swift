import Foundation
import Testing
@testable import PixlzCore

@Suite struct SleepCycleTests {
    /// Runs the clock from `t0` to `t1` in 0.25 s steps; `away(t)` is seconds since input.
    func run(_ s: inout SleepCycle, _ t0: Double, _ t1: Double, typing: Bool = false, energy: Double = 80,
             away: (Double) -> Double) -> [SleepCycle.Output] {
        var out: [SleepCycle.Output] = []
        var t = t0
        while t < t1 { t += 0.25; out += s.tick(at: t, sinceInput: away(t), typing: typing, energy: energy) }
        return out
    }

    func asleep(_ sleepiness: SleepCycle.Sleepiness = .normal, hover: Bool = false) -> (SleepCycle, Double) {
        var s = SleepCycle(at: 0, sleepiness: sleepiness, hoverWakes: hover)
        let threshold = sleepiness.awayThreshold
        _ = run(&s, 0, threshold + SleepCycle.drowsyTime + 1) { $0 }   // no input since t = 0
        return (s, threshold + SleepCycle.drowsyTime + 1)
    }

    @Test func awayFiveMinutesThenDrowsyThenAsleepThenDeep() {
        var s = SleepCycle(at: 0)
        _ = run(&s, 0, 299) { $0 }
        #expect(s.stage == .awake)
        _ = run(&s, 299, 301) { $0 }
        #expect(s.stage == .drowsy && s.cause == .away)
        _ = run(&s, 301, 322) { $0 }
        #expect(s.stage == .asleep)
        _ = run(&s, 322, 322 + 601) { $0 }
        #expect(s.stage == .deep)
    }

    @Test(arguments: SleepCycle.Sleepiness.allCases)
    func sleepinessSetsTheAwayThreshold(_ level: SleepCycle.Sleepiness) {
        var s = SleepCycle(at: 0, sleepiness: level)
        _ = run(&s, 0, level.awayThreshold - 2) { $0 }
        #expect(s.stage == .awake)
        _ = run(&s, level.awayThreshold - 2, level.awayThreshold + 1) { $0 }
        #expect(s.stage == .drowsy)
        #expect([600.0, 300, 120].contains(level.awayThreshold))
    }

    @Test func typingRestsButNeverSleepsEvenWhenANapIsDue() {
        var s = SleepCycle(at: 0)
        _ = run(&s, 0, 5, typing: true, energy: 80) { _ in 0.2 }
        #expect(s.stage == .resting)
        _ = run(&s, 5, 3600, typing: true, energy: 60) { _ in 0.2 }   // energy way down, still typing
        #expect(s.stage == .resting)
        _ = run(&s, 3600, 3601, typing: false, energy: 60) { _ in 2 }
        #expect(s.stage == .drowsy && s.cause == .nap)                  // stops typing: the nap
    }

    @Test func activityNapsComeWhenEnergyHasDroppedAndEndOnTheirOwn() {
        var s = SleepCycle(at: 0)
        _ = run(&s, 0, 10, energy: 80) { _ in 0.5 }
        let need = s.napDropNeeded
        #expect(need >= 3 && need <= 6)
        _ = run(&s, 10, 11, energy: 80 - need + 0.5) { _ in 0.5 }
        #expect(s.stage == .awake)
        _ = run(&s, 11, 12, energy: 80 - need - 0.1) { _ in 0.5 }
        #expect(s.stage == .drowsy && s.cause == .nap)
        _ = run(&s, 12, 40, energy: 75) { _ in 0.5 }                   // you keep working: it naps anyway
        #expect(s.stage == .asleep)
        let out = run(&s, 40, 40 + 241 + 2, energy: 75) { _ in 0.5 }
        #expect(out.contains(.react(.stretchYawn)) && s.stage == .awake)
    }

    @Test func sleepierPixlsNapMoreOften() {
        let owl = SleepCycle(at: 0, sleepiness: .nightOwl, seed: 9).napDropNeeded
        let sleepy = SleepCycle(at: 0, sleepiness: .sleepy, seed: 9).napDropNeeded
        #expect(sleepy < owl)
    }

    @Test func drowsyIsEasyToRouse() {
        var s = SleepCycle(at: 0)
        _ = run(&s, 0, 301) { $0 }
        #expect(s.stage == .drowsy)
        let out = s.handle(.cursorNear, at: 302)
        #expect(s.stage == .awake && out.first == .stage(from: .drowsy, to: .awake, why: "roused (cursorNear)"))
        // and you coming back rouses it too
        var t = SleepCycle(at: 0)
        _ = run(&t, 0, 301) { $0 }
        _ = run(&t, 301, 303) { _ in 0.1 }
        #expect(t.stage == .awake)
    }

    @Test func comingBackWakesItOnItsOwnAfterTheMinimumSleep() {
        var (s, t) = asleep()
        // back 10 s into its sleep: it keeps sleeping until 90 s, then stretches and yawns
        let back = t + 10
        let early = run(&s, t, t + 80) { x in x < back ? x : 0.2 }
        #expect(!early.contains(.react(.stretchYawn)) && s.stage.sleeping)
        let later = run(&s, t + 80, t + 95) { _ in 0.2 }
        #expect(later.contains(.react(.stretchYawn)))
        _ = run(&s, t + 95, t + 98) { _ in 0.2 }
        #expect(s.stage == .awake)
    }

    @Test func comingBackAfterALongSleepWakesInAFewSeconds() {
        var (s, t) = asleep()
        _ = run(&s, t, t + 200) { $0 }                                  // still away
        let out = run(&s, t + 200, t + 200 + SleepCycle.returnDelay + 0.5) { _ in 0.1 }
        #expect(out.contains(.react(.stretchYawn)))
    }

    @Test func aCursorPassingOnlyStirsIt() {
        var (s, t) = asleep()
        #expect(s.handle(.cursorNear, at: t + 1) == [.react(.stir)] && s.stage.sleeping)
    }

    @Test func hoveringOpensAnEyeThatClosesAgain() {
        var (s, t) = asleep()
        _ = s.handle(.hoverStart, at: t)
        let out = run(&s, t, t + 2.5) { $0 }
        #expect(out.contains(.react(.eyeOpen)) && s.stage.sleeping)
        #expect(s.handle(.hoverEnd, at: t + 3) == [.react(.eyeClose)])
        _ = run(&s, t + 3, t + 10) { $0 }
        #expect(s.stage.sleeping)                                        // hovering doesn't wake it by default
    }

    @Test func withHoverWakingOnALongHoverWakesIt() {
        var (s, t) = asleep(hover: true)
        _ = s.handle(.hoverStart, at: t)
        let out = run(&s, t, t + 4.5) { $0 }
        #expect(out.contains(.react(.eyeOpen)) && out.contains(.react(.wake)))
    }

    @Test func aPokeStartlesThenGrumpyThenAwakeEvenBeforeTheMinimum() {
        var (s, t) = asleep()
        #expect(s.handle(.poke, at: t + 1).contains(.react(.startled)))
        let out = run(&s, t + 1, t + 3.2) { _ in 0.5 }   // you're right there
        #expect(out.contains(.react(.grumpy)) && s.stage == .awake)
    }

    @Test func aMenuClickWakesItAndOpensTheMenu() {
        var (s, t) = asleep()
        let out = s.handle(.menuClick, at: t + 1)
        #expect(out.contains(.react(.wakeAndMenu)) && s.stage == .awake)
    }

    @Test func grabbedItStaysAsleepWhileDangling() {
        var (s, t) = asleep()
        #expect(s.handle(.grab, at: t + 1).isEmpty && s.handle(.release, at: t + 2).isEmpty && s.stage.sleeping)
    }

    @Test func windowSwitchesAndNotificationsOnlyTwitchAnEar() {
        var (s, t) = asleep()
        #expect(s.handle(.windowSwitch, at: t + 1) == [.react(.earTwitch)])
        #expect(s.handle(.notification, at: t + 2) == [.react(.earTwitch)] && s.stage.sleeping)
    }

    @Test(arguments: [SleepCycle.Input.hotkey, .focusEnded])
    func theHotkeyOrFocusEndingWakesIt(_ input: SleepCycle.Input) {
        var (s, t) = asleep()
        #expect(s.handle(input, at: t + 1).contains(.react(.wake)))
        _ = run(&s, t + 1, t + 2) { _ in 0.5 }
        #expect(s.stage == .awake)
    }

    @Test func fastForwardForTesting() {
        var (s, t) = asleep()
        s.debugFastForward(by: 600)
        _ = run(&s, t, t + 1) { $0 }
        #expect(s.stage == .deep)
    }
}
