import Foundation

/// What the Pixl is physically doing (SPEC §4.2). Exactly one at a time.
public enum Mode: String, Sendable, Equatable, Codable {
    case grounded, airborne, held, riding, hanging, traveling, hidden

    /// Slots (and which of their frames) each mode may show.
    public var allowedFrames: [Slot: Set<Int>] {
        switch self {
        case .grounded:
            [.idle: [0, 1, 2], .rest: [0, 1, 2], .poke: [0, 1, 2], .signature: [0, 1, 2],
             .mischief: [0, 1, 2], .perch: [2], .move: [0, 2]]
        case .airborne: [.move: [1], .grab: [2]]
        case .held: [.grab: [0, 1]]
        case .riding: [.fileRide: [0, 1, 2]]
        case .hanging: [.perch: [1], .rest: [0, 1, 2]]
        case .traveling, .hidden: [:]
        }
    }

    public func allows(_ slot: Slot, frame: Int) -> Bool { allowedFrames[slot]?.contains(frame) ?? false }
}

/// Things that interrupt (SPEC §4.3). Lower `rawValue` = higher priority.
public enum Reaction: Int, Sendable, Comparable, CaseIterable {
    case hideOrTravel = 1, grabbed, platformVanished, keepOutViolated, poke, fileDrag, systemEvent, autonomy

    public static func < (a: Reaction, b: Reaction) -> Bool { a.rawValue < b.rawValue }

    /// A reaction may replace the running one only if it's at least as important.
    public func canInterrupt(_ running: Reaction?) -> Bool {
        guard let running else { return true }
        return rawValue <= running.rawValue
    }
}

public enum AutonomyChoice: String, Sendable, Equatable, CaseIterable {
    case idle, move, perch, rest, signature
}

/// Everything autonomy looks at. The platform layer fills it in when the current slot finishes.
public struct AutonomyContext: Sendable {
    public var now: Date
    public var needs: [NeedKind: Double]
    public var mood: Mood
    /// The `sleepy` state (SPEC §5) holds.
    public var sleepy = false
    /// How long the current run of idles has lasted.
    public var idleRun: TimeInterval
    /// No mouse/keyboard input for this long.
    public var userAway: TimeInterval = 0
    public var moveTargetAvailable = true
    public var platformReachable = false
    public var lastSignature: Date?
    public var heavyTyping = false
    public var focusSession = false
    public var lowPowerMode = false

    public init(now: Date, needs: [NeedKind: Double], mood: Mood, idleRun: TimeInterval) {
        self.now = now
        self.needs = needs
        self.mood = mood
        self.idleRun = idleRun
    }
}

/// Weighted autonomy (SPEC §4.3). Deterministic for a given seed.
public struct AutonomyPicker: Sendable {
    public static let idleBudget: ClosedRange<TimeInterval> = 8...40
    public static let signatureCooldown: TimeInterval = 10 * 60
    public static let forcedRestAfter: TimeInterval = 10 * 60

    public var rng: SeededRandom
    /// How long the current idle run must last before anything else may be picked.
    public private(set) var budget: TimeInterval

    public init(seed: UInt64) {
        rng = SeededRandom(seed: seed)
        budget = 0
        budget = Double.random(in: Self.idleBudget, using: &rng)
    }

    /// The weights before the RNG draws. Exposed for tests and debugging.
    public static func weights(_ c: AutonomyContext) -> [AutonomyChoice: Double] {
        var w: [AutonomyChoice: Double] = [
            .idle: 6,
            .move: (c.needs[.energy] ?? 0) >= 25 && c.moveTargetAvailable ? 3 : 0,
            .perch: c.platformReachable ? 2 : 0,
            .rest: 1,
            .signature: (c.needs[.fun] ?? 0) >= 70 && c.lastSignature.map { c.now.timeIntervalSince($0) >= signatureCooldown } ?? true ? 1 : 0,
        ]
        if c.mood == .tired || c.sleepy { w[.rest]! *= 4 }
        if c.mood == .bored {
            w[.move]! *= 2
            w[.signature]! *= 2
        }
        if c.heavyTyping || c.focusSession {
            w[.move] = 0
            w[.perch] = 0
            w[.signature] = 0
        }
        if c.lowPowerMode {
            for k in w.keys where k != .idle { w[k] = 0 }
        }
        return w
    }

    /// Picks the next thing to do. Call when the current slot finishes and the Pixl is Grounded.
    public mutating func pick(_ c: AutonomyContext) -> AutonomyChoice {
        if c.userAway >= Self.forcedRestAfter && !c.lowPowerMode { return finish(.rest) }
        if c.idleRun < budget { return .idle }
        let w = Self.weights(c)
        let order = AutonomyChoice.allCases
        let i = rng.weightedIndex(order.map { w[$0] ?? 0 }) ?? 0
        return finish(order[i])
    }

    /// A new idle run starts after anything that isn't idle; it gets a fresh budget.
    private mutating func finish(_ choice: AutonomyChoice) -> AutonomyChoice {
        if choice != .idle { budget = Double.random(in: Self.idleBudget, using: &rng) }
        return choice
    }
}
