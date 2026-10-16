import Foundation

/// The three needs (SPEC §2). Higher is more satisfied; each is 0...100.
public enum NeedKind: String, Codable, CaseIterable, Sendable {
    case energy, fun, affection
}

/// One need as stored in PetState: the value at `updatedAt` and the rate (per hour) since then.
/// Needs are never ticked; the current value is computed from the timestamp (SPEC §2.2).
public struct NeedValue: Codable, Equatable, Sendable {
    public var value: Double
    public var updatedAt: Date
    /// Change per hour of real time.
    public var rate: Double

    public init(value: Double, updatedAt: Date, rate: Double) {
        self.value = value
        self.updatedAt = updatedAt
        self.rate = rate
    }

    /// `clamp(stored + rate × hours(now − updatedAt), floor, 100)`. Time before `updatedAt` counts as zero.
    /// `floor` never lifts a value that was already below it.
    public func value(at now: Date, floor: Double = 0) -> Double {
        let hours = max(0, now.timeIntervalSince(updatedAt)) / 3600
        let raw = value + rate * hours
        return Needs.clamp(raw, lower: min(floor, value), upper: 100)
    }

    /// Folds the elapsed time into `value` and restarts the clock at `now` with a new rate.
    public mutating func fold(at now: Date, newRate: Double? = nil, floor: Double = 0) {
        value = value(at: now, floor: floor)
        updatedAt = max(updatedAt, now)
        if let newRate { rate = newRate }
    }
}

/// What the Pixl is doing, as far as need rates care.
public enum NeedActivity: Sendable, Equatable {
    case idle, moving, resting, mischief
}

/// The inputs that set need rates. Rates change only when one of these changes (SPEC §2.2).
public struct NeedConditions: Sendable, Equatable {
    public var activity: NeedActivity
    public var charging: Bool
    /// Battery below 20%. Ignored while charging.
    public var lowBattery: Bool

    public init(activity: NeedActivity = .idle, charging: Bool = false, lowBattery: Bool = false) {
        self.activity = activity
        self.charging = charging
        self.lowBattery = lowBattery
    }
}

/// One-off events that raise needs instantly (SPEC §2.1 "Recovery").
public enum NeedEvent: Sendable, Equatable, CaseIterable {
    case poke, grab, throwRelease, fileRide, signature, doubleClick, mischief, travel, callOrReceive, focusCompleted

    /// The instant rise per need.
    public var boosts: [NeedKind: Double] {
        switch self {
        case .poke: [.fun: 3, .affection: 4]
        case .grab: [.affection: 5]
        case .throwRelease: [.fun: 6]
        case .fileRide: [.fun: 10]
        case .signature: [.fun: 8]
        case .doubleClick: [.affection: 6]
        case .mischief: [.fun: 12]
        case .travel: [.fun: 15]
        case .callOrReceive: [.affection: 10]
        case .focusCompleted: [.fun: 10]
        }
    }
}

/// The derived mood (SPEC §2.3). Not stored.
public enum Mood: String, Sendable, Equatable {
    case content, tired, bored, lonely
}

/// All three needs. Encodes as the `needs` object of PetState (SPEC §10.1).
public struct Needs: Codable, Equatable, Sendable {
    /// Time while the app wasn't running or the device slept can't take a need below this (SPEC §2.2).
    public static let offlineFloor: Double = 20

    public var energy: NeedValue
    public var fun: NeedValue
    public var affection: NeedValue

    public init(energy: NeedValue, fun: NeedValue, affection: NeedValue) {
        self.energy = energy
        self.fun = fun
        self.affection = affection
    }

    /// A fresh Pixl: everything at `value`, passive rates.
    public static func fresh(at now: Date, value: Double = 80) -> Needs {
        let r = rates(for: NeedConditions())
        return Needs(
            energy: NeedValue(value: value, updatedAt: now, rate: r[.energy]!),
            fun: NeedValue(value: value, updatedAt: now, rate: r[.fun]!),
            affection: NeedValue(value: value, updatedAt: now, rate: r[.affection]!)
        )
    }

    public subscript(kind: NeedKind) -> NeedValue {
        get {
            switch kind {
            case .energy: energy
            case .fun: fun
            case .affection: affection
            }
        }
        set {
            switch kind {
            case .energy: energy = newValue
            case .fun: fun = newValue
            case .affection: affection = newValue
            }
        }
    }

    /// Per-hour rates (SPEC §2.1). Activity and charging terms add to the passive drop.
    public static func rates(for c: NeedConditions) -> [NeedKind: Double] {
        var energy: Double = -4
        if c.lowBattery && !c.charging { energy *= 2 }
        switch c.activity {
        case .idle: break
        case .moving: energy += -10
        case .mischief: energy += -6
        case .resting: energy += 30
        }
        if c.charging { energy += 5 }
        return [.energy: energy, .fun: -8, .affection: -6]
    }

    /// Current values at `now`.
    public func values(at now: Date) -> [NeedKind: Double] {
        Dictionary(uniqueKeysWithValues: NeedKind.allCases.map { ($0, self[$0].value(at: now)) })
    }

    /// Call when conditions change: folds elapsed time at the old rates, then switches to the new ones.
    public mutating func apply(_ conditions: NeedConditions, at now: Date) {
        let r = Self.rates(for: conditions)
        for kind in NeedKind.allCases { self[kind].fold(at: now, newRate: r[kind]!) }
    }

    /// Call on launch, wake or iOS foreground: folds the time the app wasn't running, with the offline floor.
    public mutating func resumeAfterOffline(at now: Date) {
        for kind in NeedKind.allCases { self[kind].fold(at: now, floor: Self.offlineFloor) }
    }

    /// Applies an instant rise, capped at 100.
    public mutating func record(_ event: NeedEvent, at now: Date) {
        for (kind, boost) in event.boosts {
            self[kind].fold(at: now)
            self[kind].value = Self.clamp(self[kind].value + boost, lower: 0, upper: 100)
        }
    }

    /// The lowest need below its threshold decides the mood; ties go energy → fun → affection.
    public func mood(at now: Date) -> Mood {
        let v = values(at: now)
        let rules: [(mood: Mood, value: Double, threshold: Double)] = [
            (.tired, v[.energy]!, 25),
            (.bored, v[.fun]!, 30),
            (.lonely, v[.affection]!, 30),
        ]
        let low = rules.filter { $0.value < $0.threshold }
        return low.min { $0.value < $1.value }?.mood ?? .content
    }

    static func clamp(_ x: Double, lower: Double, upper: Double) -> Double {
        Swift.min(Swift.max(x, lower), upper)
    }
}
