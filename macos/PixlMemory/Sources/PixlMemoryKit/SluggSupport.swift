import CoreGraphics
import Foundation

/// Slugg is never on nothing (C11): what he crawls or rests on has to still be there. His paths
/// are planned against the windows of that moment; a window that moves, shrinks or closes while
/// he's on it would leave him crawling (or sitting) in midair. Top-left coordinates, y down.
public enum SluggSupport {
    /// Is there an edge under Slugg at `foot` on `surface`: a screen's edge (`screens`: its full
    /// and visible frames both count) or a window's (`windows`: on-screen, any size)?
    /// Walls: `.rightWall` has the wall on his right (a window's left side, the screen's right edge).
    public static func supported(foot p: CGPoint, surface: Surface, screens: [CGRect], windows: [CGRect],
                                 tolerance t: CGFloat = 12) -> Bool {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= t }
        func within(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> Bool { v >= lo - t && v <= hi + t }
        switch surface {
        case .hanging:
            return true   // on its thread
        case .floor:
            return screens.contains { near(p.y, $0.maxY) && within(p.x, $0.minX, $0.maxX) }
                || windows.contains { near(p.y, $0.minY) && within(p.x, $0.minX, $0.maxX) }
        case .rightWall:
            return screens.contains { near(p.x, $0.maxX) && within(p.y, $0.minY, $0.maxY) }
                || windows.contains { near(p.x, $0.minX) && within(p.y, $0.minY, $0.maxY) }
        case .leftWall:
            return screens.contains { near(p.x, $0.minX) && within(p.y, $0.minY, $0.maxY) }
                || windows.contains { near(p.x, $0.maxX) && within(p.y, $0.minY, $0.maxY) }
        case .ceiling:
            return screens.contains { near(p.y, $0.minY) && within(p.x, $0.minX, $0.maxX) }
                || windows.contains { near(p.y, $0.maxY) && within(p.x, $0.minX, $0.maxX) }
        }
    }
}

extension Choreography {
    /// The surface he's crawling along at `t`, or nil while it's anything else (a corner turn, a
    /// drop, a landing, a hold) or the timeline is over: only a crawl is checked for support.
    public func crawlSurface(at t: TimeInterval) -> Surface? {
        guard let (i, _) = segment(at: t), case .travel(_, _, _, _, let surface, _, _, _, _) = segments[i] else { return nil }
        return surface
    }
}
