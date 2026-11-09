import AppKit
import PixlzCore

/// Mischief ▸ Catch: for 20 s, things pop up around the Pixl (flies for Frogg, yarn for Katt…);
/// click one before it vanishes and the Pixl snaps it. Pure rules here (seeded, testable);
/// the app draws targets and reacts.
public struct CatchGame: Sendable {
    public struct Target: Equatable, Sendable {
        public let id: Int
        public let center: CGPoint        // top-left global coordinates
        public let born: TimeInterval
        public let life: TimeInterval
        public var dies: TimeInterval { born + life }
    }
    public enum Event: Equatable, Sendable { case spawn(Target), missed(Target), over(score: Int, missed: Int) }

    public static let duration: TimeInterval = 20
    public static let gap: TimeInterval = 0.35          // between one target going and the next
    public static let firstLife: TimeInterval = 1.6     // each target stays a little shorter…
    public static let lastLife: TimeInterval = 0.85     // …down to this, by the end
    public static let ring: ClosedRange<CGFloat> = 90...240   // how far from the Pixl they pop up

    public private(set) var score = 0
    public private(set) var missed = 0
    public private(set) var current: Target?
    public private(set) var finished = false
    var rng: SeededRandom
    var started: TimeInterval = 0
    var nextSpawn: TimeInterval = 0
    var nextID = 0
    var around: CGPoint = .zero
    var bounds: CGRect = .zero

    public init(seed: UInt64) { rng = SeededRandom(seed: seed) }

    public mutating func start(at t: TimeInterval, around p: CGPoint, bounds b: CGRect) {
        started = t; nextSpawn = t + 0.4; around = p; bounds = b
        score = 0; missed = 0; current = nil; finished = false
    }

    /// How long a target lives at time `t`: shorter as the game goes on.
    public func life(at t: TimeInterval) -> TimeInterval {
        let f = min(max((t - started) / Self.duration, 0), 1)
        return Self.firstLife + (Self.lastLife - Self.firstLife) * f
    }

    /// A spot on a ring around the Pixl, inside `bounds` (16 pt margin), never on the Pixl.
    mutating func spot() -> CGPoint {
        let inner = bounds.insetBy(dx: 16, dy: 16)
        for _ in 0..<24 {
            let a = Double.random(in: 0..<(2 * .pi), using: &rng)
            let r = CGFloat.random(in: Self.ring, using: &rng)
            let p = CGPoint(x: around.x + cos(a) * r, y: around.y - 40 + sin(a) * r * 0.7)
            if inner.contains(p) { return p }
        }
        return CGPoint(x: min(max(around.x, inner.minX), inner.maxX), y: min(max(around.y - 160, inner.minY), inner.maxY))
    }

    /// Advances to `t`. At most one event per call (the app calls it every frame or so).
    public mutating func tick(_ t: TimeInterval) -> Event? {
        guard !finished else { return nil }
        if let c = current, t >= c.dies {
            current = nil
            missed += 1
            nextSpawn = t + Self.gap
            return .missed(c)
        }
        if t - started >= Self.duration, current == nil {
            finished = true
            return .over(score: score, missed: missed)
        }
        if current == nil, t >= nextSpawn, t - started < Self.duration {
            nextID += 1
            let target = Target(id: nextID, center: spot(), born: t, life: life(at: t))
            current = target
            return .spawn(target)
        }
        return nil
    }

    /// The user clicked target `id` at `t`. True if it counted.
    public mutating func hit(_ id: Int, at t: TimeInterval) -> Bool {
        guard let c = current, c.id == id, t < c.dies, !finished else { return false }
        current = nil
        score += 1
        nextSpawn = t + Self.gap
        return true
    }
}

/// The things to catch, one per Pixl (pixl.json `ui.game.target`), as 10 × 10 pixel grids.
@MainActor
public enum GameArt {
    static let grids: [String: (grid: [String], colors: [Character: String])] = [
        "fly": (["...k..k...", "..kwk.kwk.", "..kwwkwwk.", "...kkkkk..", "..kaaaaak.", ".kaaaaaaak", "..kaaaaak.", "...kkkkk..", "..k..k..k.", ".........."],
                ["k": "#1B2A1A", "w": "#DDEBFF", "a": "#3A4A3A"]),
        "yarn": ([".........k", "...kkkk.k.", "..kaabak..", ".kababaak.", ".kaabaabk.", ".kbaabaak.", ".kaababak.", "..kabaak..", "...kkkk...", ".........."],
                 ["k": "#1B2A1A", "a": "#AE90EC", "b": "#D9C8FF"]),
        "ball": (["...kkkk...", "..kaaaak..", ".kaabbaak.", ".kabaaabk.", ".kaaaaaak.", ".kbaaaabk.", ".kaabbaak.", "..kaaaak..", "...kkkk...", ".........."],
                 ["k": "#1B2A1A", "a": "#D9F25A", "b": "#FFFBF2"]),
        "leaf": (["......k...", ".....kak..", "....kaaak.", "...kaabaak", "..kaabaaak", ".kaabaaak.", ".kabaaak..", "kbbaakk...", ".kkkk.....", ".........."],
                 ["k": "#1B2A1A", "a": "#7CC24A", "b": "#3E7A2A"]),
        "laser": (["..........", "...kkkk...", "..kbbbbk..", ".kbaaaabk.", ".kbawaabk.", ".kbaaaabk.", ".kbaaaabk.", "..kbbbbk..", "...kkkk...", ".........."],
                  ["k": "#1B2A1A", "a": "#FF1A26", "b": "#FF8A90", "w": "#FFFFFF"]),
        "sock": (["..kkkk....", "..kbbk....", "..kaak....", "..kaak....", "..kaak....", "..kaakkk..", ".kaaaaaak.", ".kaaaaaak.", "..kkkkkk..", ".........."],
                 ["k": "#1B2A1A", "a": "#FFFBF2", "b": "#A8C8F0"]),
    ]

    public static func image(_ name: String, scale: CGFloat = 3) -> NSImage? {
        guard let (grid, colors) = grids[name] else { return nil }
        let h = grid.count, w = grid.map(\.count).max() ?? 0
        return NSImage(size: NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale), flipped: true) { _ in
            for (y, row) in grid.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let hex = colors[ch] else { continue }
                    let c = RGB(hex: hex)
                    NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
                    NSRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale).fill()
                }
            }
            return true
        }
    }

    public static var names: [String] { grids.keys.sorted() }
}

/// Katt's game: a laser dot follows your mouse and Katt chases it, creeping when close and
/// pouncing; keep it moving. 20 s, counts how often Katt catches it. Pure and seeded-free:
/// the app feeds the dot (the mouse) and time, and draws `cat` with `phase`.
public struct LaserChase: Sendable {
    public enum Phase: Equatable, Sendable { case run, stalk, pounce, caught }
    public enum Event: Equatable, Sendable { case pounced, caught(Int), over(catches: Int) }

    public static let duration: TimeInterval = 20
    public static let runSpeed: CGFloat = 430       // pt/s, a bit slower than a quick hand
    public static let accel: CGFloat = 1500
    public static let stalkRange: CGFloat = 170     // creeps when this close
    public static let pounceRange: CGFloat = 120
    public static let pounceSpeed: CGFloat = 1100
    public static let pounceTime: TimeInterval = 0.22
    public static let catchRadius: CGFloat = 30
    public static let rest: TimeInterval = 0.7      // sits a moment after a catch

    public private(set) var cat: CGPoint             // where its head is aiming from (body centre)
    public private(set) var velocity = CGVector.zero
    public private(set) var phase = Phase.run
    public private(set) var catches = 0
    public private(set) var finished = false
    var started: TimeInterval
    var phaseUntil: TimeInterval = 0
    var pounceDir = CGVector.zero
    var bounds: CGRect

    public init(cat: CGPoint, at t: TimeInterval, bounds: CGRect) { self.cat = cat; started = t; self.bounds = bounds }

    public var facingLeft: Bool { velocity.dx < -1 }

    /// Advance by `dt` to time `t` with the dot at `dot`.
    public mutating func step(dt: TimeInterval, at t: TimeInterval, dot: CGPoint) -> Event? {
        guard !finished else { return nil }
        if t - started >= Self.duration { finished = true; return .over(catches: catches) }
        let dx = dot.x - cat.x, dy = dot.y - cat.y
        let dist = max(hypot(dx, dy), 0.001)
        let d = CGFloat(dt)
        switch phase {
        case .caught:
            velocity = .zero
            if t >= phaseUntil { phase = .run }
            return nil
        case .pounce:
            cat.x += pounceDir.dx * Self.pounceSpeed * d
            cat.y += pounceDir.dy * Self.pounceSpeed * d
            clamp()
            if dist < Self.catchRadius {
                catches += 1
                phase = .caught; phaseUntil = t + Self.rest
                return .caught(catches)
            }
            if t >= phaseUntil { phase = .run; velocity = CGVector(dx: pounceDir.dx * Self.runSpeed * 0.3, dy: pounceDir.dy * Self.runSpeed * 0.3) }
            return nil
        case .run, .stalk:
            if dist < Self.pounceRange {
                phase = .pounce; phaseUntil = t + Self.pounceTime
                pounceDir = CGVector(dx: dx / dist, dy: dy / dist)
                velocity = CGVector(dx: pounceDir.dx * Self.pounceSpeed, dy: pounceDir.dy * Self.pounceSpeed)
                return .pounced
            }
            phase = dist < Self.stalkRange ? .stalk : .run
            let top = phase == .stalk ? Self.runSpeed * 0.35 : Self.runSpeed
            let want = CGVector(dx: dx / dist * top, dy: dy / dist * top)
            let ddx = want.dx - velocity.dx, ddy = want.dy - velocity.dy
            let dv = hypot(ddx, ddy), maxDv = Self.accel * d
            if dv > maxDv { velocity.dx += ddx / dv * maxDv; velocity.dy += ddy / dv * maxDv } else { velocity = want }
            cat.x += velocity.dx * d
            cat.y += velocity.dy * d
            clamp()
            return nil
        }
    }

    mutating func clamp() {
        cat.x = min(max(cat.x, bounds.minX), bounds.maxX - 1)
        cat.y = min(max(cat.y, bounds.minY), bounds.maxY - 1)
    }
}
