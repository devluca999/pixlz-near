import Foundation

/// When and how a Pixl sleeps and wakes (SPEC §2 needs, §4.2 modes, §6.2 activity). Pure: the
/// app feeds it time, input timing and what you did; it answers with stage changes and small
/// reactions to play. Times are seconds on any monotonic clock.
///
/// - Falls asleep when you've been away (no keyboard or mouse) for the Sleepiness threshold,
///   and takes short naps every ~45–90 min of activity (when its energy has dropped enough).
///   While you type it rests quietly but never falls asleep.
/// - Stages: drowsy (~20 s, easy to rouse) → asleep → deep (after ~10 min).
/// - Sleeps at least ~90 s unless you deliberately wake it (poke, menu click, hotkey, Focus end).
public struct SleepCycle: Sendable {
    public enum Stage: String, Sendable, Equatable {
        case awake, resting, drowsy, asleep, deep, waking
        public var sleeping: Bool { self == .asleep || self == .deep }
        /// Drowsy or asleep: no hopping, no outings.
        public var dozing: Bool { self == .drowsy || sleeping }
    }

    public enum Sleepiness: String, CaseIterable, Sendable {
        case nightOwl, normal, sleepy
        /// How long you're away before it nods off.
        public var awayThreshold: TimeInterval { switch self { case .nightOwl: 600; case .normal: 300; case .sleepy: 120 } }
        /// Activity naps come this much more (or less) often.
        public var napScale: Double { switch self { case .nightOwl: 1.6; case .normal: 1; case .sleepy: 0.45 } }
        public var title: String { switch self { case .nightOwl: "Night owl"; case .normal: "Normal"; case .sleepy: "Sleepy" } }
    }

    /// Why it's asleep: you're away, or a nap during your activity.
    public enum Cause: String, Sendable, Equatable { case away, nap }

    /// What happened near it.
    public enum Input: String, Sendable, Equatable {
        case cursorNear, hoverStart, hoverEnd, poke, menuClick, grab, release, windowSwitch, notification, hotkey, focusEnded
    }

    /// What to play.
    public enum Reaction: String, Sendable, Equatable {
        case stir, eyeOpen, eyeClose, startled, grumpy, wakeAndMenu, stretchYawn, earTwitch, wake
    }

    public enum Output: Sendable, Equatable {
        case stage(from: Stage, to: Stage, why: String)
        case react(Reaction)
    }

    // timings
    public static let drowsyTime: TimeInterval = 20
    public static let deepAfter: TimeInterval = 600
    public static let minimumSleep: TimeInterval = 90
    public static let returnDelay: TimeInterval = 4        // wakes on its own a few seconds after you're back
    public static let hoverEyeOpen: TimeInterval = 2
    public static let hoverWake: TimeInterval = 4          // with "Let me wake them by hovering"
    public static let napLength: ClosedRange<TimeInterval> = 120...240
    public static let startledTime: TimeInterval = 0.6
    public static let grumpyTime: TimeInterval = 1.2
    public static let stretchTime: TimeInterval = 1.6
    /// Energy (PixlzCore Needs, about −4 an hour while awake) that drops between naps:
    /// 3 to 6 points is ~45 to 90 minutes.
    public static let napDrop: ClosedRange<Double> = 3...6

    public var sleepiness: Sleepiness
    public var hoverWakes: Bool
    public private(set) var stage: Stage = .awake
    public private(set) var cause: Cause?
    public private(set) var stageSince: TimeInterval
    public private(set) var sleptAt: TimeInterval?
    var energyAtWake: Double?
    var napDue: Double
    var napEnds: TimeInterval?
    var wakeAt: TimeInterval?          // you're back: it wakes on its own at this time
    var wakeStyle: Reaction = .stretchYawn
    var hoverSince: TimeInterval?
    var eyeOpen = false
    var rng: SeededRandom

    public init(at t: TimeInterval, sleepiness: Sleepiness = .normal, hoverWakes: Bool = false, seed: UInt64 = 1) {
        self.sleepiness = sleepiness
        self.hoverWakes = hoverWakes
        stageSince = t
        rng = SeededRandom(seed: seed)
        napDue = Double.random(in: Self.napDrop, using: &rng) * sleepiness.napScale
    }

    /// Energy points to lose before the next nap.
    public var napDropNeeded: Double { napDue }

    // MARK: time passing

    /// Call a few times a second. `sinceInput`: seconds since any keyboard or mouse input;
    /// `typing`: a key went down very recently; `energy`: the energy need now (0–100).
    public mutating func tick(at t: TimeInterval, sinceInput: TimeInterval, typing: Bool, energy: Double) -> [Output] {
        var out: [Output] = []
        if energyAtWake == nil { energyAtWake = energy }
        switch stage {
        case .awake, .resting:
            if sinceInput >= sleepiness.awayThreshold {
                out += go(.drowsy, at: t, why: "away \(Int(sinceInput)) s")
                cause = .away
            } else if typing {
                if stage != .resting { out += go(.resting, at: t, why: "you're typing") }
            } else if let e0 = energyAtWake, e0 - energy >= napDue {
                out += go(.drowsy, at: t, why: "nap due (energy \(Int(e0)) → \(Int(energy)))")
                cause = .nap
            } else if stage == .resting {
                out += go(.awake, at: t, why: "stopped typing")
            }
        case .drowsy:
            // easy to rouse: you coming back (if it nodded off because you were away) or typing
            if (cause == .away && sinceInput < 1) || typing {
                out += go(.awake, at: t, why: typing ? "you're typing" : "you're back")
                cause = nil
            } else if t - stageSince >= Self.drowsyTime {
                out += go(.asleep, at: t, why: "dozed off")
                sleptAt = t
                if cause == .nap { napEnds = t + Double.random(in: Self.napLength, using: &rng) }
            }
        case .asleep, .deep:
            if stage == .asleep, let s = sleptAt, t - s >= Self.deepAfter { out += go(.deep, at: t, why: "10 min asleep") }
            let slept = t - (sleptAt ?? t)
            if cause == .away, sinceInput < 1, wakeAt == nil {
                // you're back: wake on its own in a moment, but not before the minimum sleep
                wakeAt = max(t + Self.returnDelay, (sleptAt ?? t) + Self.minimumSleep)
            }
            if cause == .nap, let end = napEnds, t >= end, slept >= Self.minimumSleep { wakeAt = wakeAt ?? t }
            if let h = hoverSince {
                if !eyeOpen, t - h >= Self.hoverEyeOpen { eyeOpen = true; out.append(.react(.eyeOpen)) }
                if hoverWakes, t - h >= Self.hoverWake { out += wake(.wake, at: t, why: "hovered awake") }
            }
            if let w = wakeAt, t >= w, stage.sleeping { out += wake(.stretchYawn, at: t, why: cause == .nap ? "nap over" : "you're back") }
        case .waking:
            let length = wakeStyle == .startled ? Self.startledTime + Self.grumpyTime : wakeStyle == .stretchYawn ? Self.stretchTime : 0.3
            if wakeStyle == .startled, t - stageSince >= Self.startledTime, !grumpyShown {
                grumpyShown = true
                out.append(.react(.grumpy))
            }
            if t - stageSince >= length {
                out += go(.awake, at: t, why: "awake")
            }
        }
        return out
    }

    var grumpyShown = false

    // MARK: things you do

    public mutating func handle(_ input: Input, at t: TimeInterval) -> [Output] {
        switch stage {
        case .awake, .resting, .waking:
            return []
        case .drowsy:
            switch input {
            case .cursorNear, .hoverStart, .poke, .hotkey, .focusEnded:
                cause = nil
                return go(.awake, at: t, why: "roused (\(input.rawValue))")
            case .menuClick:
                cause = nil
                return go(.awake, at: t, why: "menu") + [.react(.wakeAndMenu)]
            default:
                return []
            }
        case .asleep, .deep:
            switch input {
            case .cursorNear: return [.react(.stir)]
            case .hoverStart:
                hoverSince = hoverSince ?? t
                return []
            case .hoverEnd:
                hoverSince = nil
                if eyeOpen { eyeOpen = false; return [.react(.eyeClose)] }
                return []
            case .poke: return wake(.startled, at: t, why: "poked")
            case .menuClick:
                return wake(.wakeAndMenu, at: t, why: "menu") + go(.awake, at: t, why: "menu")   // the menu opens at once
            case .grab, .release: return []   // dangling, still asleep
            case .windowSwitch, .notification: return [.react(.earTwitch)]
            case .hotkey, .focusEnded: return wake(.wake, at: t, why: input.rawValue)
            }
        }
    }

    // MARK: debug

    /// PIXL_DEBUG: as if you'd been away long enough, or time had passed (fast-forward).
    public mutating func debugFastForward(by seconds: TimeInterval) {
        stageSince -= seconds
        if let s = sleptAt { sleptAt = s - seconds }
        if let n = napEnds { napEnds = n - seconds }
        if let w = wakeAt { wakeAt = w - seconds }
        if let h = hoverSince { hoverSince = h - seconds }
    }

    /// PIXL_DEBUG: start a nap now.
    public mutating func debugNap(at t: TimeInterval) -> [Output] {
        guard !stage.dozing, stage != .waking else { return [] }
        cause = .nap
        return go(.drowsy, at: t, why: "debug nap")
    }

    // MARK: helpers

    mutating func go(_ s: Stage, at t: TimeInterval, why: String) -> [Output] {
        guard s != stage else { return [] }
        let from = stage
        stage = s
        stageSince = t
        if !s.dozing { sleptAt = nil; napEnds = nil; wakeAt = nil; hoverSince = nil; eyeOpen = false }
        // up from a doze, however it ended: a fresh nap baseline (the next tick takes today's energy),
        // or the drop it dozed off at would still be "due" and it would nod off again at once
        if s == .awake, from.dozing || from == .waking {
            energyAtWake = nil
            napDue = Double.random(in: Self.napDrop, using: &rng) * sleepiness.napScale
        }
        return [.stage(from: from, to: s, why: why)]
    }

    mutating func wake(_ style: Reaction, at t: TimeInterval, why: String) -> [Output] {
        wakeStyle = style
        grumpyShown = false
        cause = nil
        return go(.waking, at: t, why: why) + [.react(style)]
    }
}
