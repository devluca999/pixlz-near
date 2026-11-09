import AppKit
import PixlMemoryKit

/// Slugg's slime trail on the desktop (C11): laid behind its tail while it crawls (floor, walls,
/// upside down), one body length at most, fading by 2 s after it stops. Click-through, just below
/// Slugg. Nothing for other Pixls, and nothing while sealed.
@MainActor
final class TrailController {
    unowned let app: AppController
    var panel: NSPanel?
    var view: SlimeTrailView?
    /// Where it touched, newest last (art pixels on the global grid), with the way off its surface.
    var path: [(p: CGPoint, n: (Int, Int))] = []
    var stoppedAt: TimeInterval?
    var fadeTimer: Timer?
    var lastAge = -1
    /// How many body lengths show (1; 4 while Slugg chases you in Inevitable).
    var lengthBodies: CGFloat = 1

    init(app: AppController) { self.app = app }

    /// Each frame of motion: lay trail while crawling; start fading when it stops.
    func step(force: Bool = false) {
        let d = app.frogg.drawn
        let crawling = force || (app.moving && app.shellPose == nil && d.anchored
            && ["crawl_", "climb_", "under_"].contains(where: { d.name.hasPrefix($0) }))
        guard crawling, let foot = app.foot else { if !path.isEmpty, stoppedAt == nil { stop() }; return }
        let n: (Int, Int) = switch app.frogg.surface {
        case .floor, .hanging: (0, -1)
        case .ceiling: (0, 1)
        case .rightWall: (-1, 0)
        case .leftWall: (1, 0)
        }
        // the row just off the surface, on the global art grid
        let p = CGPoint(x: foot.x / app.scale + CGFloat(n.0) * 0.5, y: foot.y / app.scale + CGFloat(n.1) * 0.5)
        if let last = path.last?.p {
            let gap = hypot(p.x - last.x, p.y - last.y)
            if gap < 0.5 { return }
            if gap > 6 { path.removeAll() }   // it hopped or was carried: a new trail
        }
        stoppedAt = nil
        fadeTimer?.invalidate(); fadeTimer = nil
        path.append((p, n))
        trim()
        render(age: 0)
    }

    /// The body's length and how far behind the contact its tail is (art pixels).
    var body: CGFloat { 58 }
    var tailBehind: CGFloat { body * 0.45 }

    /// Keeps only what can still show: the tail's distance plus a body length.
    func trim() {
        var dist: CGFloat = 0, keep = path.count
        for i in stride(from: path.count - 1, to: 0, by: -1) {
            dist += hypot(path[i].p.x - path[i - 1].p.x, path[i].p.y - path[i - 1].p.y)
            if dist > tailBehind + body * lengthBodies + 2 { keep = path.count - i + 1; break }
        }
        if keep < path.count { path.removeFirst(path.count - keep) }
    }

    /// The visible stretch, tail first: from the tail back one body length.
    func visible() -> [CGPoint] {
        var out: [CGPoint] = [], dist: CGFloat = 0
        for i in stride(from: path.count - 1, through: 0, by: -1) {
            if i < path.count - 1 { dist += hypot(path[i + 1].p.x - path[i].p.x, path[i + 1].p.y - path[i].p.y) }
            if dist >= tailBehind, dist <= tailBehind + body * lengthBodies { out.append(path[i].p) }
        }
        return out
    }

    func render(age: Int) {
        lastAge = age
        let pts = visible()
        let px = SlimeTrail.pixels(path: pts, normal: path.last?.n ?? (0, -1), age: age)
        guard !px.isEmpty else { panel?.orderOut(nil); return }
        let minX = px.map(\.x).min()!, maxX = px.map(\.x).max()!, minY = px.map(\.y).min()!, maxY = px.map(\.y).max()!
        let s = app.scale
        let frame = NSRect(x: CGFloat(minX) * s, y: app.primaryHeight - CGFloat(maxY + 1) * s,
                           width: CGFloat(maxX - minX + 1) * s, height: CGFloat(maxY - minY + 1) * s)
        let p = panel ?? makePanel()
        if p.frame != frame { p.setFrame(frame, display: false) }
        view?.frame = NSRect(origin: .zero, size: frame.size)
        view?.scale = s
        view?.origin = CGPoint(x: minX, y: minY)
        view?.palette = PixlSkins.current.option?.id == "racer" ? SlimeTrail.racer : SlimeTrail.green
        view?.pixels = px
        if !p.isVisible { p.order(.below, relativeTo: app.froggPanel.windowNumber) }
    }

    /// Stopped: the whole trail steps down every 0.5 s and is gone by 2 s.
    func stop() {
        stoppedAt = app.now
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let t0 = self.stoppedAt else { return }
                let age = Int((self.app.now - t0) / 0.5)
                if age >= 4 { self.clear(); return }
                if age != self.lastAge { self.render(age: age) }
            }
        }
    }

    func clear() {
        fadeTimer?.invalidate(); fadeTimer = nil
        path.removeAll(); stoppedAt = nil
        panel?.orderOut(nil)
    }

    func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = app.froggPanel.level
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = SlimeTrailView(frame: .zero)
        p.contentView = v
        panel = p; view = v
        return p
    }
}
