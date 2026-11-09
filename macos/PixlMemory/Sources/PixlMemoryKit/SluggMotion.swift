import CoreGraphics

/// How an anchored frame is turned when drawn: quarter turns counter-clockwise (as seen on
/// screen), after an optional left-right flip.
public struct ArtTurn: Equatable, Sendable {
    public var turns: Int
    public var flip: Bool
    public init(_ turns: Int = 0, flip: Bool = false) { self.turns = ((turns % 4) + 4) % 4; self.flip = flip }
    public static let none = ArtTurn()

    /// A vector in screen coordinates (y down) turned the same way the art is.
    public func apply(_ v: CGPoint) -> CGPoint {
        var p = CGPoint(x: flip ? -v.x : v.x, y: v.y)
        for _ in 0..<turns { p = CGPoint(x: p.y, y: -p.x) }   // a quarter turn CCW on screen: down → right → up
        return p
    }
}

/// One corner Slugg wraps around: the loop to play there, turned to fit, and where it starts
/// and ends (screen points, the contact on each surface).
public struct CornerWrap: Equatable, Sendable {
    public var frames: [String]
    public var fps: Double
    public var turn: ArtTurn
    public var at: CGPoint
    public var start: CGPoint
    public var end: CGPoint
}

/// Slugg's soft body (C11/C13): its own poses on walls, beneath edges and around corners, in
/// place of a turned floor frame. Frames come from scripts/render-pixls.mjs with an `anchor`
/// (where they touch): crawl, climb (a wall on its right, heading up), under (beneath an edge,
/// heading left), wrapin (floor → a wall ahead: an inside corner), wrapout (up a side and over
/// the top: an outside corner).
public enum SluggMotion {
    /// The frame to draw instead of `frame` on `surface`, and how to turn it; nil when the
    /// ordinary drawing applies. `mirrored` is the pose's facing (on a wall: true while it heads up).
    public static func native(frame: String, surface: Surface, mirrored: Bool, turns: Int, has: (String) -> Bool) -> (name: String, turn: ArtTurn)? {
        if frame.hasPrefix("wrapin_") || frame.hasPrefix("wrapout_") { return has(frame) ? (frame, ArtTurn(turns, flip: mirrored)) : nil }
        let travelling = frame.hasPrefix("crawl_")
        let i = travelling ? Int(frame.dropFirst(6)) ?? 0 : 0
        switch surface {
        case .floor:
            return travelling && has(frame) ? (frame, ArtTurn(0, flip: mirrored)) : nil
        case .rightWall, .leftWall:
            let name = "climb_\(i % 8)"
            guard has(name) else { return nil }
            let up = !travelling || mirrored            // resting on a wall: head up
            let left = surface == .leftWall
            // the art climbs with the wall on its right, heading up
            return (name, up ? ArtTurn(0, flip: left) : ArtTurn(2, flip: !left))
        case .ceiling:
            let name = "under_\(i % 6)"
            guard has(name) else { return nil }
            return (name, ArtTurn(0, flip: travelling && !mirrored))   // the art heads left
        case .hanging:
            return nil
        }
    }

    /// The corner between two crawl legs and how the loop turns to fit it, or nil (no corner).
    public static func corner(_ a: CrawlLeg, _ b: CrawlLeg) -> (kind: String, turn: ArtTurn, at: CGPoint)? {
        let vertical: (Surface) -> Bool = { $0 == .rightWall || $0 == .leftWall }
        guard a.surface != b.surface else { return nil }
        let wall = vertical(a.surface) ? a : b, flat = vertical(a.surface) ? b : a
        guard vertical(wall.surface), !vertical(flat.surface) else { return nil }
        let at = CGPoint(x: wall.from.x, y: flat.from.y)
        let up = a.to.y < a.from.y, down = b.to.y > b.from.y
        switch (a.surface, b.surface) {
        // off a top edge and down its side (an outside corner, the other way round)
        case (.floor, .rightWall) where down: return ("wrapout", ArtTurn(1, flip: true), at)   // the loop mirrored on its diagonal
        case (.floor, .leftWall) where down: return ("wrapout", ArtTurn(3), at)
        case (.floor, .rightWall): return ("wrapin", ArtTurn(0), at)
        case (.floor, .leftWall): return ("wrapin", ArtTurn(0, flip: true), at)
        case (.rightWall, .ceiling): return ("wrapin", ArtTurn(1), at)
        case (.leftWall, .ceiling): return ("wrapin", ArtTurn(3, flip: true), at)
        case (.ceiling, .leftWall): return ("wrapin", ArtTurn(2), at)
        case (.ceiling, .rightWall): return ("wrapin", ArtTurn(2, flip: true), at)
        case (.rightWall, .floor): return up ? ("wrapout", ArtTurn(0), at) : ("wrapin", ArtTurn(1, flip: true), at)
        case (.leftWall, .floor): return up ? ("wrapout", ArtTurn(0, flip: true), at) : ("wrapin", ArtTurn(3), at)
        default: return nil
        }
    }

    /// Where a corner loop starts and ends, in art pixels from its anchor (y down), untuned:
    /// the contact on the first surface in its first frame and on the second in its last.
    public static func ends(_ kind: String, frames: [String: FroggArt.Frame]) -> (start: CGPoint, end: CGPoint)? {
        let names = (0..<8).map { "\(kind)_\($0)" }
        guard let f0 = frames[names[0]], let f1 = frames[names[7]], let a = f0.anchor, a.count == 2 else { return nil }
        let b0 = opaqueBox(f0), b1 = opaqueBox(f1)
        let ax = CGFloat(a[0]), ay = CGFloat(a[1])
        if kind == "wrapin" {
            // on the floor before it (bottom middle of the body), on the wall after (the body's middle height)
            return (CGPoint(x: b0.midX - ax, y: b0.maxY - ay), CGPoint(x: 0, y: b1.midY - ay))
        }
        // wrapout: on the side below it, then on the top beyond it
        return (CGPoint(x: 0, y: b0.midY - ay), CGPoint(x: b1.midX - ax, y: 0))
    }

    /// The corner to play between two legs at `scale` (points per art pixel), from `art`.
    public static func wrap(_ a: CrawlLeg, _ b: CrawlLeg, art: FroggArt, scale: CGFloat) -> CornerWrap? {
        guard let c = corner(a, b), let e = ends(c.kind, frames: art.frames) else { return nil }
        let names = (0..<8).map { "\(c.kind)_\($0)" }
        guard names.allSatisfy({ art.frames[$0] != nil }) else { return nil }
        let s = c.turn.apply(CGPoint(x: e.start.x * scale, y: e.start.y * scale))
        let t = c.turn.apply(CGPoint(x: e.end.x * scale, y: e.end.y * scale))
        return CornerWrap(frames: names, fps: 6, turn: c.turn, at: c.at,
                          start: CGPoint(x: c.at.x + s.x, y: c.at.y + s.y), end: CGPoint(x: c.at.x + t.x, y: c.at.y + t.y))
    }

    /// The opaque pixels' box of a frame, in art pixels (y down).
    static func opaqueBox(_ f: FroggArt.Frame) -> CGRect {
        var x0 = f.w, y0 = f.h, x1 = -1, y1 = -1
        for (y, row) in f.rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
        }
        return x1 < 0 ? .zero : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }
}
