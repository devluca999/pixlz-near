import Foundation

/// FX kinds (SPEC §8). The FX layer draws these; PixlzCore only names them.
public enum Effect: String, Sendable, CaseIterable, Codable {
    case dust, puff, speedLines, zz, bang, sweat, sparkle, heart, questionMark, splash, ripple, aura
}

/// Heavy-typing detection from key-down *counts* only; key identities are never seen (D12, SPEC §6.2).
/// No polling: feed it key-down times; ask it when deciding; schedule one timer for `quietUntil`.
public struct TypingDetector: Sendable, Equatable {
    /// Key-downs per second that count as heavy.
    public static let rate = 3
    /// Seconds the rate must be sustained.
    public static let sustain = 5
    /// Quiet lasts this long after the last heavy second.
    public static let quietAfter: TimeInterval = 10

    /// Key-down counts per whole second (unix seconds), only the last `sustain` kept.
    private var buckets: [Int: Int] = [:]
    public private(set) var quietUntil: Date?

    public init() {}

    public mutating func keyDown(at t: Date) {
        let s = Int(t.timeIntervalSince1970.rounded(.down))
        buckets[s, default: 0] += 1
        buckets = buckets.filter { $0.key > s - Self.sustain }
        // The current second counts once it has reached the rate.
        let sustained = (0..<Self.sustain).allSatisfy { buckets[s - $0, default: 0] >= Self.rate }
        if sustained { quietUntil = t.addingTimeInterval(Self.quietAfter) }
    }

    /// Autonomy is quiet (no moves, signature or mischief) until 10 s after heavy typing stops.
    public func isQuiet(at now: Date) -> Bool { quietUntil.map { now < $0 } ?? false }
}

public enum MischiefLevel: String, Sendable, Codable, CaseIterable {
    case chill, normal, chaos

    /// Gap between autonomous acts (SPEC §9). Nil = never on its own.
    public var interval: ClosedRange<TimeInterval>? {
        switch self {
        case .chill: nil
        case .normal: (20 * 60)...(40 * 60)
        case .chaos: (5 * 60)...(10 * 60)
        }
    }
}

/// Frogg's acts (SPEC §9). Species-specific sets come later with more Pixls.
public enum MischiefAct: String, Sendable, CaseIterable {
    case pond, tongueSnatch, titleBarNap, iconLick, dockHop, ghostDrag

    public var levels: Set<MischiefLevel> {
        switch self {
        case .pond, .tongueSnatch, .titleBarNap, .iconLick: [.normal, .chaos]
        case .dockHop, .ghostDrag: [.chaos]
        }
    }
}

/// What can block mischief right now.
public struct MischiefGate: Sendable, Equatable {
    public var userAway: TimeInterval
    public var focusSession = false
    public var fullscreen = false
    public var heavyTyping = false
    public var lowPowerMode = false
    public var tired = false

    public init(userAway: TimeInterval) { self.userAway = userAway }

    /// Mischief needs ≥ 2 min with no input and nothing forbidding it (SPEC §9, §2.3).
    public var isOpen: Bool {
        userAway >= 120 && !focusSession && !fullscreen && !heavyTyping && !lowPowerMode && !tired
    }
}

/// When the next autonomous mischief is due. One timer, never polled.
public struct MischiefScheduler: Sendable {
    public var level: MischiefLevel
    public private(set) var nextDue: Date?
    public var rng: SeededRandom

    public init(level: MischiefLevel, seed: UInt64) {
        self.level = level
        rng = SeededRandom(seed: seed)
    }

    /// Call at launch, after each act, and when the level changes.
    public mutating func schedule(from now: Date) {
        nextDue = level.interval.map { now.addingTimeInterval(Double.random(in: $0, using: &rng)) }
    }

    public func isDue(at now: Date, gate: MischiefGate) -> Bool {
        guard let due = nextDue else { return false }
        return now >= due && gate.isOpen
    }

    /// Picks an act for the current level, given which acts the world allows right now
    /// (e.g. no `iconLick` without desktop icons). Reschedules.
    public mutating func pickAct(at now: Date, available: Set<MischiefAct> = Set(MischiefAct.allCases)) -> MischiefAct? {
        // Chill only gets mischief on request; it uses the Normal set.
        let level = self.level == .chill ? .normal : self.level
        let acts = MischiefAct.allCases.filter { $0.levels.contains(level) && available.contains($0) }
        defer { schedule(from: now) }
        return acts.randomElement(using: &rng)
    }
}
