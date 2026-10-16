import Foundation

/// The current emotion as saved in PetState (SPEC §5, §10.1). `until == nil` means a state that lasts
/// while its conditions hold (`sleepy`).
public struct EmotionState: Codable, Equatable, Sendable {
    public var kind: Emotion
    public var until: Date?

    public init(kind: Emotion, until: Date?) {
        self.kind = kind
        self.until = until
    }
}

extension Emotion {
    /// Burst length in seconds; nil for `sleepy`, which is a state.
    public var duration: TimeInterval? {
        switch self {
        case .happy: 4
        case .annoyed: 5
        case .sleepy: nil
        case .startled: 2
        case .curious: 3
        case .proud: 4
        }
    }

    /// The FX shown above the head (SPEC §8).
    public var effect: Effect {
        switch self {
        case .happy: .heart
        case .annoyed: .sweat
        case .sleepy: .zz
        case .startled: .bang
        case .curious: .questionMark
        case .proud: .sparkle
        }
    }
}

/// Conditions for the `sleepy` state (SPEC §5).
public struct SleepyConditions: Sendable, Equatable {
    public var energy: Double
    /// 0–23, local time.
    public var localHour: Int
    public var lowBatteryNotCharging: Bool

    public init(energy: Double, localHour: Int, lowBatteryNotCharging: Bool) {
        self.energy = energy
        self.localHour = localHour
        self.lowBatteryNotCharging = lowBatteryNotCharging
    }

    public var holds: Bool { energy < 25 || localHour >= 23 || localHour < 6 || lowBatteryNotCharging }
}

/// One emotion at a time; a new burst replaces the old one. When a burst ends, `sleepy` shows if it holds.
public struct EmotionEngine: Sendable, Equatable {
    public private(set) var burst: EmotionState?

    public init(saved: EmotionState? = nil) {
        burst = saved?.until == nil ? nil : saved
    }

    public mutating func trigger(_ e: Emotion, at now: Date) {
        guard let d = e.duration else { return }
        burst = EmotionState(kind: e, until: now.addingTimeInterval(d))
    }

    /// What shows at `now`.
    public func current(at now: Date, sleepy: Bool) -> EmotionState? {
        if let b = burst, let until = b.until, now < until { return b }
        return sleepy ? EmotionState(kind: .sleepy, until: nil) : nil
    }

    /// When the visible emotion next changes on its own, for a one-shot timer. Nil = nothing scheduled.
    public func nextChange(after now: Date) -> Date? {
        guard let until = burst?.until, until > now else { return nil }
        return until
    }
}

/// Poke rules (SPEC §11.1): 3 pokes within 4 s → annoyed; a poke while asleep → startled, then annoyed.
public struct PokeTracker: Sendable, Equatable {
    public static let window: TimeInterval = 4
    public static let annoyedAfter = 3
    private var recent: [Date] = []

    public init() {}

    public enum Outcome: Equatable, Sendable {
        case poke
        case annoyed
        /// Startled now, annoyed when the startle ends.
        case wokenUp
    }

    public mutating func poke(at now: Date, asleep: Bool) -> Outcome {
        recent = recent.filter { now.timeIntervalSince($0) < Self.window } + [now]
        if asleep {
            recent.removeAll()
            return .wokenUp
        }
        if recent.count >= Self.annoyedAfter {
            recent.removeAll()
            return .annoyed
        }
        return .poke
    }
}
