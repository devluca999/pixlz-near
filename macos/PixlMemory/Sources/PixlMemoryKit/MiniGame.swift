import AppKit
import PixlzCore

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

/// Kiti's game: a laser dot follows your mouse and Kiti chases it, creeping when close and
/// pouncing; keep it moving. 20 s, counts how often Kiti catches it. Pure and seeded-free:
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
                // on the dot already (dist 0): no direction, it just lands (never NaN)
                pounceDir = dist > 0 ? CGVector(dx: dx / dist, dy: dy / dist) : CGVector(dx: 0, dy: 0)
                velocity = CGVector(dx: pounceDir.dx * Self.pounceSpeed, dy: pounceDir.dy * Self.pounceSpeed)
                return .pounced
            }
            phase = dist < Self.stalkRange ? .stalk : .run
            let top = phase == .stalk ? Self.runSpeed * 0.35 : Self.runSpeed
            let want = dist > 0 ? CGVector(dx: dx / dist * top, dy: dy / dist * top) : CGVector(dx: 0, dy: 0)
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
