import CoreGraphics
import Foundation
import PixlzCore

/// Behavior ▸ Roam: now and then, the Pixl goes on a short outing in its own style. Pure
/// planning here (seeded, testable); the app supplies what's on screen and plays the result.
///
/// What the Pixl knows (all local, nothing sent): screen edges, window frames, desktop folders
/// not covered by a window, where your caret is, the mouse, and whether the app in front is a
/// code app. Never the text itself.

/// Which surface the Pixl's feet are on. The art is drawn turned so its feet face the surface.
public enum Surface: String, Equatable, Sendable {
    case floor, rightWall, ceiling, leftWall
    /// Hanging below the point (Silky on its thread): upright, its body below.
    case hanging

    /// Rotation for drawing, in radians, counter-clockwise in a y-up view.
    public var rotation: CGFloat {
        switch self {
        case .floor, .hanging: 0
        case .rightWall: .pi / 2
        case .ceiling: .pi
        case .leftWall: -.pi / 2
        }
    }

    /// The middle of the Pixl's body when its feet touch the surface at `foot` (top-left
    /// coordinates, y down), for a body `height` tall.
    public func bodyCenter(foot: CGPoint, height: CGFloat) -> CGPoint {
        switch self {
        case .floor: CGPoint(x: foot.x, y: foot.y - height / 2)
        case .rightWall: CGPoint(x: foot.x - height / 2, y: foot.y)
        case .ceiling, .hanging: CGPoint(x: foot.x, y: foot.y + height / 2)
        case .leftWall: CGPoint(x: foot.x + height / 2, y: foot.y)
        }
    }
}

/// How each Pixl roams (from its id and movement in pixl.json).
public enum RoamStyle: String, CaseIterable, Sendable {
    case hopper    // Frogg: folders, window tops, reading along above your caret
    case prowler   // Katt: walks the edge it's on, naps, hops up high
    case trotter   // Mochi: trots after the mouse, sniffs around folders
    case drifter   // Boo: drifts about, half see-through, haunts folders
    case crawler   // Silky: walks to the screen's side, climbs, crawls the ceiling, drops on silk

    public static func of(id: String, movement: String) -> RoamStyle {
        switch id {
        case "frogg": .hopper
        case "cat": .prowler
        case "shiba": .trotter
        case "ghost": .drifter
        case "widow": .crawler
        default: movement == "float" ? .drifter : .hopper
        }
    }

    /// Points per second on the move, and the frames it cycles while moving.
    var speed: CGFloat {
        switch self { case .hopper: 60; case .prowler: 55; case .trotter: 150; case .drifter: 45; case .crawler: 110 }
    }
}

/// Everything on screen the planner may use, in top-left global coordinates.
public struct RoamWorld: Sendable {
    public var screens: [CGRect]        // visible frames (below the menu bar, above the Dock)
    public var active: CGRect?          // the window you're using
    public var others: [CGRect]         // other windows whose top edge shows
    public var folders: [CGRect]        // desktop folders no window covers
    public var avoid: [CGRect]          // your caret and selection
    public var cursor: CGPoint
    public var foot: CGPoint
    public var sprite: CGSize           // the Pixl's on-screen size
    public var codeContext: Bool        // a terminal or code editor is in front
    public var hanging: CGPoint?        // Silky: the anchor of the thread it hangs from
    public var surface: Surface = .floor // what its feet are on now (Silky can rest on a wall)

    public init(screens: [CGRect], active: CGRect? = nil, others: [CGRect] = [], folders: [CGRect] = [],
                avoid: [CGRect] = [], cursor: CGPoint = .zero, foot: CGPoint, sprite: CGSize,
                codeContext: Bool = false, hanging: CGPoint? = nil, surface: Surface = .floor) {
        self.screens = screens; self.active = active; self.others = others; self.folders = folders
        self.avoid = avoid; self.cursor = cursor; self.foot = foot; self.sprite = sprite
        self.codeContext = codeContext; self.hanging = hanging; self.surface = surface
    }

    /// The screen the Pixl is on.
    public var screen: CGRect {
        screens.first { $0.insetBy(dx: -4, dy: -4).contains(foot) } ?? screens.first ?? .zero
    }
}

/// One outing.
public enum Outing: Equatable, Sendable {
    case hop(to: CGPoint, why: String)
    case walk(to: CGPoint)                                    // along the edge it stands on
    case drift(to: CGPoint)                                   // Boo
    case crawl(legs: [CrawlLeg], dangle: CGFloat?)            // Silky; then down a thread by this much
    case climbAndMove(to: CGPoint, dangle: CGFloat?)          // Silky, hanging: up the thread, along, down again
    case glance(at: CGPoint, lookLeft: Bool)                  // read along: above your caret
    case nap(TimeInterval)
    case pond(TimeInterval)                                   // Frogg dives into a little pond, eyes peeking
    case stalk(to: CGPoint)                                   // Katt creeps low, then arches its back

    public var name: String {
        switch self {
        case .hop(_, let why): "hop (\(why))"
        case .walk: "walk"
        case .drift: "drift"
        case .crawl(_, let d): d == nil ? "crawl" : "crawl and dangle"
        case .climbAndMove: "climb and move"
        case .glance: "glance"
        case .nap: "nap"
        case .pond: "pond"
        case .stalk: "stalk"
        }
    }
}

public struct CrawlLeg: Equatable, Sendable {
    public var from: CGPoint
    public var to: CGPoint
    public var surface: Surface
    public init(from: CGPoint, to: CGPoint, surface: Surface) { self.from = from; self.to = to; self.surface = surface }
}

public struct RoamPlanner: Sendable {
    public let style: RoamStyle
    var rng: SeededRandom

    public init(style: RoamStyle, seed: UInt64) { self.style = style; rng = SeededRandom(seed: seed) }

    /// How long to wait before the next outing.
    public mutating func pause() -> TimeInterval { Double.random(in: 5...12, using: &rng) }

    enum Kind { case folderHop, windowHop, glance, nap, walk, trot, drift, folderDrift, crawlTour, moveHanging, pond, stalk, climbDown }

    /// Picks the next outing, or nil when nothing fits right now.
    public mutating func next(_ w: RoamWorld) -> Outing? {
        let g = w.codeContext ? 3.0 : 1.0   // in a code app it reads along more often
        var options: [(Double, Kind)]
        switch style {
        case .hopper: options = [(3, .folderHop), (3, .windowHop), (2 * g, .glance), (1.5, .pond), (0.2, .nap)]
        case .prowler: options = [(3, .walk), (2, .stalk), (0.6, .nap), (1.5, .windowHop), (1, .folderHop), (g, .glance)]
        case .trotter: options = [(3, .trot), (2, .folderHop), (1.5, .walk), (g, .glance)]
        case .drifter: options = [(3, .drift), (2, .folderDrift), (1.5 * g, .glance)]
        case .crawler:
            if w.hanging != nil { options = [(3, .moveHanging), (1, .nap)] }
            else if w.surface == .rightWall || w.surface == .leftWall { options = [(3, .climbDown), (1, .nap)] }
            else { options = [(3, .crawlTour), (g, .glance), (0.3, .nap)] }
        }
        // weighted draw; if the pick doesn't fit right now, try the others
        while !options.isEmpty {
            let total = options.map(\.0).reduce(0, +)
            var r = Double.random(in: 0..<total, using: &rng)
            var i = 0
            while i < options.count - 1, r >= options[i].0 { r -= options[i].0; i += 1 }
            if let o = make(options[i].1, w) { return o }
            options.remove(at: i)
        }
        return nil
    }

    /// Reading along right now (after a stretch of typing in a code app).
    public mutating func glanceNow(_ w: RoamWorld) -> Outing? { glance(w) }

    mutating func make(_ k: Kind, _ w: RoamWorld) -> Outing? {
        switch k {
        case .folderHop: folderHop(w)
        case .windowHop: windowHop(w)
        case .glance: glance(w)
        case .nap: .nap(style == .prowler ? Double.random(in: 8...16, using: &rng) : Double.random(in: 4...8, using: &rng))
        case .walk: walkAlong(w)
        case .trot: trotToCursor(w)
        case .drift: drift(w)
        case .folderDrift: folderDrift(w)
        case .crawlTour: crawlTour(w)
        case .moveHanging: moveWhileHanging(w)
        case .pond: Self.fine(w.foot, w) || w.avoid.isEmpty ? .pond(Double.random(in: 4...9, using: &rng)) : nil
        case .climbDown: climbDown(w)
        case .stalk: { () -> Outing? in if case .walk(let to)? = walkAlong(w) { return .stalk(to: to) }; return nil }()
        }
    }

    // MARK: is a spot fine?

    /// The body's box when standing at `foot` on `surface`.
    public static func body(foot: CGPoint, sprite: CGSize, surface: Surface = .floor) -> CGRect {
        let c = surface.bodyCenter(foot: foot, height: sprite.height)
        let turned = surface == .floor || surface == .ceiling ? sprite : CGSize(width: sprite.height, height: sprite.width)
        return CGRect(x: c.x - turned.width / 2, y: c.y - turned.height / 2, width: turned.width, height: turned.height)
    }

    /// On a screen, clear of your caret and selection, not on the window's content, not under the mouse.
    public static func fine(_ foot: CGPoint, _ w: RoamWorld, surface: Surface = .floor) -> Bool {
        let b = body(foot: foot, sprite: w.sprite, surface: surface).insetBy(dx: 6, dy: 6)
        guard w.screens.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(b) }) else { return false }
        if w.avoid.contains(where: { $0.insetBy(dx: -16, dy: -16).intersects(b) }) { return false }
        if let a = w.active, a.insetBy(dx: 0, dy: 4).intersects(b) {
            // never over what you're working on, except along the screen's edges when the window
            // fills the screen (the bottom is where the Pixl sits anyway), well away from your caret
            let floor = w.screens.contains { s in
                abs(b.maxY + 6 - s.maxY) < 10 || abs(b.maxX + 6 - s.maxX) < 10 || abs(b.minX - 6 - s.minX) < 10
            }
            let clear = w.avoid.allSatisfy { abs($0.midX - b.midX) > 260 || abs($0.midY - b.midY) > 220 }
            if !(floor && clear) { return false }
        }
        if b.insetBy(dx: -10, dy: -10).contains(w.cursor) { return false }
        return true
    }

    // MARK: outings

    mutating func folderHop(_ w: RoamWorld) -> Outing? {
        let spots = w.folders.map { CGPoint(x: $0.midX, y: $0.minY + 6) }.filter { Self.fine($0, w) && hypot($0.x - w.foot.x, $0.y - w.foot.y) > 40 }
        guard let s = spots.randomElement(using: &rng) else { return nil }
        return .hop(to: s, why: "folder")
    }

    mutating func folderDrift(_ w: RoamWorld) -> Outing? {
        guard case .hop(let s, _)? = folderHop(w) else { return nil }
        return .drift(to: s)
    }

    mutating func windowHop(_ w: RoamWorld) -> Outing? {
        let half = w.sprite.width / 2
        let spots: [CGPoint] = w.others.compactMap { r in
            guard r.width > w.sprite.width * 2 else { return nil }
            return CGPoint(x: CGFloat.random(in: (r.minX + half)...(r.maxX - half), using: &rng), y: r.minY)
        }.filter { Self.fine($0, w) && abs($0.y - w.foot.y) + abs($0.x - w.foot.x) > 60 }
        if let s = spots.randomElement(using: &rng) { return .hop(to: s, why: "window") }
        // no other windows: the screen's floor, somewhere else
        let sc = w.screen
        let s = CGPoint(x: CGFloat.random(in: (sc.minX + half)...(sc.maxX - half), using: &rng), y: sc.maxY)
        return Self.fine(s, w) && abs(s.x - w.foot.x) > 80 ? .hop(to: s, why: "floor") : nil
    }

    /// Along the edge it's standing on (a window top or the floor), a little way.
    mutating func walkAlong(_ w: RoamWorld) -> Outing? {
        let (lo, hi) = edgeSpan(w)
        guard hi - lo > 80 else { return nil }
        for _ in 0..<6 {
            let x = CGFloat.random(in: lo...hi, using: &rng)
            let s = CGPoint(x: x, y: w.foot.y)
            if abs(x - w.foot.x) > 60, Self.fine(s, w) { return .walk(to: s) }
        }
        return nil
    }

    /// The x range of the edge under its feet: the window top it's on, or the screen's floor.
    func edgeSpan(_ w: RoamWorld) -> (CGFloat, CGFloat) {
        let half = w.sprite.width / 2
        let windows = (w.active.map { [$0] } ?? []) + w.others
        if let r = windows.first(where: { abs($0.minY - w.foot.y) < 4 && $0.minX <= w.foot.x && w.foot.x <= $0.maxX }) {
            return (r.minX + half, r.maxX - half)
        }
        let sc = w.screen
        return (sc.minX + half, sc.maxX - half)
    }

    mutating func trotToCursor(_ w: RoamWorld) -> Outing? {
        let (lo, hi) = edgeSpan(w)
        // stop a little short of the mouse, on the side it came from
        let side: CGFloat = w.cursor.x > w.foot.x ? -1 : 1
        let x = min(max(w.cursor.x + side * (w.sprite.width * 0.8), lo), hi)
        let s = CGPoint(x: x, y: w.foot.y)
        return abs(x - w.foot.x) > 50 && Self.fine(s, w) ? .walk(to: s) : nil
    }

    mutating func drift(_ w: RoamWorld) -> Outing? {
        let sc = w.screen
        for i in 0..<12 {
            // anywhere in the air, or (every other try) low along the bottom edge
            let y = i % 2 == 0 ? CGFloat.random(in: (sc.minY + w.sprite.height + 20)...(sc.maxY - 10), using: &rng) : sc.maxY - 4
            let s = CGPoint(x: CGFloat.random(in: (sc.minX + w.sprite.width)...(sc.maxX - w.sprite.width), using: &rng), y: y)
            if hypot(s.x - w.foot.x, s.y - w.foot.y) > 120, Self.fine(s, w) { return .drift(to: s) }
        }
        return nil
    }

    /// Up on the active window's top edge, right above your caret, looking down at it.
    mutating func glance(_ w: RoamWorld) -> Outing? {
        guard let a = w.active else { return nil }
        let half = w.sprite.width / 2
        let caretX = w.avoid.last?.midX ?? a.midX
        if style == .crawler {
            // Silky lowers itself from the top of the screen to just above the window, over the caret
            let sc = w.screen
            let x = min(max(caretX, sc.minX + half), sc.maxX - half)
            let depth = a.minY - 6 - w.sprite.height - sc.minY
            guard depth > 30 else { return nil }
            let spot = CGPoint(x: x, y: sc.minY + depth)
            guard Self.fine(spot, w, surface: .hanging) else { return nil }
            return w.hanging == nil ? .crawl(legs: crawlToCeiling(w, x: x), dangle: depth) : .climbAndMove(to: CGPoint(x: x, y: sc.minY), dangle: depth)
        }
        // a little to the side of the caret, so it never sits on the line you're on
        let side: CGFloat = caretX > a.midX ? -1 : 1
        let x = min(max(caretX + side * w.sprite.width * 0.7, a.minX + half), a.maxX - half)
        let s = CGPoint(x: x, y: a.minY)
        guard Self.fine(s, w) else { return nil }
        return .glance(at: s, lookLeft: caretX < x)
    }

    // MARK: Silky

    /// Walk to the nearer side of the screen, climb the wall, crawl the ceiling, drop on a thread.
    mutating func crawlTour(_ w: RoamWorld) -> Outing? {
        let sc = w.screen
        let half = w.sprite.width / 2
        // where along the top to stop and drop: somewhere it won't hang over your window's content
        for _ in 0..<10 {
            let x = CGFloat.random(in: (sc.minX + half)...(sc.maxX - half), using: &rng)
            let below = w.active.flatMap { a in a.minX - half < x && x < a.maxX + half ? a.minY - 6 : nil } ?? (sc.minY + sc.height * 0.35)
            let depth = min(below - w.sprite.height - sc.minY, sc.height * 0.4)
            let d: CGFloat = depth > 40 ? CGFloat.random(in: 40...depth, using: &rng) : 24
            guard Self.fine(CGPoint(x: x, y: sc.minY + d), w, surface: .hanging) else { continue }
            let legs = crawlToCeiling(w, x: x)
            return legs.isEmpty ? nil : .crawl(legs: legs, dangle: d)
        }
        // a window fills the top of the screen: climb the wall and rest high up on it instead
        let legs = crawlToCeiling(w, x: sc.midX)
        guard legs.count >= 2 else { return nil }
        var up = legs[1]
        up.to.y = sc.minY + w.sprite.height * 0.6 + CGFloat.random(in: 0...80, using: &rng)
        guard Self.fine(up.to, w, surface: up.surface) else { return nil }
        return .crawl(legs: [legs[0], up], dangle: nil)
    }

    /// Silky resting on a wall: down to the floor, then off along it.
    mutating func climbDown(_ w: RoamWorld) -> Outing? {
        let sc = w.screen
        let h = w.sprite.height, half = w.sprite.width / 2
        let right = w.surface == .rightWall
        let down = CrawlLeg(from: w.foot, to: CGPoint(x: w.foot.x, y: sc.maxY - h / 2), surface: w.surface)
        let corner = CGPoint(x: right ? sc.maxX - h / 2 : sc.minX + h / 2, y: sc.maxY)
        for _ in 0..<6 {
            let x = CGFloat.random(in: (sc.minX + half)...(sc.maxX - half), using: &rng)
            let end = CGPoint(x: x, y: sc.maxY)
            if abs(x - corner.x) > 120, Self.fine(end, w) {
                return .crawl(legs: [down, CrawlLeg(from: corner, to: end, surface: .floor)], dangle: nil)
            }
        }
        return nil
    }

    /// From the floor: along to the nearer side, up the wall, along the ceiling to `x`.
    func crawlToCeiling(_ w: RoamWorld, x: CGFloat) -> [CrawlLeg] {
        let sc = w.screen
        let h = w.sprite.height
        let floorY = sc.maxY
        let right = w.foot.x > sc.midX
        let wallX = right ? sc.maxX : sc.minX
        let corner = CGPoint(x: right ? sc.maxX - h / 2 : sc.minX + h / 2, y: floorY)
        let wallBottom = CGPoint(x: wallX, y: floorY - h / 2)
        let wallTop = CGPoint(x: wallX, y: sc.minY + h / 2)
        let ceilingStart = CGPoint(x: right ? sc.maxX - h / 2 : sc.minX + h / 2, y: sc.minY)
        var legs: [CrawlLeg] = []
        // already on the floor? walk to the corner; on a window top, the app hops down first
        legs.append(CrawlLeg(from: CGPoint(x: w.foot.x, y: floorY), to: corner, surface: .floor))
        legs.append(CrawlLeg(from: wallBottom, to: wallTop, surface: right ? .rightWall : .leftWall))
        legs.append(CrawlLeg(from: ceilingStart, to: CGPoint(x: x, y: sc.minY), surface: .ceiling))
        return legs
    }

    mutating func moveWhileHanging(_ w: RoamWorld) -> Outing? {
        guard let anchor = w.hanging else { return nil }
        let sc = w.screen
        let half = w.sprite.width / 2
        for _ in 0..<6 {
            let x = CGFloat.random(in: (sc.minX + half)...(sc.maxX - half), using: &rng)
            let depth = CGFloat.random(in: 40...max(41, (w.active.map { $0.minY - 6 } ?? sc.midY) - w.sprite.height - sc.minY), using: &rng)
            let spot = CGPoint(x: x, y: sc.minY + depth)
            if abs(x - anchor.x) > 100, Self.fine(spot, w, surface: .hanging) {
                return .climbAndMove(to: CGPoint(x: x, y: sc.minY), dangle: depth)
            }
        }
        return nil
    }
}

// MARK: playing an outing

extension RoamPlanner {
    /// Frames each style cycles through while moving.
    public static func moveFrames(_ style: RoamStyle) -> [String] {
        switch style {
        case .drifter: ["idle_0", "idle_1"]
        case .crawler: ["move_0", "move_2"]
        default: ["move_0", "move_2"]
        }
    }

    /// A timeline for `outing` starting at `foot`. `hop` builds a hop (the app's route planner).
    public static func choreography(_ outing: Outing, from foot: CGPoint, style: RoamStyle, hanging: CGPoint?,
                                    hop: (CGPoint, CGPoint) -> Choreography) -> Choreography {
        let speed = style.speed
        let frames = moveFrames(style)
        func dur(_ a: CGPoint, _ b: CGPoint, _ v: CGFloat = speed) -> TimeInterval { max(0.3, Double(hypot(b.x - a.x, b.y - a.y) / v)) }
        switch outing {
        case .hop(let to, _):
            return hop(foot, to)
        case .walk(let to):
            let left = to.x < foot.x
            return Choreography([
                .travel(from: foot, to: to, frames: frames, fps: style == .trotter ? 10 : 6, surface: .floor, mirrored: left, bob: 0, alpha: 1, duration: dur(foot, to)),
                .settle(at: to, duration: 0.2),
            ])
        case .drift(let to):
            return Choreography([
                .travel(from: foot, to: to, frames: frames, fps: 2, surface: .floor, mirrored: to.x < foot.x, bob: 4, alpha: 0.72, duration: dur(foot, to)),
                .travel(from: to, to: to, frames: ["idle_0"], fps: 1, surface: .floor, mirrored: false, bob: 0, alpha: 1, duration: 0.4),
            ])
        case .glance(let at, let lookLeft):
            let move: Choreography = style == .drifter
                ? Choreography([.travel(from: foot, to: at, frames: frames, fps: 2, surface: .floor, mirrored: at.x < foot.x, bob: 4, alpha: 0.72, duration: dur(foot, at))])
                : hop(foot, at)
            return Choreography(move.segments + [
                .hold(at: at, frame: "emotion_curious", mirrored: lookLeft, duration: 2.6),
                .hold(at: at, frame: "idle_1", mirrored: lookLeft, duration: 0.8),
            ])
        case .pond(let t):
            return Choreography([
                .hold(at: foot, frame: "mischief_0", mirrored: false, duration: 0.35),   // crouch
                .hold(at: foot, frame: "mischief_1", mirrored: false, duration: 0.3),    // splash up
                .hold(at: foot, frame: "mischief_2", mirrored: false, duration: t),      // under, eyes peeking
                .hold(at: foot, frame: "mischief_1", mirrored: false, duration: 0.3),    // pop out
                .settle(at: foot, duration: 0.2),
            ])
        case .stalk(let to):
            let left = to.x < foot.x
            return Choreography([
                .travel(from: foot, to: to, frames: ["mischief_0", "mischief_1"], fps: 3, surface: .floor, mirrored: left, bob: 0, alpha: 1,
                        duration: dur(foot, to, speed * 0.5)),
                .hold(at: to, frame: "mischief_2", mirrored: left, duration: 1.0),       // the arch
                .settle(at: to, duration: 0.2),
            ])
        case .nap(let t) where style == .drifter:
            // Boo doesn't squash into a puddle: it dozes upright, floating and fading softly
            return Choreography([
                .travel(from: foot, to: foot, frames: ["emotion_sleepy"], fps: 1, surface: .floor, mirrored: false, bob: 5, alpha: 0.8, duration: t),
                .settle(at: foot, duration: 0.2),
            ])
        case .nap(let t):
            return Choreography([
                .hold(at: foot, frame: "rest_0", mirrored: false, duration: 0.5),
                .hold(at: foot, frame: "rest_1", mirrored: false, duration: t),
                .hold(at: foot, frame: "rest_0", mirrored: false, duration: 0.4),
            ])
        case .crawl(let legs, let dangle):
            var segs: [Choreography.Segment] = []
            var from = foot
            for leg in legs {
                // step onto the leg's surface (a wall or ceiling turn is instant at the corner)
                if leg.surface == .floor, abs(from.y - leg.from.y) > 4 {
                    segs += hop(from, leg.from).segments
                }
                segs.append(.travel(from: leg.from, to: leg.to, frames: frames, fps: 8, surface: leg.surface,
                                    mirrored: leg.to.x < leg.from.x || leg.to.y < leg.from.y, bob: 0, alpha: 1, duration: dur(leg.from, leg.to)))
                from = leg.to
            }
            if let d = dangle, let last = legs.last {
                let anchor = last.to
                segs.append(.dangle(anchor: anchor, from: 0, to: d, duration: Double(d / 90)))
            }
            return Choreography(segs)
        case .climbAndMove(let to, let dangle):
            guard let anchor = hanging else { return Choreography([]) }
            let depth = foot.y - anchor.y
            var segs: [Choreography.Segment] = [
                .dangle(anchor: anchor, from: depth, to: 0, duration: Double(depth / 120)),
                .travel(from: anchor, to: to, frames: frames, fps: 8, surface: .ceiling, mirrored: to.x < anchor.x, bob: 0, alpha: 1, duration: dur(anchor, to)),
            ]
            if let d = dangle { segs.append(.dangle(anchor: to, from: 0, to: d, duration: Double(d / 90))) }
            return Choreography(segs)
        }
    }
}
