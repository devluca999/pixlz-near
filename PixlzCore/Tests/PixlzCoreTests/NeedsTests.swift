import Foundation
import Testing
@testable import PixlzCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

@Suite struct NeedsTests {
    @Test func passiveDecayFromTimestamps() {
        let needs = Needs.fresh(at: t0, value: 80)
        let v = needs.values(at: hours(2))
        #expect(v[.energy] == 72)
        #expect(v[.fun] == 64)
        #expect(v[.affection] == 68)
    }

    @Test func clampsAtZeroWhileRunningAndHundredAlways() {
        let n = NeedValue(value: 10, updatedAt: t0, rate: -8)
        #expect(n.value(at: hours(10)) == 0)
        let up = NeedValue(value: 90, updatedAt: t0, rate: 30)
        #expect(up.value(at: hours(5)) == 100)
    }

    @Test func timeBeforeUpdatedAtCountsAsZero() {
        let n = NeedValue(value: 50, updatedAt: t0, rate: -8)
        #expect(n.value(at: hours(-3)) == 50)
    }

    @Test func offlineFloorStopsAtTwentyButDoesNotLift() {
        var needs = Needs.fresh(at: t0, value: 80)
        needs.affection.value = 12
        needs.resumeAfterOffline(at: hours(24 * 7))
        #expect(needs.energy.value == 20)
        #expect(needs.fun.value == 20)
        #expect(needs.affection.value == 12)
        #expect(needs.energy.updatedAt == hours(24 * 7))
    }

    @Test func rateChangeFoldsElapsedTime() {
        var needs = Needs.fresh(at: t0, value: 50)
        needs.apply(NeedConditions(activity: .resting), at: hours(1))
        #expect(needs.energy.value == 46)
        #expect(needs.energy.rate == 26)
        #expect(needs.energy.value(at: hours(2)) == 72)
    }

    @Test func rates() {
        #expect(Needs.rates(for: .init())[.energy] == -4)
        #expect(Needs.rates(for: .init(lowBattery: true))[.energy] == -8)
        #expect(Needs.rates(for: .init(charging: true, lowBattery: true))[.energy] == 1)
        #expect(Needs.rates(for: .init(activity: .moving))[.energy] == -14)
        #expect(Needs.rates(for: .init(activity: .mischief))[.energy] == -10)
        #expect(Needs.rates(for: .init(activity: .resting, charging: true))[.energy] == 31)
    }

    @Test func eventsRiseInstantlyAndCap() {
        var needs = Needs.fresh(at: t0, value: 98)
        needs.record(.poke, at: hours(0.25))
        #expect(needs.fun.value == 99)          // 98 − 2 decay + 3
        #expect(needs.affection.value == 100)   // 98 − 1.5 + 4, capped
        #expect(needs.energy.value == 98)       // not folded: no boost
        needs.record(.travel, at: hours(0.25))
        #expect(needs.fun.value == 100)
    }

    @Test func moodLowestNeedDecides() {
        func mood(_ e: Double, _ f: Double, _ a: Double) -> Mood {
            Needs(
                energy: .init(value: e, updatedAt: t0, rate: 0),
                fun: .init(value: f, updatedAt: t0, rate: 0),
                affection: .init(value: a, updatedAt: t0, rate: 0)
            ).mood(at: t0)
        }
        #expect(mood(80, 80, 80) == .content)
        #expect(mood(40, 40, 40) == .content)
        #expect(mood(24, 80, 80) == .tired)
        #expect(mood(80, 29, 80) == .bored)
        #expect(mood(80, 80, 29) == .lonely)
        #expect(mood(24, 10, 80) == .bored)
        #expect(mood(20, 20, 20) == .tired)
    }

    @Test func codableRoundTrip() throws {
        let needs = Needs.fresh(at: t0)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(Needs.self, from: enc.encode(needs))
        #expect(back == needs)
    }
}
