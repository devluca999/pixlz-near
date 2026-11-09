import CoreGraphics
import Foundation

/// Slugg never hops: every move is a crawl. Between two spots (the floor, or the top of a window)
/// he crawls along what he's on, down a window's side and up another's, wrapping round corners.
/// A window that doesn't reach the floor: he crawls down its side and lets go to the floor (a
/// short drop, the only time his feet leave a surface); one he can't climb (it doesn't reach the
/// floor), he stays on the floor below its top instead. Top-left coordinates, y down.
public enum SluggPath {
    public enum Step: Equatable, Sendable {
        case crawl(CrawlLeg)
        case drop(from: CGPoint, to: CGPoint)
    }

    /// Steps from `a` to `b` (or to the floor below `b` when its window can't be climbed), and
    /// where he ends up.
    public static func plan(from a0: CGPoint, to b: CGPoint, screen: CGRect, windows: [CGRect], sprite: CGSize,
                            surface: Surface = .floor) -> (steps: [Step], end: CGPoint) {
        let floorY = screen.maxY
        let half = sprite.width / 2, h = sprite.height
        // on a wall or the ceiling: crawl down to the floor first (along the top to the nearer side)
        var lead: [Step] = []
        var a = a0
        switch surface {
        case .rightWall, .leftWall:
            let right = surface == .rightWall
            lead.append(.crawl(CrawlLeg(from: a, to: CGPoint(x: a.x, y: floorY - h / 2), surface: surface)))
            a = CGPoint(x: right ? a.x - h / 2 : a.x + h / 2, y: floorY)
        case .ceiling, .hanging:
            let right = a.x > screen.midX
            let wallX = right ? screen.maxX : screen.minX
            lead.append(.crawl(CrawlLeg(from: a, to: CGPoint(x: wallX, y: screen.minY), surface: .ceiling)))
            lead.append(.crawl(CrawlLeg(from: CGPoint(x: wallX, y: screen.minY + h / 2), to: CGPoint(x: wallX, y: floorY - h / 2), surface: right ? .rightWall : .leftWall)))
            a = CGPoint(x: right ? wallX - h / 2 : wallX + h / 2, y: floorY)
        case .floor: break
        }
        if !lead.isEmpty {
            let rest = plan(from: a, to: b, screen: screen, windows: windows, sprite: sprite)
            // the floor leg from the wall's foot joins the rest
            return (lead + (rest.steps.isEmpty ? [.crawl(CrawlLeg(from: a, to: a, surface: .floor))] : rest.steps), rest.end)
        }
        func top(of p: CGPoint) -> CGRect? {
            if abs(p.y - floorY) < 6 { return nil }
            return windows.first { abs($0.minY - p.y) < 8 && $0.minX - 4 <= p.x && p.x <= $0.maxX + 4 }
        }
        func standsOnFloor(_ r: CGRect) -> Bool { r.maxY >= floorY - 12 }
        var steps: [Step] = []
        var cur = a
        let wa = top(of: a), wb = top(of: b)

        // the same window top, or both on the floor: straight along
        if let wa, let wb, wa == wb { return ([.crawl(CrawlLeg(from: a, to: b, surface: .floor))], b) }
        if wa == nil, wb == nil, abs(a.y - floorY) < 6 {
            let end = CGPoint(x: b.x, y: floorY)
            return (abs(end.x - a.x) < 1 ? [] : [.crawl(CrawlLeg(from: a, to: end, surface: .floor))], end)
        }

        // 1. off the window he's on: to its end nearer the goal, down its side
        if let wa {
            let left = b.x < cur.x || (wb == nil && b.x - wa.minX < wa.maxX - b.x && b.x <= wa.maxX && b.x >= wa.minX)
            let side = left ? wa.minX : wa.maxX
            steps.append(.crawl(CrawlLeg(from: cur, to: CGPoint(x: side, y: wa.minY), surface: .floor)))
            let wall: Surface = left ? .rightWall : .leftWall
            if standsOnFloor(wa) {
                steps.append(.crawl(CrawlLeg(from: CGPoint(x: side, y: wa.minY), to: CGPoint(x: side, y: floorY), surface: wall)))
                cur = CGPoint(x: side + (left ? -half : half), y: floorY)
                steps.append(.crawl(CrawlLeg(from: CGPoint(x: side, y: floorY), to: cur, surface: .floor)))
            } else {
                // down to the window's bottom corner, then a short drop to the floor
                steps.append(.crawl(CrawlLeg(from: CGPoint(x: side, y: wa.minY), to: CGPoint(x: side, y: wa.maxY), surface: wall)))
                let landing = CGPoint(x: side + (left ? -half : half), y: floorY)
                steps.append(.drop(from: CGPoint(x: landing.x, y: wa.maxY), to: landing))
                cur = landing
            }
        } else if abs(cur.y - floorY) >= 6 {
            // somewhere in the air (put down, a display change): down to the floor first
            let landing = CGPoint(x: cur.x, y: floorY)
            steps.append(.drop(from: cur, to: landing))
            cur = landing
        }

        // 2. onto the goal's window: along the floor to its nearer side, up it, over the top
        if let wb, standsOnFloor(wb) {
            let left = cur.x < wb.midX
            let side = left ? wb.minX : wb.maxX
            steps.append(.crawl(CrawlLeg(from: cur, to: CGPoint(x: side, y: floorY), surface: .floor)))
            steps.append(.crawl(CrawlLeg(from: CGPoint(x: side, y: floorY), to: CGPoint(x: side, y: wb.minY), surface: left ? .rightWall : .leftWall)))
            steps.append(.crawl(CrawlLeg(from: CGPoint(x: side, y: wb.minY), to: b, surface: .floor)))
            return (steps, b)
        }
        // the floor (or below a window he can't climb)
        let end = CGPoint(x: b.x, y: floorY)
        if abs(end.x - cur.x) >= 1 { steps.append(.crawl(CrawlLeg(from: cur, to: end, surface: .floor))) }
        return (steps, end)
    }

    /// Out of the way of your typing: the path of least resistance, along the floor to the nearer
    /// side of the screen and up it, to rest on the wall above the bottom of the screen.
    public static func escape(from foot: CGPoint, wall: (right: Bool, x: CGFloat), screen: CGRect, sprite: CGSize, height: CGFloat) -> [CrawlLeg] {
        let floorY = screen.maxY, h = sprite.height
        let corner = CGPoint(x: wall.right ? wall.x - h / 2 : wall.x + h / 2, y: floorY)
        let restY = max(screen.minY + h, floorY - height)
        return [CrawlLeg(from: CGPoint(x: foot.x, y: floorY), to: corner, surface: .floor),
                CrawlLeg(from: CGPoint(x: wall.x, y: floorY - h / 2), to: CGPoint(x: wall.x, y: restY), surface: wall.right ? .rightWall : .leftWall)]
    }

    /// The steps as one timeline: crawl legs (wrapping at corners) via the roam planner, drops in
    /// between. No hops anywhere.
    public static func choreography(_ steps: [Step], from foot: CGPoint, gait: Gait?, wrap: ((CrawlLeg, CrawlLeg) -> CornerWrap?)?) -> Choreography {
        var segs: [Choreography.Segment] = []
        var group: [CrawlLeg] = []
        var at = foot
        // never a hop: anything that would step between surfaces crawls straight there instead
        let crawlTo: (CGPoint, CGPoint) -> Choreography = { a, b in
            Choreography([.travel(from: a, to: b, frames: gait?.frames ?? ["crawl_0"], fps: gait?.fps ?? 7, surface: .floor,
                                  mirrored: b.x < a.x, bob: 0, alpha: 1, duration: max(0.2, Double(hypot(b.x - a.x, b.y - a.y) / (gait?.speed ?? 36))))])
        }
        func flush() {
            guard let first = group.first else { return }
            let c = RoamPlanner.choreography(.crawl(legs: group, dangle: nil), from: first.from, style: .slider, hanging: nil, gait: gait,
                                             wrap: wrap, hop: crawlTo)
            segs += c.segments
            at = c.pose(at: c.duration).pose.foot
            group = []
        }
        for s in steps {
            switch s {
            case .crawl(let leg): group.append(leg)
            case .drop(let a, let b):
                flush()
                let t = max(0.25, Double((max(b.y - a.y, 1) / 1800).squareRoot() * 1.4))
                segs.append(.drop(from: a, to: b, frame: "crawl_0", mirrored: false, duration: t))
                segs.append(.land(at: b, frame: "crawl_0", mirrored: false, duration: 0.25, dust: true))
                at = b
            }
        }
        flush()
        _ = at
        return Choreography(segs)
    }
}
