import CoreGraphics
import Foundation

/// How the Pixl reacts to you, from timing and the cursor only (SPEC §6.2; research rules in
/// docs/PRODUCT-NOTES.md §3). Pure: the app feeds it samples ~4 times a second.
public struct Presence: Sendable {
    public enum Mood: Equatable, Sendable { case awake, typing, napping, waking }
    public enum Reaction: Equatable, Sendable { case none, look(left: Bool), startle }

    /// You're typing if a key went down this recently.
    public static let typingWindow: TimeInterval = 1.5
    /// No keyboard or mouse for this long: the Pixl naps.
    public static let napAfter: TimeInterval = 60
    /// The wake-up yawn.
    public static let wakeTime: TimeInterval = 0.8
    /// The cursor is "near" within this distance of the Pixl's head.
    public static let lookRadius: CGFloat = 200
    /// A fast pass this close (pt) and this fast (pt/s) startles it, at most once per cooldown.
    public static let startleRadius: CGFloat = 130
    public static let startleSpeed: CGFloat = 1600
    public static let startleCooldown: TimeInterval = 8

    public private(set) var mood: Mood = .awake
    var wokeAt: TimeInterval = -.infinity
    var lastStartle: TimeInterval = -.infinity
    var lastCursor: (CGPoint, TimeInterval)?
    var facingLeft: Bool?

    public init() {}

    /// Seconds since the last key press and since any input (keys, mouse, trackpad).
    public mutating func activity(sinceKey: TimeInterval, sinceAny: TimeInterval, at t: TimeInterval) -> Mood {
        switch mood {
        case .napping where sinceAny < 1:
            mood = .waking; wokeAt = t
        case .waking where t - wokeAt >= Self.wakeTime:
            mood = .awake
        case .waking:
            break
        default:
            if sinceAny >= Self.napAfter { mood = .napping }
            else { mood = sinceKey < Self.typingWindow ? .typing : .awake }
        }
        return mood
    }

    /// The cursor at `p` (same coordinates as `head`) at time `t`.
    public mutating func cursor(_ p: CGPoint, head: CGPoint, at t: TimeInterval) -> Reaction {
        defer { lastCursor = (p, t) }
        guard mood == .awake || mood == .typing else { return .none }   // asleep or yawning: no reaction
        let d = hypot(p.x - head.x, p.y - head.y)
        if let (q, t0) = lastCursor, t > t0 {
            let speed = hypot(p.x - q.x, p.y - q.y) / CGFloat(t - t0)
            if d < Self.startleRadius, speed > Self.startleSpeed, t - lastStartle >= Self.startleCooldown {
                lastStartle = t
                return .startle
            }
        }
        guard d < Self.lookRadius, abs(p.x - head.x) > 12 else { return .none }
        let left = p.x < head.x
        guard left != facingLeft else { return .none }   // only report a change
        facingLeft = left
        return .look(left: left)
    }

    /// Forget which way it faced (it hopped, or a menu took over).
    public mutating func resetFacing() { facingLeft = nil }
}
