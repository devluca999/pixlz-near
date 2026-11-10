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
    case prowler   // Kiti: walks the edge it's on, naps, hops up high
    case trotter   // Mochi: trots after the mouse, sniffs around folders
    case drifter   // Boo: drifts about, half see-through, haunts folders
    case crawler   // Silky: walks to the screen's side, climbs, crawls the ceiling, drops on silk
    case slider    // Slugg: crawls the floor, climbs a wall and rests up high (no thread), slides back down

    public static func of(id: String, movement: String) -> RoamStyle {
        switch id {
        case "frogg": .hopper
        case "cat": .prowler
        case "shiba": .trotter
        case "ghost": .drifter
        case "widow": .crawler
        case "slugg": .slider
        default: movement == "float" ? .drifter : .hopper
        }
    }

    /// Points per second on the move, and the frames it cycles while moving.
    var speed: CGFloat {
        switch self { case .hopper: 60; case .prowler: 55; case .trotter: 150; case .drifter: 45; case .crawler: 110; case .slider: 36 }
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

    /// Whole display frames (top-left), Dock and menu bar included: the screen's real sides.
    /// Empty: the visible frames stand in.
    public var displays: [CGRect] = []

    /// The x of a real side of the Pixl's screen to climb: the display's own edge (not the Dock's
    /// edge, which only runs part of the way up), and never the seam with a display beside it,
    /// where there's nothing to climb. Nil when that side has no edge.
    public func wallX(right: Bool) -> CGFloat? {
        let sc = screen
        let all = displays.isEmpty ? screens : displays
        let full = all.first { $0.insetBy(dx: -4, dy: -4).intersects(sc) && $0.minX <= sc.midX && sc.midX <= $0.maxX } ?? sc
        let x = right ? full.maxX : full.minX
        let neighbour = all.contains { d in d != full && abs((right ? d.minX : d.maxX) - x) < 2 && d.minY < full.maxY && d.maxY > full.minY }
        return neighbour ? nil : x
    }

    /// The side to climb: the nearer real edge (the path of least resistance), else the other.
    public func nearerWall(to x: CGFloat? = nil) -> (right: Bool, x: CGFloat)? {
        let sc = screen
        let preferRight = (x ?? foot.x) > sc.midX
        if let w = wallX(right: preferRight) { return (preferRight, w) }
        return wallX(right: !preferRight).map { (!preferRight, $0) }
    }
}

/// One outing.
public enum Outing: Equatable, Sendable {
    case hop(to: CGPoint, why: String)
    case walk(to: CGPoint)                                    // along the edge it stands on
    case drift(to: CGPoint)                                   // Boo
    case crawl(legs: [CrawlLeg], dangle: CGFloat?)            // Silky; then down a thread by this much
    /// Slugg's lap: up a wall, across the top upside down, down the far wall. With `fallAt`, he
    /// loses his grip at that x on the ceiling: drops, his shell lands on him, he crawls on to `end`.
    case lap(legs: [CrawlLeg], fallAt: CGFloat?, end: CGPoint)
    case climbAndMove(to: CGPoint, dangle: CGFloat?)          // Silky, hanging: up the thread, along, down again
    case glance(at: CGPoint, lookLeft: Bool)                  // read along: above your caret
    case nap(TimeInterval)
    case pond(TimeInterval)                                   // Frogg dives into a little pond, eyes peeking
    case stalk(to: CGPoint)                                   // Kiti creeps low, then arches its back

    public var name: String {
        switch self {
        case .hop(_, let why): "hop (\(why))"
        case .walk: "walk"
        case .drift: "drift"
        case .crawl(_, let d): d == nil ? "crawl" : "crawl and dangle"
        case .lap(_, let f, _): f == nil ? "lap over the top" : "lap over the top (falls off)"
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

    enum Kind { case folderHop, windowHop, glance, nap, walk, trot, drift, folderDrift, crawlTour, moveHanging, pond, stalk, climbDown,
                overWindow, offWindow, ceilingHome, lap }

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
        case .slider:
            // Slugg crawls: along the floor, up a wall (inside corner), up a window's side and over its
            // top (outside corner), back down off it, and now and then across the top upside down
            let sc = w.screen
            // high on a wall he keeps going: over the top and across, upside down
            if w.surface == .rightWall || w.surface == .leftWall { options = [(3, .lap), (1.5, .climbDown), (0.5, .nap)] }
            else if w.surface == .ceiling { options = [(3, .ceilingHome)] }
            else if w.foot.y < sc.maxY - 8 { options = [(2, .walk), (3, .offWindow), (0.5, .nap)] }   // on a window top
            else { options = [(3, .walk), (3, .lap), (2, .overWindow), (0.5, .nap)] }   // no more stopping high on a wall
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

    /// A named outing, for the debug build's e2e commands ("crawlTour", "overWindow", …).
    public mutating func outing(named n: String, _ w: RoamWorld) -> Outing? {
        // debug: a lap that's sure to fall off halfway
        if n == "lapFall", case .lap(let legs, _, let end)? = lap(w), let c = legs.first(where: { $0.surface == .ceiling }) {
            return .lap(legs: legs, fallAt: (c.from.x + c.to.x) / 2, end: end)
        }
        let k: Kind? = switch n {
        case "crawlTour": .crawlTour
        case "overWindow": .overWindow
        case "offWindow": .offWindow
        case "ceilingHome": .ceilingHome
        case "lap": .lap
        case "climbDown": .climbDown
        case "walk": .walk
        default: nil
        }
        return k.flatMap { make($0, w) }
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
        case .overWindow: overWindow(w)
        case .offWindow: offWindow(w)
        case .ceilingHome: ceilingHome(w)
        case .lap: lap(w)
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
        for _ in 0..<(style == .slider ? 0 : 10) {
            let x = CGFloat.random(in: (sc.minX + half)...(sc.maxX - half), using: &rng)
            let below = w.active.flatMap { a in a.minX - half < x && x < a.maxX + half ? a.minY - 6 : nil } ?? (sc.minY + sc.height * 0.35)
            let depth = min(below - w.sprite.height - sc.minY, sc.height * 0.4)
            let d: CGFloat = depth > 40 ? CGFloat.random(in: 40...depth, using: &rng) : 24
            guard Self.fine(CGPoint(x: x, y: sc.minY + d), w, surface: .hanging) else { continue }
            let legs = crawlToCeiling(w, x: x)
            return legs.isEmpty ? nil : .crawl(legs: legs, dangle: d)
        }
        // Slugg, now and then: up the wall and across the top, upside down
        if style == .slider, Int.random(in: 0..<3, using: &rng) == 0 {
            for _ in 0..<6 {
                let x = CGFloat.random(in: (sc.minX + half * 3)...(sc.maxX - half * 3), using: &rng)
                let legs = crawlToCeiling(w, x: x)
                if legs.count == 3, Self.fine(legs[2].to, w, surface: .ceiling) { return .crawl(legs: legs, dangle: nil) }
            }
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
        let corner = CGPoint(x: right ? w.foot.x - h / 2 : w.foot.x + h / 2, y: sc.maxY)   // at the foot of the wall it's on
        for _ in 0..<6 {
            let x = CGFloat.random(in: (sc.minX + half)...(sc.maxX - half), using: &rng)
            let end = CGPoint(x: x, y: sc.maxY)
            if abs(x - corner.x) > 120, Self.fine(end, w) {
                return .crawl(legs: [down, CrawlLeg(from: corner, to: end, surface: .floor)], dangle: nil)
            }
        }
        return nil
    }

    /// Slugg: along the floor to a window that stands on it, up its side and over the top (an
    /// outside corner), then a little way along its top.
    mutating func overWindow(_ w: RoamWorld) -> Outing? {
        let sc = w.screen, floorY = sc.maxY, half = w.sprite.width / 2, h = w.sprite.height
        let windows = ((w.active.map { [$0] } ?? []) + w.others).filter { $0.maxY >= floorY - 12 && $0.minY > sc.minY + h * 2 && $0.width > w.sprite.width * 2 }
        for r in windows.shuffled(using: &rng) {
            let fromLeft = w.foot.x < r.minX
            guard fromLeft || w.foot.x > r.maxX else { continue }   // behind it: no side to climb
            let side = fromLeft ? r.minX : r.maxX
            let along = CGFloat.random(in: min(60, r.width / 3)...max(61, min(240, r.width - half)), using: &rng)
            let end = CGPoint(x: fromLeft ? side + along : side - along, y: r.minY)
            guard Self.fine(end, w) else { continue }
            return .crawl(legs: [CrawlLeg(from: w.foot, to: CGPoint(x: side, y: floorY), surface: .floor),
                                 CrawlLeg(from: CGPoint(x: side, y: floorY), to: CGPoint(x: side, y: r.minY), surface: fromLeft ? .rightWall : .leftWall),
                                 CrawlLeg(from: CGPoint(x: side, y: r.minY), to: end, surface: .floor)], dangle: nil)
        }
        return nil
    }

    /// Slugg on a window top that stands on the floor: to its nearer end, over the edge and down
    /// its side, and off along the floor.
    mutating func offWindow(_ w: RoamWorld) -> Outing? {
        let sc = w.screen, floorY = sc.maxY
        let windows = (w.active.map { [$0] } ?? []) + w.others
        guard let r = windows.first(where: { abs($0.minY - w.foot.y) < 6 && $0.minX <= w.foot.x && w.foot.x <= $0.maxX && $0.maxY >= floorY - 12 }) else { return nil }
        let left = w.foot.x - r.minX < r.maxX - w.foot.x
        let side = left ? r.minX : r.maxX
        guard left ? side - sc.minX > 140 : sc.maxX - side > 140 else { return nil }
        let end = CGPoint(x: left ? side - CGFloat.random(in: 80...140, using: &rng) : side + CGFloat.random(in: 80...140, using: &rng), y: floorY)
        guard Self.fine(end, w) else { return nil }
        return .crawl(legs: [CrawlLeg(from: w.foot, to: CGPoint(x: side, y: r.minY), surface: .floor),
                             CrawlLeg(from: CGPoint(x: side, y: r.minY), to: CGPoint(x: side, y: floorY), surface: left ? .rightWall : .leftWall),
                             CrawlLeg(from: CGPoint(x: side, y: floorY), to: end, surface: .floor)], dangle: nil)
    }

    /// Slugg upside down at the top: back along to the nearer side, down the wall, onto the floor.
    mutating func ceilingHome(_ w: RoamWorld) -> Outing? {
        let sc = w.screen, h = w.sprite.height
        guard let (right, wallX) = w.nearerWall() else { return nil }
        let end = CGPoint(x: right ? wallX - CGFloat.random(in: 140...320, using: &rng) : wallX + CGFloat.random(in: 140...320, using: &rng), y: sc.maxY)
        return .crawl(legs: [CrawlLeg(from: w.foot, to: CGPoint(x: wallX, y: sc.minY), surface: .ceiling),
                             CrawlLeg(from: CGPoint(x: wallX, y: sc.minY + h / 2), to: CGPoint(x: wallX, y: sc.maxY - h / 2), surface: right ? .rightWall : .leftWall),
                             CrawlLeg(from: CGPoint(x: wallX, y: sc.maxY), to: end, surface: .floor)], dangle: nil)
    }

    /// Slugg's body without its shell (the shell falls on its own a moment later).
    public static let bareBody = "crawl_0_body"
    /// How long he hangs on bare after his shell has hit the floor.
    public static let bareHang: TimeInterval = 0.5


    /// Chance that Slugg loses his grip on a lap (he's no spider).
    public static let lapFallChance = 0.35

    /// Slugg: up the nearer wall (or on from the wall he's on), across the whole top upside down,
    /// down the far wall and off along the floor. Sometimes he drops off on the way (`fallAt`).
    mutating func lap(_ w: RoamWorld) -> Outing? {
        let sc = w.screen, h = w.sprite.height, floorY = sc.maxY
        guard sc.width > h * 6 else { return nil }
        let onWall = w.surface == .rightWall || w.surface == .leftWall
        // up the nearer real edge, down the far one: both must be there
        guard let near = onWall ? (w.surface == .rightWall, w.foot.x) : w.nearerWall() else { return nil }
        let startRight = near.0, wallX = near.1
        guard let farX = w.wallX(right: !startRight) else { return nil }
        let inward: CGFloat = startRight ? -1 : 1
        var legs: [CrawlLeg] = []
        if onWall {
            legs.append(CrawlLeg(from: w.foot, to: CGPoint(x: wallX, y: sc.minY + h / 2), surface: w.surface))
        } else {
            // along the floor to half a body from the wall, then up it
            legs.append(CrawlLeg(from: CGPoint(x: w.foot.x, y: floorY), to: CGPoint(x: wallX + inward * h / 2, y: floorY), surface: .floor))
            legs.append(CrawlLeg(from: CGPoint(x: wallX, y: floorY - h / 2), to: CGPoint(x: wallX, y: sc.minY + h / 2), surface: startRight ? .rightWall : .leftWall))
        }
        let ceilingFrom = CGPoint(x: wallX + inward * h / 2, y: sc.minY)
        let ceilingTo = CGPoint(x: farX - inward * h / 2, y: sc.minY)
        legs.append(CrawlLeg(from: ceilingFrom, to: ceilingTo, surface: .ceiling))
        legs.append(CrawlLeg(from: CGPoint(x: farX, y: sc.minY + h / 2), to: CGPoint(x: farX, y: floorY - h / 2), surface: startRight ? .leftWall : .rightWall))
        // where he ends up on the far side: clear of your caret (never by the prompt you're typing in)
        var endX: CGFloat?
        for i in 0..<10 {
            let inset = i < 5 ? CGFloat.random(in: 140...320, using: &rng) : CGFloat.random(in: 320...max(321, sc.width / 2), using: &rng)
            let x = farX - inward * inset
            if Self.fine(CGPoint(x: x, y: floorY), w) { endX = x; break }
        }
        guard let endX else { return nil }
        legs.append(CrawlLeg(from: CGPoint(x: farX - inward * h / 2, y: floorY), to: CGPoint(x: endX, y: floorY), surface: .floor))
        let end = CGPoint(x: endX, y: floorY)
        var fallAt: CGFloat?
        if Double.random(in: 0..<1, using: &rng) < Self.lapFallChance {
            let t = CGFloat.random(in: 0.25...0.75, using: &rng)
            fallAt = ceilingFrom.x + (ceilingTo.x - ceilingFrom.x) * t
        }
        return .lap(legs: legs, fallAt: fallAt, end: end)
    }

    /// From the floor: along to the nearer side, up the wall, along the ceiling to `x`.
    func crawlToCeiling(_ w: RoamWorld, x: CGFloat) -> [CrawlLeg] {
        let sc = w.screen
        let h = w.sprite.height
        let floorY = sc.maxY
        guard let (right, wallX) = w.nearerWall() else { return [] }
        let corner = CGPoint(x: right ? wallX - h / 2 : wallX + h / 2, y: floorY)
        let wallBottom = CGPoint(x: wallX, y: floorY - h / 2)
        let wallTop = CGPoint(x: wallX, y: sc.minY + h / 2)
        let ceilingStart = CGPoint(x: right ? wallX - h / 2 : wallX + h / 2, y: sc.minY)
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

/// A Pixl's locomotion loop (C13): the frames, their rate, and the ground speed that keeps the
/// feet from skating. `bob` lifts the whole sprite in the stride's float (Mochi: 1 art pixel).
public struct Gait: Equatable, Sendable {
    public var frames: [String]
    public var fps: Double
    public var speed: CGFloat      // pt/s
    public var bob: CGFloat        // pt, phase-locked to the loop
    public init(frames: [String], fps: Double, speed: CGFloat, bob: CGFloat = 0) {
        self.frames = frames; self.fps = fps; self.speed = speed; self.bob = bob
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
    /// `wrap` gives the corner loop between two crawl legs (Slugg), or nil: an instant turn.
    public static func choreography(_ outing: Outing, from foot: CGPoint, style: RoamStyle, hanging: CGPoint?, gait: Gait? = nil,
                                    surface: Surface = .floor, wrap: ((CrawlLeg, CrawlLeg) -> CornerWrap?)? = nil,
                                    hop: (CGPoint, CGPoint) -> Choreography) -> Choreography {
        let speed = gait?.speed ?? style.speed
        let frames = gait?.frames ?? moveFrames(style)
        let fps = gait?.fps ?? (style == .trotter ? 10 : 6)
        let bob = -(gait?.bob ?? 0)   // negative: phase-locked to the loop
        func dur(_ a: CGPoint, _ b: CGPoint, _ v: CGFloat = speed) -> TimeInterval { max(0.3, Double(hypot(b.x - a.x, b.y - a.y) / v)) }
        switch outing {
        case .hop(let to, _):
            return hop(foot, to)
        case .walk(let to):
            let left = to.x < foot.x
            return Choreography([
                .travel(from: foot, to: to, frames: frames, fps: fps, surface: .floor, mirrored: left, bob: bob, alpha: 1, duration: dur(foot, to)),
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
        case .nap(let t) where surface != .floor:
            // on a wall or upside down: it naps where it is, still on that surface
            return Choreography([.travel(from: foot, to: foot, frames: ["rest_1"], fps: 1, surface: surface, mirrored: false, bob: 0, alpha: 1, duration: t)])
        case .nap(let t):
            return Choreography([
                .hold(at: foot, frame: "rest_0", mirrored: false, duration: 0.5),
                .hold(at: foot, frame: "rest_1", mirrored: false, duration: t),
                .hold(at: foot, frame: "rest_0", mirrored: false, duration: 0.4),
            ])
        case .crawl(let legs0, let dangle):
            // corners: Slugg wraps round them (the legs end and start where its corner loop does);
            // anyone else turns at once
            var legs = legs0
            var wraps: [Int: CornerWrap] = [:]   // before leg i
            if let wrap {
                for i in 1..<max(1, legs.count) {
                    guard let w = wrap(legs[i - 1], legs[i]) else { continue }
                    legs[i - 1].to = w.start
                    legs[i].from = w.end
                    wraps[i] = w
                }
            }
            var segs: [Choreography.Segment] = []
            var from = foot
            for (i, leg) in legs.enumerated() {
                if let w = wraps[i] { segs.append(.wrap(w, duration: Double(w.frames.count) / w.fps)) }
                // step onto the leg's surface (a wall or ceiling turn is instant at the corner)
                else if leg.surface == .floor, abs(from.y - leg.from.y) > 4 {
                    segs += hop(from, leg.from).segments
                }
                segs.append(.travel(from: leg.from, to: leg.to, frames: frames, fps: gait?.fps ?? 8, surface: leg.surface,
                                    mirrored: leg.to.x < leg.from.x || leg.to.y < leg.from.y, bob: 0, alpha: 1, duration: dur(leg.from, leg.to)))
                from = leg.to
            }
            if let d = dangle, let last = legs.last {
                let anchor = last.to
                segs.append(.dangle(anchor: anchor, from: 0, to: d, duration: Double(d / 90)))
            }
            return Choreography(segs)
        case .lap(let legs, let fallAt, let end):
            guard let x = fallAt, let c = legs.firstIndex(where: { $0.surface == .ceiling }) else {
                return choreography(.crawl(legs: legs, dangle: nil), from: foot, style: style, hanging: hanging, gait: gait,
                                    surface: surface, wrap: wrap, hop: hop)
            }
            // up and partway across, upside down
            var upTo = Array(legs[...c])
            upTo[c].to.x = x
            let first = choreography(.crawl(legs: upTo, dangle: nil), from: foot, style: style, hanging: hanging, gait: gait,
                                     surface: surface, wrap: wrap, hop: hop)
            let grip = first.pose(at: first.duration).pose.foot
            let left = end.x < grip.x
            let floorY = end.y
            func fall(_ d: CGFloat) -> TimeInterval { max(0.35, Double((max(d, 1) / 1800).squareRoot() * 1.4)) }
            // on his back on the floor: his feet up, his shell under him
            // (the under pose is a little taller than he stands: the far wall leg ends half a body up)
            let bodyH = legs.last(where: { $0.surface == .rightWall || $0.surface == .leftWall }).map { 2 * (floorY - $0.to.y) } ?? 62
            let onBack = CGPoint(x: grip.x, y: floorY - bodyH * 1.1)
            let flip = CGPoint(x: grip.x, y: floorY - (floorY - onBack.y) / 2)
            let landing = CGPoint(x: grip.x, y: floorY)
            return Choreography(first.segments + [
                // a wobble upside down…
                .travel(from: grip, to: grip, frames: ["crawl_0", "crawl_4"], fps: 9, surface: .ceiling, mirrored: left, bob: 0, alpha: 1, duration: 0.45),
                // …his shell lets go first and drops to the floor; he hangs on bare for a moment
                .travel(from: grip, to: grip, frames: [Self.bareBody], fps: 1, surface: .ceiling, mirrored: left, bob: 0, alpha: 1,
                        duration: fall(floorY - grip.y) + Self.bareHang),
                // then he falls too, on his back, onto it
                .tumble(from: grip, to: onBack, frame: Self.bareBody, mirrored: left, duration: fall(onBack.y - grip.y)),
                .travel(from: onBack, to: onBack, frames: ["crawl_0"], fps: 1, surface: .ceiling, mirrored: left, bob: 0, alpha: 1, duration: 0.5),
                // flips the right way up
                .travel(from: flip, to: flip, frames: ["crawl_2"], fps: 1, surface: left ? .rightWall : .leftWall, mirrored: false, bob: 0, alpha: 1, duration: 0.12),
                .land(at: landing, frame: "crawl_0", mirrored: left, duration: 0.3, dust: true),
                // and keeps going
                .travel(from: landing, to: end, frames: frames, fps: gait?.fps ?? 8, surface: .floor, mirrored: left, bob: 0, alpha: 1,
                        duration: dur(landing, end)),
            ])
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
