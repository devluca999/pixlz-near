import CoreGraphics
import Foundation
import PixlzCore

/// Which art frame each motion beat uses. Swap names here when new art lands;
/// the motion code doesn't change.
public enum MotionFrames {
    public static let notice = "poke_1"    // head turned up toward the new window
    public static let coil = "move_0"      // crouched, side-on
    public static let rise = "move_1"      // fully stretched leap
    public static let fall = "move_2"      // legs swinging forward to land
    public static let land = "move_0"      // back into the crouch as the feet touch
    public static let settle = "idle_0"
    public static let hang = "grab_0"      // peeking down from under the menu bar
    public static let dropLand = "move_0"  // the same crouch after a straight drop (no splat)
    public static let startle = "emotion_startled"  // "whoa": the Space just changed under him
    /// How long the land frame shows before the settle frame, while the landing spring plays out.
    public static let landFrameTime: TimeInterval = 0.1
}

/// Everything the view needs for one moment of motion.
public struct Pose: Equatable, Sendable {
    public var foot: CGPoint           // top-left global coordinates
    public var frame: String
    public var squash = CGSize(width: 1, height: 1)
    public var mirrored = false        // face left
    public var alpha: CGFloat = 1
    /// Which surface the feet are on (Silky on a wall or the ceiling): the art is turned to match.
    public var surface: Surface = .floor
    /// Silky's thread: where it's tied (top-left global coordinates), or nil.
    public var thread: CGPoint? = nil
    /// Slugg around a corner: quarter turns of its corner loop (with `mirrored` as the flip).
    public var turns = 0
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
        /// A startle in place with a springy wobble.
        case whoa(at: CGPoint, mirrored: Bool, duration: TimeInterval)
        /// Out at one display's edge and in at the other's (shrink and fade, then grow back).
        case pop(from: CGPoint, to: CGPoint, mirrored: Bool, duration: TimeInterval)
        /// Turning around: one narrow in-between frame, half facing the old way, half the new.
        case pivot(at: CGPoint, frame: String, toLeft: Bool, duration: TimeInterval)
        /// Roam: a straight move along a surface, cycling `frames` (walk, trot, crawl, drift).
        /// `bob` floats it up and down (Boo); `alpha` fades it while moving.
        case travel(from: CGPoint, to: CGPoint, frames: [String], fps: Double, surface: Surface, mirrored: Bool,
                    bob: CGFloat, alpha: CGFloat, duration: TimeInterval)
        /// A ghost's move: no hop, a smooth drift that eases in and out, fading a little mid-way.
        case glide(from: CGPoint, to: CGPoint, mirrored: Bool, duration: TimeInterval)
        /// Silky on its thread, tied at `anchor`, going from one depth below it to another.
        case dangle(anchor: CGPoint, from: CGFloat, to: CGFloat, duration: TimeInterval)
        /// Slugg wrapping around a corner at `at`: its corner loop once through, turned to fit.
        case wrap(CornerWrap, duration: TimeInterval)
        /// Dropping straight down under gravity in one frame, upright (Slugg losing his grip on the ceiling).
        case drop(from: CGPoint, to: CGPoint, frame: String, mirrored: Bool, duration: TimeInterval)

        public var duration: TimeInterval {
            switch self {
            case .hold(_, _, _, let d), .coil(_, _, let d), .land(_, _, _, let d, _), .settle(_, let d),
                 .fall(_, _, let d), .exit(_, _, let d), .whoa(_, _, let d), .pop(_, _, _, let d), .pivot(_, _, _, let d),
                 .travel(_, _, _, _, _, _, _, _, let d), .dangle(_, _, _, let d), .glide(_, _, _, let d), .wrap(_, let d),
                 .drop(_, _, _, _, let d): d
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
    /// The landing squash springs back over this time (0.75 → 1.1 → 0.97 → 1.0); it is the settle.
    public static let landTime: TimeInterval = SquashStretch.landingTime
    public static let whoaTime: TimeInterval = 0.26
    public static let popTime: TimeInterval = 0.16
    public static let pivotTime: TimeInterval = 0.07

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
        if route.end.x < first.start.x - 2 {
            // turning to go left: a narrow in-between frame so the facing doesn't just pop
            segs.append(.pivot(at: first.start, frame: notice ? MotionFrames.notice : MotionFrames.coil, toLeft: true, duration: pivotTime))
        }
        if notice {
            // the notice frame looks up and to the right: mirror it to look toward the target
            segs.append(.hold(at: first.start, frame: MotionFrames.notice, mirrored: route.end.x < first.start.x, duration: noticeTime))
        }
        segs.append(.coil(at: first.start, mirrored: facing, duration: coil))
        for (i, leg) in route.legs.enumerated() {
            facing = Self.facing(from: leg.start, to: leg.end, current: facing)
            segs.append(.flight(leg, offset: 0, mirrored: facing, frames: (MotionFrames.rise, MotionFrames.fall)))
            if i == route.popAfter, i + 1 < route.legs.count {
                // between displays with no arc that stays on screen: pop through the edge
                let next = route.legs[i + 1]
                segs.append(.pop(from: leg.end, to: next.start, mirrored: facing, duration: popTime))
                segs.append(.coil(at: next.start, mirrored: facing, duration: route.pause * 0.6))
            } else if i < route.legs.count - 1 {
                // a short landing between chained hops: squash, then straight into the next coil
                segs.append(.land(at: leg.end, frame: MotionFrames.land, mirrored: facing, duration: route.pause * 0.6, dust: true))
                segs.append(.coil(at: leg.end, mirrored: facing, duration: route.pause * 0.4))
            }
        }
        // land: crouch frame, then settle frame, while the squash springs back (feet planted)
        segs.append(.land(at: route.end, frame: MotionFrames.land, mirrored: facing, duration: landTime, dust: true))
        return Choreography(segs)
    }

    /// The Space changed under the Pixl: a startle with a wobble where it stands, then a
    /// springy hop to the new perch (no notice beat: the startle is the notice).
    /// A ghost moves by gliding, not hopping (about 240 pt/s, at least half a second).
    public static func glide(from a: CGPoint, to b: CGPoint) -> Choreography {
        let d = Double(hypot(b.x - a.x, b.y - a.y))
        guard d >= 1 else { return Choreography([]) }
        return Choreography([.glide(from: a, to: b, mirrored: b.x < a.x, duration: max(0.5, d / 240))])
    }

    public static func whoa(at p: CGPoint, then route: HopRoute?) -> Choreography {
        let toLeft = route.map { $0.end.x < p.x } ?? false
        var segs: [Segment] = [.whoa(at: p, mirrored: toLeft, duration: whoaTime)]
        if let route, hypot(route.end.x - p.x, route.end.y - p.y) >= 1 { segs += hop(route, notice: false).segments }
        return Choreography(segs)
    }

    /// A tiny hop in place (when a dragged window stops).
    public static func bump(at p: CGPoint, scale: CGFloat) -> Choreography {
        let plan = HopPlan(from: p, to: p, apexHeight: Double(5 * scale), duration: 0.2)
        return Choreography([
            .flight(plan, offset: 0, mirrored: false, frames: (MotionFrames.rise, MotionFrames.fall)),
            .land(at: p, frame: MotionFrames.land, mirrored: false, duration: 0.24, dust: false),
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
            .land(at: target, frame: MotionFrames.dropLand, mirrored: false, duration: landTime, dust: true),
        ])  // total ≤ 0.08 + 0.26 + 0.36 = 0.70 s
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
            if case .pop(_, let b, _, let d) = seg, start + d / 2 > t0, start + d / 2 <= t1 { out.append(b) }
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
            return Pose(foot: p, frame: MotionFrames.coil, squash: SquashStretch.crouch(t), mirrored: m)
        case .flight(let plan, let offset, let m, let frames):
            let tt = offset + t
            let apex = plan.duration > 0 ? plan.timeToApex / plan.duration : 0.5
            let progress = plan.duration > 0 ? tt / plan.duration : 1
            return Pose(foot: plan.position(at: tt), frame: progress < apex ? frames.rise : frames.fall,
                        squash: SquashStretch.scale(.flight(progress), apex: apex), mirrored: m)
        case .land(let p, let frame, let m, let d, _):
            // the squash springs back over the whole segment; the last frame is exactly neutral
            let squash = t >= d ? CGSize(width: 1, height: 1) : SquashStretch.landing(t)
            return Pose(foot: p, frame: t < MotionFrames.landFrameTime ? frame : MotionFrames.settle, squash: squash,
                        mirrored: t < MotionFrames.landFrameTime ? m : false)
        case .settle(let p, _):
            return Pose(foot: p, frame: MotionFrames.settle, squash: SquashStretch.scale(.settle(f)))
        case .fall(let a, let b, _):
            let y = a.y + (b.y - a.y) * CGFloat(f * f)  // constant acceleration
            return Pose(foot: CGPoint(x: b.x, y: y), frame: MotionFrames.fall,
                        squash: SquashStretch.scale(.flight(0.5 + 0.5 * f), apex: 0.5))
        case .pivot(let p, let frame, let toLeft, _):
            // narrowest at the middle of the turn; the facing flips halfway
            let w = 1 - 0.18 * sin(Double.pi * f)
            return Pose(foot: p, frame: frame, squash: CGSize(width: w, height: 1 + (1 - w) * 0.3), mirrored: f >= 0.5 ? toLeft : !toLeft)
        case .whoa(let p, let m, let d):
            return Pose(foot: p, frame: MotionFrames.startle, squash: t >= d ? CGSize(width: 1, height: 1) : SquashStretch.wobble(t), mirrored: m)
        case .pop(let a, let b, let m, _):
            // shrink out at the edge, grow in on the other display
            let out = f < 0.5
            let k = out ? 1 - f * 2 : (f - 0.5) * 2
            let s = 0.35 + 0.65 * k
            return Pose(foot: out ? a : b, frame: MotionFrames.rise, squash: CGSize(width: s, height: s), mirrored: m, alpha: CGFloat(k))
        case .exit(let p, let rise, _):
            return Pose(foot: CGPoint(x: p.x, y: p.y - rise * CGFloat(f)), frame: MotionFrames.rise,
                        squash: SquashStretch.scale(.flight(f * 0.3), apex: 0.5), alpha: CGFloat(1 - f))
        case .travel(let a, let b, let frames, let fps, let surface, let m, let bob, let alpha, _):
            let e = CGFloat(f)
            var p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            if bob > 0 { p.y -= bob * CGFloat(sin(t * 2 * .pi / 1.6)) }   // a float (Boo)
            if bob < 0, !frames.isEmpty {
                // phase-locked: up in the stride's float (two per loop for a trot)
                let phase = (t * fps / Double(frames.count)).truncatingRemainder(dividingBy: 1)
                p.y += bob * CGFloat(max(0, sin(phase * 4 * .pi))).rounded()
            }
            let frame = frames.isEmpty ? MotionFrames.settle : frames[Int(t * fps) % frames.count]
            // fade out over the first fifth and back in over the last fifth
            let fade = min(1, min(e, 1 - e) * 5)
            var pose = Pose(foot: p, frame: frame, mirrored: m, alpha: 1 - (1 - alpha) * fade)
            pose.surface = surface
            return pose
        case .wrap(let w, _):
            let i = min(w.frames.count - 1, Int(f * Double(w.frames.count)))
            var pose = Pose(foot: w.at, frame: w.frames[i], mirrored: w.turn.flip)
            pose.turns = w.turn.turns
            return pose
        case .drop(let a, let b, let frame, let m, _):
            let y = a.y + (b.y - a.y) * CGFloat(f * f)   // constant acceleration
            return Pose(foot: CGPoint(x: b.x, y: y), frame: frame, squash: CGSize(width: 1 - 0.1 * f, height: 1 + 0.12 * f), mirrored: m)
        case .glide(let a, let b, let m, _):
            let e = CGFloat(f * f * (3 - 2 * f))   // smoothstep
            return Pose(foot: CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e), frame: f < 0.5 ? "idle_1" : "idle_0",
                        mirrored: m, alpha: 1 - 0.35 * CGFloat(sin(Double.pi * f)))
        case .dangle(let anchor, let d0, let d1, _):
            let e = CGFloat(f * f * (3 - 2 * f))   // smoothstep: eases off and onto the thread's end
            // its own hanging art, swaying between two frames
            var pose = Pose(foot: CGPoint(x: anchor.x, y: anchor.y + d0 + (d1 - d0) * e), frame: Int(t * 2.5) % 2 == 0 ? "mischief_0" : "mischief_1")
            pose.surface = .hanging
            pose.thread = anchor
            return pose
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
        case .fall(_, let b, _), .drop(_, let b, _, _, _):
            return Choreography.hop(route(b), notice: false)
        case .exit(let p, _, _), .whoa(let p, _, _), .pivot(let p, _, _, _):
            return Choreography.hop(route(p), notice: false)
        case .travel, .dangle, .glide, .wrap:
            // off a wall, the ceiling or a thread: hop on from where it is, upright
            return Choreography.hop(route(pose(at: t).pose.foot), notice: false)
        case .pop(let a, let b, _, _):
            return Choreography.hop(route(local < segments[i].duration / 2 ? a : b), notice: false)
        }
    }
}
