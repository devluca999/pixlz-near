import Foundation
import Testing
@testable import PixlzCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func context(idleRun: TimeInterval = 60, energy: Double = 80, fun: Double = 80, mood: Mood = .content) -> AutonomyContext {
    AutonomyContext(now: now, needs: [.energy: energy, .fun: fun, .affection: 80], mood: mood, idleRun: idleRun)
}

@Suite struct BehaviorTests {
    @Test func modesGateSlotFrames() {
        #expect(Mode.grounded.allows(.move, frame: 0))
        #expect(!Mode.grounded.allows(.move, frame: 1))
        #expect(Mode.airborne.allows(.move, frame: 1))
        #expect(Mode.held.allows(.grab, frame: 1) && !Mode.held.allows(.grab, frame: 2))
        #expect(Mode.hidden.allowedFrames.isEmpty)
    }

    @Test func reactionPriority() {
        #expect(Reaction.grabbed.canInterrupt(.poke))
        #expect(!Reaction.poke.canInterrupt(.grabbed))
        #expect(Reaction.poke.canInterrupt(.poke))
        #expect(Reaction.autonomy.canInterrupt(nil))
        #expect(Reaction.hideOrTravel.canInterrupt(.grabbed))
    }

    @Test func idleBudgetHoldsIdle() {
        var p = AutonomyPicker(seed: 1)
        #expect(AutonomyPicker.idleBudget.contains(p.budget))
        #expect(p.pick(context(idleRun: 0)) == .idle)
        #expect(p.pick(context(idleRun: p.budget - 0.1)) == .idle)
    }

    @Test func weightsFollowMoodAndRules() {
        var c = context()
        #expect(AutonomyPicker.weights(c) == [.idle: 6, .move: 3, .perch: 0, .rest: 1, .signature: 1])
        c.platformReachable = true
        c.lastSignature = now.addingTimeInterval(-60)
        #expect(AutonomyPicker.weights(c)[.perch] == 2)
        #expect(AutonomyPicker.weights(c)[.signature] == 0)   // cooldown

        let tired = context(energy: 20, mood: .tired)
        #expect(AutonomyPicker.weights(tired)[.rest] == 4)
        #expect(AutonomyPicker.weights(tired)[.move] == 0)

        let bored = context(fun: 75, mood: .bored)
        #expect(AutonomyPicker.weights(bored)[.move] == 6)
        #expect(AutonomyPicker.weights(bored)[.signature] == 2)

        var typing = context(); typing.heavyTyping = true; typing.platformReachable = true
        #expect(AutonomyPicker.weights(typing) == [.idle: 6, .move: 0, .perch: 0, .rest: 1, .signature: 0])

        var lowPower = context(); lowPower.lowPowerMode = true
        #expect(AutonomyPicker.weights(lowPower).filter { $0.value > 0 }.keys.sorted { $0.rawValue < $1.rawValue } == [.idle])
    }

    @Test func userAwayForcesRest() {
        var p = AutonomyPicker(seed: 3)
        var c = context(idleRun: 0); c.userAway = 600
        #expect(p.pick(c) == .rest)
    }

    /// SPEC §14: a fixed seed and a scripted world replay the same choices.
    @Test func seededRunMatchesSnapshot() {
        func run() -> [AutonomyChoice] {
            var p = AutonomyPicker(seed: 2026)
            var out: [AutonomyChoice] = []
            var idleRun: TimeInterval = 0
            for step in 0..<40 {
                var c = context(idleRun: idleRun, energy: step < 20 ? 80 : 20, mood: step < 20 ? .content : .tired)
                c.platformReachable = step % 3 == 0
                let choice = p.pick(c)
                out.append(choice)
                idleRun = choice == .idle ? idleRun + 5 : 0
            }
            return out
        }
        let a = run()
        #expect(a == run())
        #expect(a.map(\.rawValue).joined(separator: " ") == AutonomySnapshot.seed2026)
    }
}

@Suite struct EmotionTests {
    @Test func burstReplacesAndExpires() {
        var e = EmotionEngine()
        e.trigger(.happy, at: now)
        #expect(e.current(at: now.addingTimeInterval(3), sleepy: false)?.kind == .happy)
        e.trigger(.startled, at: now.addingTimeInterval(1))
        #expect(e.current(at: now.addingTimeInterval(2), sleepy: false)?.kind == .startled)
        #expect(e.current(at: now.addingTimeInterval(3.5), sleepy: false) == nil)
        #expect(e.current(at: now.addingTimeInterval(3.5), sleepy: true)?.kind == .sleepy)
        #expect(e.nextChange(after: now.addingTimeInterval(2)) == now.addingTimeInterval(3))
    }

    @Test func sleepyConditions() {
        #expect(SleepyConditions(energy: 80, localHour: 23, lowBatteryNotCharging: false).holds)
        #expect(SleepyConditions(energy: 80, localHour: 5, lowBatteryNotCharging: false).holds)
        #expect(!SleepyConditions(energy: 80, localHour: 6, lowBatteryNotCharging: false).holds)
        #expect(SleepyConditions(energy: 24, localHour: 12, lowBatteryNotCharging: false).holds)
        #expect(SleepyConditions(energy: 80, localHour: 12, lowBatteryNotCharging: true).holds)
    }

    @Test func pokeRules() {
        var p = PokeTracker()
        #expect(p.poke(at: now, asleep: false) == .poke)
        #expect(p.poke(at: now.addingTimeInterval(1), asleep: false) == .poke)
        #expect(p.poke(at: now.addingTimeInterval(3.9), asleep: false) == .annoyed)
        #expect(p.poke(at: now.addingTimeInterval(4), asleep: false) == .poke)
        #expect(p.poke(at: now.addingTimeInterval(9), asleep: false) == .poke)
        #expect(p.poke(at: now.addingTimeInterval(14), asleep: false) == .poke)
        #expect(p.poke(at: now.addingTimeInterval(15), asleep: true) == .wokenUp)
    }
}

@Suite struct ActivityTests {
    @Test func heavyTypingNeedsFiveSustainedSeconds() {
        var t = TypingDetector()
        // 4 s at 3/s: not yet.
        for s in 0..<4 { for k in 0..<3 { t.keyDown(at: now.addingTimeInterval(Double(s) + Double(k) * 0.3)) } }
        #expect(!t.isQuiet(at: now.addingTimeInterval(4)))
        for k in 0..<3 { t.keyDown(at: now.addingTimeInterval(4 + Double(k) * 0.3)) }
        #expect(t.isQuiet(at: now.addingTimeInterval(5)))
        #expect(t.isQuiet(at: now.addingTimeInterval(14.5)))
        #expect(!t.isQuiet(at: now.addingTimeInterval(14.7)))
    }

    @Test func slowTypingNeverTriggers() {
        var t = TypingDetector()
        for i in 0..<60 { t.keyDown(at: now.addingTimeInterval(Double(i) * 0.5)) }
        #expect(!t.isQuiet(at: now.addingTimeInterval(30)))
    }

    @Test func mischiefGateAndSchedule() {
        var gate = MischiefGate(userAway: 119)
        #expect(!gate.isOpen)
        gate.userAway = 120
        #expect(gate.isOpen)
        gate.heavyTyping = true
        #expect(!gate.isOpen)

        var s = MischiefScheduler(level: .normal, seed: 9)
        s.schedule(from: now)
        let due = s.nextDue!
        #expect((now.addingTimeInterval(1200)...now.addingTimeInterval(2400)).contains(due))
        #expect(!s.isDue(at: due.addingTimeInterval(-1), gate: MischiefGate(userAway: 300)))
        #expect(s.isDue(at: due, gate: MischiefGate(userAway: 300)))

        var chill = MischiefScheduler(level: .chill, seed: 9)
        chill.schedule(from: now)
        #expect(chill.nextDue == nil)
        #expect(chill.pickAct(at: now).map { $0.levels.contains(.normal) } == true)

        var chaos = MischiefScheduler(level: .chaos, seed: 9)
        let acts = Set((0..<200).compactMap { _ in chaos.pickAct(at: now) })
        #expect(acts == Set(MischiefAct.allCases))
        #expect(chaos.pickAct(at: now, available: [.dockHop]) == .dockHop)
        #expect(s.pickAct(at: now, available: [.dockHop]) == nil)
    }
}
