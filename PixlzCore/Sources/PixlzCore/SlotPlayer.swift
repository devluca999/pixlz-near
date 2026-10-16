import Foundation

/// Plays one slot's 3-frame strip on the 12 fps clock (SPEC §4.4).
///
/// The renderer never ticks blindly: it asks `ticksUntilNextChange` and schedules one wake-up for then.
/// `nil` means the frame is held until something external happens, so a held frame costs no CPU.
public struct SlotPlayer: Sendable, Equatable {
    public static let fps: Double = 12
    public static let tick: TimeInterval = 1 / fps

    public let slot: Slot
    public let spec: SlotSpec
    public private(set) var frame: Int = 0
    /// Ticks already spent on the current frame.
    public private(set) var elapsed: Int = 0
    /// Full passes through frames 0→2 (only grows for `loop: all`).
    public private(set) var cycles: Int = 0
    /// True once a `none` slot has shown its last frame for its hold, or an ended slot has played out.
    public private(set) var isFinished = false
    private var ending = false
    private var released = false

    public init(slot: Slot, spec: SlotSpec, startFrame: Int = 0) {
        self.slot = slot
        self.spec = spec
        self.frame = startFrame
    }

    /// Ticks until the frame changes, or nil if it's held until `release()`, `end()` or forever.
    public var ticksUntilNextChange: Int? {
        if isFinished || isHeldOpen { return nil }
        return max(1, spec.holds[frame] - elapsed)
    }

    /// A frame with hold 0 waiting for physics, or a looping frame waiting for `end()`.
    private var isHeldOpen: Bool {
        if spec.holds[frame] == 0 && !released { return true }
        if ending { return false }
        switch spec.loop {
        case .middle: return frame == 1
        case .last: return frame == 2
        case .none, .all: return false
        }
    }

    /// Advances the clock. Returns true if the visible frame changed.
    @discardableResult
    public mutating func advance(ticks: Int = 1) -> Bool {
        let start = frame
        var remaining = ticks
        while remaining > 0, let left = ticksUntilNextChange {
            let step = min(left, remaining)
            elapsed += step
            remaining -= step
            if step == left { nextFrame() }
        }
        return frame != start
    }

    /// Lets a physics-held frame (hold 0) move on, e.g. on landing.
    public mutating func release() {
        guard spec.holds[frame] == 0 else { return }
        released = true
        nextFrame()
    }

    /// Ends a looping slot. `middle` jumps to frame 2 and plays it (grab → drop); `last` finishes at once
    /// if frame 2 is already up (wake from rest); `all` finishes at the end of the current pass.
    public mutating func end() {
        ending = true
        switch spec.loop {
        case .last where frame == 2: isFinished = true
        case .middle where frame == 1: nextFrame()
        default: break
        }
    }

    private mutating func nextFrame() {
        elapsed = 0
        released = false
        switch frame {
        case 0, 1:
            frame += 1
        default:
            if spec.loop == .all && !ending {
                frame = 0
                cycles += 1
            } else {
                isFinished = true
            }
        }
    }
}
