import CoreGraphics
import Foundation

// SPEC §7. All rects are world coordinates (pt, y-down; see Physics.swift).

/// One display as the platform layer reports it.
public struct DisplayInfo: Sendable, Equatable {
    public var id: Int
    public var frame: CGRect
    /// `frame` minus the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// The Dock's rect on this display if it's showing here, at the bottom, and not auto-hidden.
    public var dockFrame: CGRect?

    public init(id: Int, frame: CGRect, visibleFrame: CGRect, dockFrame: CGRect? = nil) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.dockFrame = dockFrame
    }
}

/// A normal (layer 0) on-screen window.
public struct WindowInfo: Sendable, Equatable {
    public var id: Int
    public var frame: CGRect
    public init(id: Int, frame: CGRect) { self.id = id; self.frame = frame }
}

public struct WorldInput: Sendable, Equatable {
    public var displays: [DisplayInfo]
    /// Front to back, as CGWindowList returns them.
    public var windows: [WindowInfo]
    public var focusedWindowID: Int?
    /// No Accessibility permission: ground, Dock and menu bar only (D12).
    public var groundOnly: Bool

    public init(displays: [DisplayInfo], windows: [WindowInfo] = [], focusedWindowID: Int? = nil, groundOnly: Bool = false) {
        self.displays = displays
        self.windows = windows
        self.focusedWindowID = focusedWindowID
        self.groundOnly = groundOnly
    }
}

public enum SurfaceKind: Sendable, Hashable {
    case ground(display: Int)
    case dockTop(display: Int)
    case windowTop(window: Int)
    /// Sticky species hang below it (SPEC §7.1).
    case menuBarUnderside(display: Int)
}

/// A horizontal surface at `y` with its visible x-intervals.
public struct Platform: Sendable, Equatable {
    public var kind: SurfaceKind
    public var y: CGFloat
    public var intervals: [ClosedRange<CGFloat>]
    public var isHang: Bool { if case .menuBarUnderside = kind { true } else { false } }

    public func contains(x: CGFloat) -> Bool { intervals.contains { $0.contains(x) } }
}

public enum Side: Sendable, Hashable { case left, right }

/// A visible vertical stretch of a window's side (cling surface for sticky species).
public struct WindowSide: Sendable, Equatable {
    public var window: Int
    public var side: Side
    public var x: CGFloat
    public var intervals: [ClosedRange<CGFloat>]
}

/// Where a standing Pixl's anchor is.
public struct Spot: Sendable, Equatable {
    public var surface: SurfaceKind
    public var point: CGPoint
    public init(surface: SurfaceKind, point: CGPoint) { self.surface = surface; self.point = point }
}

/// The Pixl's size on screen, for hitbox and hop-range checks.
public struct PixlGeometry: Sendable, Equatable {
    public var manifest: PixlManifest
    public var scale: CGFloat

    public init(manifest: PixlManifest, scale: CGFloat) { self.manifest = manifest; self.scale = scale }

    /// The hitbox in world coordinates with the anchor at `anchor`, facing right.
    public func hitbox(at anchor: CGPoint) -> CGRect {
        let hb = manifest.hitbox, a = manifest.anchor
        return CGRect(
            x: anchor.x + CGFloat(hb.x - a.x) * scale, y: anchor.y + CGFloat(hb.y - a.y) * scale,
            width: CGFloat(hb.w) * scale, height: CGFloat(hb.h) * scale)
    }

    public var maxHopDistance: CGFloat { CGFloat(manifest.physics.hopDistance[1]) * scale }
    public var minHopDistance: CGFloat { CGFloat(manifest.physics.hopDistance[0]) * scale }
    /// Highest one hop can climb: as high as it can jump far.
    public var maxRise: CGFloat { maxHopDistance }
    public var apexRange: ClosedRange<CGFloat> {
        CGFloat(manifest.physics.hopApex[0]) * scale...CGFloat(manifest.physics.hopApex[1]) * scale
    }
}

/// A route onto a window top by clinging to its side and climbing (sticky species, SPEC §7.3).
public struct PerchRoute: Sendable, Equatable {
    public var window: Int
    public var side: Side
    /// Where the hop lands on the side.
    public var cling: CGPoint
    /// Where the Pixl sits on the window top after climbing.
    public var top: CGPoint
}

public struct WorldMap: Sendable {
    /// The top band of the focused window the Pixl may overlap (so it can perch on its title bar).
    public static let keepOutTopBand: CGFloat = 2

    public let input: WorldInput
    public private(set) var platforms: [Platform] = []
    public private(set) var sides: [WindowSide] = []
    /// The focused window's frame (SPEC §6.4).
    public let keepOut: CGRect?

    public init(_ input: WorldInput) {
        self.input = input
        keepOut = input.focusedWindowID.flatMap { id in input.windows.first { $0.id == id }?.frame }
        build()
    }

    private mutating func build() {
        for d in input.displays {
            // Ground: the screen's bottom edge, except where the Dock is; there it's the Dock's top.
            var ground = [d.frame.minX...d.frame.maxX]
            if let dock = d.dockFrame {
                ground = Self.subtract(dock.minX...dock.maxX, from: ground)
                platforms.append(Platform(kind: .dockTop(display: d.id), y: dock.minY, intervals: [dock.minX...dock.maxX]))
            }
            platforms.append(Platform(kind: .ground(display: d.id), y: d.frame.maxY, intervals: ground))
            if d.visibleFrame.minY > d.frame.minY {
                platforms.append(Platform(
                    kind: .menuBarUnderside(display: d.id), y: d.visibleFrame.minY,
                    intervals: [d.visibleFrame.minX...d.visibleFrame.maxX]))
            }
        }
        guard !input.groundOnly else { return }

        for (i, w) in input.windows.enumerated() {
            let above = input.windows[..<i].map(\.frame)
            let y = w.frame.minY
            // Only the parts of the top edge that are on a display's visible area and not under a window in front.
            var top = input.displays
                .filter { $0.visibleFrame.minY <= y && y < $0.visibleFrame.maxY }
                .compactMap { Self.intersect(w.frame.minX...w.frame.maxX, $0.visibleFrame.minX...$0.visibleFrame.maxX) }
            for f in above where f.minY <= y && y <= f.maxY {
                top = Self.subtract(f.minX...f.maxX, from: top)
            }
            if !top.isEmpty { platforms.append(Platform(kind: .windowTop(window: w.id), y: y, intervals: top)) }

            for (side, x) in [(Side.left, w.frame.minX), (.right, w.frame.maxX)] {
                var segs = [w.frame.minY...w.frame.maxY]
                for f in above where f.minX <= x && x <= f.maxX {
                    segs = Self.subtract(f.minY...f.maxY, from: segs)
                }
                if !segs.isEmpty { sides.append(WindowSide(window: w.id, side: side, x: x, intervals: segs)) }
            }
        }
    }

    // MARK: Queries

    /// The display containing `point`, or the nearest one.
    public func display(containing point: CGPoint) -> DisplayInfo? {
        input.displays.first { $0.frame.contains(point) }
            ?? input.displays.min { Self.distance($0.frame, point) < Self.distance($1.frame, point) }
    }

    /// The bottom of the menu bar on the display under `point`; the Pixl's body stays below it unless hanging.
    public func visibleTop(at point: CGPoint) -> CGFloat {
        display(containing: point)?.visibleFrame.minY ?? -.infinity
    }

    /// Keep-out check (SPEC §6.4): the hitbox may touch only the top 2 pt band of the focused window.
    public func isLegal(hitbox: CGRect) -> Bool {
        guard let k = keepOut else { return true }
        let body = CGRect(x: k.minX, y: k.minY + Self.keepOutTopBand, width: k.width, height: max(0, k.height - Self.keepOutTopBand))
        return !hitbox.intersects(body)
    }

    public func platform(_ kind: SurfaceKind) -> Platform? { platforms.first { $0.kind == kind } }

    /// Is this standing spot still there (window not gone, not covered)?
    public func supports(_ spot: Spot) -> Bool {
        guard let p = platform(spot.surface) else { return false }
        return abs(p.y - spot.point.y) < 0.5 && p.contains(x: spot.point.x)
    }

    /// The first standing surface crossed when moving from `a` to `b` downward (falls, throws).
    public func landing(from a: CGPoint, to b: CGPoint) -> Spot? {
        guard b.y > a.y else { return nil }
        var best: Spot?
        for p in platforms where !p.isHang && p.y > a.y && p.y <= b.y {
            let t = (p.y - a.y) / (b.y - a.y)
            let x = a.x + (b.x - a.x) * t
            if p.contains(x: x), best.map({ p.y < $0.point.y }) ?? true {
                best = Spot(surface: p.kind, point: CGPoint(x: x, y: p.y))
            }
        }
        return best
    }

    /// The highest standing surface at or below `point` (where a fall from here ends).
    public func firstPlatformBelow(_ point: CGPoint) -> Spot? {
        platforms
            .filter { !$0.isHang && $0.y >= point.y && $0.contains(x: point.x) }
            .min { $0.y < $1.y }
            .map { Spot(surface: $0.kind, point: CGPoint(x: point.x, y: $0.y)) }
    }

    /// Standing x-ranges reachable by one hop from `spot` (SPEC §7.3): within hop distance, rising at most
    /// `maxRise`, on the same display, and with the whole arc clear of the keep-out rect.
    public func hopTargets(from spot: Spot, geometry g: PixlGeometry) -> [(SurfaceKind, ClosedRange<CGFloat>)] {
        guard let disp = display(containing: spot.point) else { return [] }
        let reach = (spot.point.x - g.maxHopDistance)...(spot.point.x + g.maxHopDistance)
        var out: [(SurfaceKind, ClosedRange<CGFloat>)] = []
        for p in platforms where !p.isHang && spot.point.y - p.y <= g.maxRise {
            for iv in p.intervals {
                guard let r = Self.intersect(iv, reach), let dr = Self.intersect(r, disp.frame.minX...disp.frame.maxX) else { continue }
                // Representative target: the point nearest the start, nudged off the very edge.
                let x = min(max(spot.point.x, dr.lowerBound + 1), dr.upperBound - 1)
                guard dr.upperBound - dr.lowerBound >= 2 else { continue }
                let target = CGPoint(x: x, y: p.y)
                if arcIsClear(from: spot.point, to: target, geometry: g, bounds: disp.frame) { out.append((p.kind, dr)) }
            }
        }
        return out
    }

    /// Whether a hop from `a` to `b` stays on the display and out of the keep-out rect.
    public func arcIsClear(from a: CGPoint, to b: CGPoint, geometry g: PixlGeometry, bounds: CGRect) -> Bool {
        let apex = g.apexRange.lowerBound, gravity = g.manifest.physics.gravity * Double(g.scale)
        guard apex > 0, gravity > 0 else { return false }   // no hop is possible (HopPlan would trap)
        let hop = HopPlan(from: a, to: b, apexHeight: apex, gravity: gravity)
        let top = visibleTop(at: a)
        return hop.samples().allSatisfy { pt in
            let hb = g.hitbox(at: pt)
            return hb.minY >= top && isLegal(hitbox: hb)
        }
    }

    /// Window tops reachable by hopping onto a side and climbing it (sticky species only).
    public func perchRoutes(from spot: Spot, geometry g: PixlGeometry) -> [PerchRoute] {
        guard g.manifest.sticky else { return [] }
        var routes: [PerchRoute] = []
        for s in sides {
            guard abs(s.x - spot.point.x) <= g.maxHopDistance,
                  let w = input.windows.first(where: { $0.id == s.window }),
                  let top = platform(.windowTop(window: s.window)),
                  // The visible stretch must run all the way up to the top corner…
                  let seg = s.intervals.first(where: { abs($0.lowerBound - w.frame.minY) < 0.5 }),
                  // …and come down to within one hop's rise of the Pixl.
                  spot.point.y - seg.upperBound <= g.maxRise
            else { continue }
            let cornerX = s.side == .left ? w.frame.minX + 1 : w.frame.maxX - 1
            guard top.contains(x: cornerX) else { continue }
            let clingY = max(seg.lowerBound, min(seg.upperBound, spot.point.y - g.maxRise / 2))
            let cling = CGPoint(x: s.x, y: clingY)
            let topPoint = CGPoint(x: cornerX, y: w.frame.minY)
            if isLegal(hitbox: g.hitbox(at: topPoint)) {
                routes.append(PerchRoute(window: s.window, side: s.side, cling: cling, top: topPoint))
            }
        }
        return routes
    }

    /// The nearest standing spot where the hitbox is legal (keep-out escape, SPEC §6.4).
    /// Nil means there is none: the platform layer fades the Pixl to 25% and makes it click-through.
    public func nearestLegalSpot(to point: CGPoint, geometry g: PixlGeometry) -> Spot? {
        var best: (Spot, CGFloat)?
        let halfWidth = g.hitbox(at: .zero).width / 2
        for p in platforms where !p.isHang {
            for iv in p.intervals {
                // Candidates: the point straight above/below, plus each end of the interval and
                // just past each side of the keep-out rect.
                var xs = [point.x, iv.lowerBound + halfWidth, iv.upperBound - halfWidth]
                if let k = keepOut { xs += [k.minX - halfWidth - 1, k.maxX + halfWidth + 1] }
                for x in xs where iv.contains(x) {
                    let c = CGPoint(x: x, y: p.y)
                    let hb = g.hitbox(at: c)
                    guard isLegal(hitbox: hb), hb.minY >= visibleTop(at: c) else { continue }
                    let d = hypot(c.x - point.x, c.y - point.y)
                    if best.map({ d < $0.1 }) ?? true { best = (Spot(surface: p.kind, point: c), d) }
                }
            }
        }
        return best?.0
    }

    // MARK: Interval helpers

    static func intersect(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> ClosedRange<CGFloat>? {
        let lo = max(a.lowerBound, b.lowerBound), hi = min(a.upperBound, b.upperBound)
        return lo <= hi ? lo...hi : nil
    }

    /// `ranges` minus `cut`. Pieces narrower than 1 pt are dropped.
    static func subtract(_ cut: ClosedRange<CGFloat>, from ranges: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var out: [ClosedRange<CGFloat>] = []
        for r in ranges {
            guard r.overlaps(cut) else { out.append(r); continue }
            if r.lowerBound < cut.lowerBound - 1 { out.append(r.lowerBound...cut.lowerBound) }
            if r.upperBound > cut.upperBound + 1 { out.append(cut.upperBound...r.upperBound) }
        }
        return out
    }

    static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
