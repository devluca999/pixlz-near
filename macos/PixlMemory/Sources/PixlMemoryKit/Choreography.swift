import CoreGraphics
import Foundation
import PixlzCore

/// Which art frame each motion beat uses. Swap names here when new art lands;
/// the motion code doesn't change.
public enum MotionFrames {
    public static let notice = "poke_1"    // head turned up toward the new window
    public static let coil = "move_0"
    public static let rise = "move_1"
    /// No dedicated falling frame exists yet: the rising frame plus a falling stretch stands in.
    public static let fall = "move_1"
    public static let land = "move_2"
    public static let settle = "idle_0"
    public static let hang = "grab_0"      // peeking down from under the menu bar
    public static let dropLand = "grab_2"  // splat after a straight drop
}

/// Everything the view needs for one moment of motion.
public struct Pose: Equatable, Sendable {
    public var foot: CGPoint           // top-left global coordinates
    public var frame: String
    public var squash = CGSize(width: 1, height: 1)
    public var mirrored = false        // face left
    public var alpha: CGFloat = 1
}

/// A timeline of motion beats: sample it at any time since it started.
public struct Choreography: Sendable {
    public enum Segment: Sendable {
        case hold(at: CGPoint, frame: String, mirrored: Bool, duration: TimeInterval)
        case coil(at: CGPoint, mirrored: Bool, duration: TimeInterval)
        case flight(HopPlan, offset: TimeInterval, mirrored: Bool, frames: (rise: String, fall: String))
        case land(at: CGPoint, frame: String, mirrored: Bool, duration: TimeInterval, dust: Bool)
        case settle(at: CGPoint, duration: TimeInterval)
        case fall(from: CGPoint, to: CGPoint, duration: TimeInterval)
        case exit(from: CGPoint, rise: CGFloat, duration: TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .hold(_, _, _, let d), .coil(_, _, let d), .land(_, _, _, let d, _), .settle(_, let d),
                 .fall(_, _, let d), .exit(_, _, let d): d
            case .flight(let p, let offset, _, _): max(p.duration - offset, 0)
            }
        }
    }

    public let segments: [Segment]
    public var duration: TimeInterval { segments.map(\.duration).reduce(0, +) }

    public init(_ segments: [Segment]) { self.segments = segments.filter { $0.duration > 0 } }

    // MARK: building

    public static let noticeTime: TimeInterval = 0.14   // 120–250 ms "notice" beat (after a 0.12 s switch debounce)
    public static let coilTime: TimeInterval = 0.12
    public static let landTime: TimeInterval = 0.11
    public static let settleTime: TimeInterval = 0.24

    /// Face left when the hop is mostly horizontal and goes left; otherwise keep `current`.
    public static func facing(from a: CGPoint, to b: CGPoint, current: Bool) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        return abs(dx) >= abs(dy) * 0.8 && abs(dx) > 2 ? dx < 0 : current
    }

    /// Notice → coil → hop(s) with short landings between → land → settle.
    public static func hop(_ route: HopRoute, notice: Bool = true, coil: TimeInterval = coilTime) -> Choreography {
        guard let first = route.legs.first else { return Choreography([]) }
        var segs: [Segment] = []
        var facing = facing(from: first.start, to: route.end, current: false)
        if notice {
            // the notice frame looks up and to the right: mirror it to look toward the target
            segs.append(.hold(at: first.start, frame: MotionFrames.notice, mirrored: route.end.x < first.start.x, duration: noticeTime))
        }
        segs.append(.coil(at: first.start, mirrored: facing, duration: coil))
        for (i, leg) in route.legs.enumerated() {
            facing = Self.facing(from: leg.start, to: leg.end, current: facing)
            segs.append(.flight(leg, offset: 0, mirrored: facing, frames: (MotionFrames.rise, MotionFrames.fall)))
            if i < route.legs.count - 1 {
                // a short landing between chained hops: squash, then straight into the next coil
                segs.append(.land(at: leg.end, frame: MotionFrames.land, mirrored: facing, duration: route.pause * 0.6, dust: true))
                segs.append(.coil(at: leg.end, mirrored: facing, duration: route.pause * 0.4))
            }
        }
        segs.append(.land(at: route.end, frame: MotionFrames.land, mirrored: facing, duration: landTime, dust: true))
        segs.append(.settle(at: route.end, duration: settleTime))
        return Choreography(segs)
    }

    /// A tiny hop in place (when a dragged window stops).
    public static func bump(at p: CGPoint, scale: CGFloat) -> Choreography {
        let plan = HopPlan(from: p, to: p, apexHeight: Double(5 * scale), duration: 0.2)
        return Choreography([
            .flight(plan, offset: 0, mirrored: false, frames: (MotionFrames.rise, MotionFrames.fall)),
            .land(at: p, frame: MotionFrames.land, mirrored: false, duration: 0.08, dust: false),
            .settle(at: p, duration: 0.16),
        ])
    }

    /// Swiping to another Space, part 1: a quick hop up and away, fading out (~0.14 s).
    public static func exit(from p: CGPoint, scale: CGFloat) -> Choreography {
        Choreography([.exit(from: p, rise: 26 * scale, duration: 0.14)])
    }

    /// Swiping to another Space, part 2 (≤ 0.6 s): peek down from under the menu bar,
    /// let go, drop with a falling stretch, squash on landing, settle.
    /// - Parameter hangFoot: where the feet are while the hanging frame's toe pad holds the top edge.
    public static func dropIn(hangFoot: CGPoint, to target: CGPoint) -> Choreography {
        let distance = max(target.y - hangFoot.y, 0)
        let fall = min(max(0.16 + Double(distance) / 4000, 0.16), 0.26)
        return Choreography([
            .hold(at: hangFoot, frame: MotionFrames.hang, mirrored: false, duration: 0.08),
            .fall(from: hangFoot, to: target, duration: fall),
            .land(at: target, frame: MotionFrames.dropLand, mirrored: false, duration: 0.09, dust: true),
            .settle(at: target, duration: 0.13),   // total ≤ 0.58 s
        ])
    }

    // MARK: sampling

    /// The pose at `t` seconds, and whether the timeline has finished.
    public func pose(at t: TimeInterval) -> (pose: Pose, done: Bool) {
        var start: TimeInterval = 0
        for seg in segments {
            let d = seg.duration
            if t < start + d || seg.duration == 0 {
                return (Self.pose(seg, local: t - start), false)
            }
            start += d
        }
        guard let last = segments.last else { return (Pose(foot: .zero, frame: MotionFrames.settle), true) }
        return (Self.pose(last, local: last.duration), true)
    }

    /// Landing points (with dust) between `t0` (exclusive) and `t1` (inclusive), for FX.
    public func landings(between t0: TimeInterval, and t1: TimeInterval) -> [CGPoint] {
        var start: TimeInterval = 0
        var out: [CGPoint] = []
        for seg in segments {
            if case .land(let p, _, _, _, true) = seg, start > t0, start <= t1 { out.append(p) }
            start += seg.duration
        }
        return out
    }

    /// Index of the segment playing at `t`, and the time into it.
    func segment(at t: TimeInterval) -> (Int, TimeInterval)? {
        var start: TimeInterval = 0
        for (i, seg) in segments.enumerated() {
            if t < start + seg.duration { return (i, t - start) }
            start += seg.duration
        }
        return nil
    }

    static func pose(_ seg: Segment, local t: TimeInterval) -> Pose {
        let f = seg.duration > 0 ? min(max(t / seg.duration, 0), 1) : 1
        switch seg {
        case .hold(let p, let frame, let m, _):
            return Pose(foot: p, frame: frame, mirrored: m)
        case .coil(let p, let m, _):
            return Pose(foot: p, frame: MotionFrames.coil, squash: SquashStretch.scale(.coil(f)), mirrored: m)
        case .flight(let plan, let offset, let m, let frames):
            let tt = offset + t
            let apex = plan.duration > 0 ? plan.timeToApex / plan.duration : 0.5
            let progress = plan.duration > 0 ? tt / plan.duration : 1
            return Pose(foot: plan.position(at: tt), frame: progress < apex ? frames.rise : frames.fall,
                        squash: SquashStretch.scale(.flight(progress), apex: apex), mirrored: m)
        case .land(let p, let frame, let m, _, _):
            return Pose(foot: p, frame: frame, squash: SquashStretch.scale(.land(f)), mirrored: m)
        case .settle(let p, _):
            return Pose(foot: p, frame: MotionFrames.settle, squash: SquashStretch.scale(.settle(f)))
        case .fall(let a, let b, _):
            let y = a.y + (b.y - a.y) * CGFloat(f * f)  // constant acceleration
            return Pose(foot: CGPoint(x: b.x, y: y), frame: MotionFrames.fall,
                        squash: SquashStretch.scale(.flight(0.5 + 0.5 * f), apex: 0.5))
        case .exit(let p, let rise, _):
            return Pose(foot: CGPoint(x: p.x, y: p.y - rise * CGFloat(f)), frame: MotionFrames.rise,
                        squash: SquashStretch.scale(.flight(f * 0.3), apex: 0.5), alpha: CGFloat(1 - f))
        }
    }

    // MARK: retargeting

    /// The target changed while this plays. Never snaps back to the start:
    /// - before take-off: hop from the same spot to the new target (no second notice);
    /// - early in a flight (< 60%): a new arc from where Frogg is, straight to the target;
    /// - late in a flight, landing or settling: finish this leg, then hop again.
    public func retargeted(at t: TimeInterval, route: (CGPoint) -> HopRoute) -> Choreography {
        guard let (i, local) = segment(at: t) else { return Choreography.hop(route(pose(at: t).pose.foot), notice: false) }
        switch segments[i] {
        case .hold(let p, _, _, _), .coil(let p, _, _):
            return Choreography.hop(route(p), notice: false)
        case .flight(let plan, let offset, let m, let frames):
            let progress = (offset + local) / max(plan.duration, 0.001)
            if progress < 0.6 {
                return Choreography.hop(route(plan.position(at: offset + local)), notice: false, coil: 0)
            }
            let rest = Choreography([
                .flight(plan, offset: offset + local, mirrored: m, frames: frames),
                .land(at: plan.end, frame: MotionFrames.land, mirrored: m, duration: 0.07, dust: true),
            ])
            return Choreography(rest.segments + Choreography.hop(route(plan.end), notice: false, coil: 0.08).segments)
        case .land(let p, _, _, _, _), .settle(let p, _):
            return Choreography.hop(route(p), notice: false, coil: 0.08)
        case .fall(_, let b, _):
            return Choreography.hop(route(b), notice: false)
        case .exit(let p, _, _):
            return Choreography.hop(route(p), notice: false)
        }
    }
}
