import AppKit
import PixlMemoryKit
import PixlzCore

/// Everything a game draws that isn't the pet: the fly on the cursor, Frogg's tongue and throat,
/// stars, the crown, the edge vignette, score pops, the HUD chip, and (PIXL_DEBUG=1) hitboxes and
/// timers. One click-through panel over the pet's screen; only the parts that change are redrawn.
@MainActor
final class GameOverlay {
    enum Debug { case circle(CGPoint, Double, NSColor), point(CGPoint, NSColor), text(String) }

    let panel: OverlayPanel
    let view: GameOverlayView
    let screen: CGRect          // top-left global
    unowned let app: AppController

    var fly: CGPoint?
    var tongue: (from: CGPoint, to: CGPoint, width: Int, flash: Bool)?
    var throat: (center: CGPoint, amount: Double)?
    var danger = 0.0
    var hud: (time: String, score: String)?
    var debug: [Debug] = []
    var lastAim: CGPoint?
    var stars: [(at: CGPoint, born: TimeInterval)] = []
    var pops: [(text: String, at: CGPoint, born: TimeInterval)] = []
    var whiffs: [(at: CGPoint, born: TimeInterval)] = []
    var crownBox: (box: CGRect, born: TimeInterval)?
    var flyAwayFrom: (at: CGPoint, born: TimeInterval)?
    var streakPopAt: TimeInterval = -10

    init(screenTopLeft s: CGRect, app: AppController) {
        self.screen = s
        self.app = app
        let frame = Perch.toAppKit(s, primaryHeight: app.primaryHeight)
        panel = OverlayPanel(size: frame.size)
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true      // hands off: every click goes where it would anyway
        panel.setFrame(frame, display: false)
        view = GameOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        panel.contentView = view
        view.overlay = self
        panel.orderFrontRegardless()
    }

    var px: CGFloat { app.scale }
    /// Global top-left → this view (flipped, top-left).
    func v(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - screen.minX, y: p.y - screen.minY) }

    func star(at p: CGPoint, now: TimeInterval) { stars.append((p, now)) }
    func pop(_ text: String, at p: CGPoint, now: TimeInterval) { pops.append((text, p, now)) }
    func whiff(at p: CGPoint, now: TimeInterval) { whiffs.append((p, now)) }
    func crown(over box: CGRect, now: TimeInterval) { crownBox = (box, now) }
    func popStreak(now: TimeInterval) { streakPopAt = now }
    func flyAway(now: TimeInterval) { if let f = fly { flyAwayFrom = (f, now); fly = nil } }

    // MARK: redraw only what moved

    var lastDirty: [CGRect] = []
    var now: TimeInterval = 0

    func redraw(now: TimeInterval) {
        self.now = now
        stars.removeAll { now - $0.born > 0.25 }
        pops.removeAll { now - $0.born > 0.7 }
        whiffs.removeAll { now - $0.born > 0.3 }
        if let f = flyAwayFrom, now - f.born > 1.2 { flyAwayFrom = nil }
        let oldHUD = hudRect
        placeHUD()
        if hudRect != oldHUD { view.setNeedsDisplay(oldHUD.insetBy(dx: -12, dy: -12)) }
        let dirty = rects()
        if !debug.isEmpty || danger > 0 || lastDirty.count > 40 {
            view.needsDisplay = true
        } else {
            for r in lastDirty + dirty { view.setNeedsDisplay(r.insetBy(dx: -2 * px, dy: -2 * px)) }
        }
        lastDirty = dirty
    }

    /// The boxes (view coordinates) that hold something this frame.
    func rects() -> [CGRect] {
        var out: [CGRect] = []
        let k = px
        if let f = fly { out.append(CGRect(x: v(f).x - 4 * k, y: v(f).y - 7 * k, width: 12 * k, height: 10 * k)) }
        if let f = flyAwayFrom { let p = flyAwayPoint(f); out.append(CGRect(x: v(p).x - 6 * k, y: v(p).y - 8 * k, width: 14 * k, height: 12 * k)) }
        if let t = tongue { out.append(CGRect(x: min(v(t.from).x, v(t.to).x), y: min(v(t.from).y, v(t.to).y), width: abs(t.to.x - t.from.x), height: abs(t.to.y - t.from.y)).insetBy(dx: -4 * k, dy: -4 * k)) }
        if let t = throat { out.append(CGRect(x: v(t.center).x - 9 * k, y: v(t.center).y - 2 * k, width: 18 * k, height: 14 * k)) }
        for s in stars { out.append(CGRect(x: v(s.at).x - 4 * k, y: v(s.at).y - 4 * k, width: 8 * k, height: 8 * k)) }
        for w in whiffs { out.append(CGRect(x: v(w.at).x - 7 * k, y: v(w.at).y - 5 * k, width: 14 * k, height: 10 * k)) }
        for p in pops { out.append(CGRect(x: v(p.at).x - 20, y: v(p.at).y - 40, width: 80, height: 40)) }
        if let c = crownBox { out.append(CGRect(x: v(c.box.origin).x, y: v(c.box.origin).y - 14 * k, width: c.box.width, height: 16 * k)) }
        if hud != nil { out.append(hudRect.insetBy(dx: -12, dy: -12)) }
        return out
    }

    /// Which corner the HUD sits in: bottom right unless the pet or the cursor is there.
    var hudCorner = 0
    /// The pet's box (top-left global), so the HUD never covers it.
    var petBox: CGRect = .zero

    func hudRect(_ corner: Int) -> CGRect {
        let w: CGFloat = 210, h: CGFloat = 28, m: CGFloat = 16
        let right = corner == 0 || corner == 2, bottom = corner < 2
        return CGRect(x: right ? view.bounds.maxX - w - m : m, y: bottom ? view.bounds.maxY - h - m : m + 24, width: w, height: h)
    }
    var hudRect: CGRect { hudRect(hudCorner) }

    /// Moves the HUD when the pet reaches its corner.
    func placeHUD() {
        let pet = CGRect(origin: v(petBox.origin), size: petBox.size).insetBy(dx: -24, dy: -24)
        // only the pet moves it (it fades near the cursor instead, so it doesn't jump about as you dodge)
        func free(_ c: Int) -> Bool { !hudRect(c).intersects(pet) }
        if free(hudCorner) { return }
        if let c = [0, 1, 2, 3].first(where: free) { hudCorner = c }
    }

    func flyAwayPoint(_ f: (at: CGPoint, born: TimeInterval)) -> CGPoint {
        let t = now - f.born
        return CGPoint(x: f.at.x + t * 180 + sin(t * 30) * 4, y: f.at.y - t * 140)
    }

    func close() { panel.orderOut(nil) }
}

/// Draws the overlay's pieces in whole art pixels.
@MainActor
final class GameOverlayView: NSView {
    weak var overlay: GameOverlay?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let flyFrames = [["..ww.ww..", ".wWWkWWw.", "..wkbkw..", ".kbbbbbk.", ".kbhbbbk.", "..kbbbk..", "...kkk..."],
                            [".ww...ww.", "wWWwkwWWw", ".wwkbkww.", ".kbbbbbk.", ".kbhbbbk.", "..kbbbk..", "...kkk..."]]
    static let flyColors: [Character: NSColor] = ["k": .hex("#06070A"), "b": .hex("#2A3038"), "h": .hex("#8A96A4"), "w": .hex("#3A4048"), "W": .hex("#EAF4FA")]
    static let crown = ["k...k...k", "kyk.kyk.k", "kyykyykyk", "kyyyryyyk", "kyyyyyyyk", "kkkkkkkkk"]
    static let crownColors: [Character: NSColor] = ["k": .hex("#2A1A04"), "y": .hex("#F0C040"), "r": .hex("#D83A3A")]

    override func draw(_ dirtyRect: NSRect) {
        guard let o = overlay else { return }
        let k = o.px
        func block(_ p: CGPoint, _ c: NSColor, _ size: CGFloat = 1) {
            c.setFill()
            NSRect(x: (p.x / k).rounded(.down) * k, y: (p.y / k).rounded(.down) * k, width: k * size, height: k * size).fill()
        }
        func grid(_ rows: [String], _ colors: [Character: NSColor], at origin: CGPoint) {
            for (j, row) in rows.enumerated() {
                for (i, ch) in row.enumerated() { if let c = colors[ch] { block(CGPoint(x: origin.x + CGFloat(i) * k, y: origin.y + CGFloat(j) * k), c) } }
            }
        }

        // the edge vignette: a dithered band in Slugg's mustard, pulsing at 1 Hz
        if o.danger > 0 {
            let pulse = Reduce.motion ? 1.0 : 0.75 + 0.25 * sin(o.now * 2 * .pi)
            let amt = o.danger * 0.55 * pulse
            let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
            let cols = Int(bounds.width / k), rows = Int(bounds.height / k)
            let c = NSColor.hex("#C9A43A")
            for y in 0..<rows {
                let edgeY = min(y, rows - 1 - y)
                if edgeY >= 4 {
                    // only the left and right bands on this row
                    for x in Array(0..<min(4, cols)) + Array(max(0, cols - 4)..<cols) {
                        let d = Double(min(x, cols - 1 - x))
                        if (bayer[y & 3][x & 3] + 0.5) / 16 < amt * (1 - d / 4) { block(CGPoint(x: CGFloat(x) * k, y: CGFloat(y) * k), c) }
                    }
                    continue
                }
                for x in 0..<cols {
                    let d = Double(min(x, y, cols - 1 - x, rows - 1 - y))
                    if (bayer[y & 3][x & 3] + 0.5) / 16 < amt * (1 - d / 4) { block(CGPoint(x: CGFloat(x) * k, y: CGFloat(y) * k), c) }
                }
            }
        }

        // Frogg's throat puff (cream, outlined) under the mouth
        if let t = o.throat, t.amount > 0.02 {
            let m = o.v(t.center), a = t.amount
            let rx = 4 + 3 * a, ry = 2 + 2.4 * a
            let cy = m.y + (ry + 4) * k       // hangs under the chin
            var y = -ry - 1
            while y <= ry + 1 {
                var i = -rx - 1
                while i <= rx + 1 {
                    let d = hypot(i / (rx + 0.5), y / (ry + 0.5))
                    if d <= 1.08 {
                        let c: NSColor = d > 0.88 ? .hex("#0E1A0C") : y < -ry * 0.3 ? .hex("#FFF8DC") : y < ry * 0.4 ? .hex("#EAE2BC") : .hex("#C4B888")
                        block(CGPoint(x: m.x + i * k, y: cy + y * k), c)
                    }
                    i += 1
                }
                y += 1
            }
        }

        // the tongue: a pink line in whole pixels, a round tip; white flash pixels at full reach
        if let t = o.tongue {
            let a = o.v(t.from), b = o.v(t.to)
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / k))
            for i in 0...n {
                let p = CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(i) / CGFloat(n))
                for w in 0..<t.width { block(CGPoint(x: p.x, y: p.y + CGFloat(w) * k), w == 0 ? .hex("#E86A86") : .hex("#B03A52")) }
            }
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1), (-1, 0), (0, -1), (2, 1), (1, 2)] {
                block(CGPoint(x: b.x + CGFloat(dx - 1) * k, y: b.y + CGFloat(dy - 1) * k), .hex("#E86A86"))
            }
            block(CGPoint(x: b.x - k, y: b.y - k), .hex("#FFC8D4"))
            if t.flash { for (dx, dy) in [(0, -3), (0, 3), (-3, 0), (3, 0), (-2, -2), (2, 2), (2, -2), (-2, 2)] { block(CGPoint(x: b.x + CGFloat(dx) * k, y: b.y + CGFloat(dy) * k), .white) } }
        }

        // the fly, wings flapping, up and right of the cursor tip
        if let f = o.fly { grid(Self.flyFrames[Int(o.now * 24) % 2], Self.flyColors, at: CGPoint(x: o.v(f).x - 2 * k, y: o.v(f).y - 5 * k)) }
        if let f = o.flyAwayFrom { let p = o.v(o.flyAwayPoint(f)); grid(Self.flyFrames[Int(o.now * 30) % 2], Self.flyColors, at: CGPoint(x: p.x - 2 * k, y: p.y - 5 * k)) }

        // "whiff": a puff at the empty spot, 3 frames
        for w in o.whiffs {
            let p = o.v(w.at), s = CGFloat(1 + Int((o.now - w.born) / 0.1))
            for (dx, dy) in [(-4, -3), (-3, -3), (3, -3), (4, -3), (-5, 0), (-4, 0), (4, 0), (5, 0), (-4, 3), (-3, 3), (3, 3), (4, 3)] {
                block(CGPoint(x: p.x + CGFloat(dx) * k * (0.7 + 0.2 * s), y: p.y + CGFloat(dy) * k * (0.7 + 0.2 * s)), NSColor.hex("#E8F0F4").withAlphaComponent(1 - (s - 1) * 0.3))
            }
        }

        // little stars (two frames)
        for s in o.stars {
            let p = o.v(s.at), big = o.now - s.born < 0.12
            for (dx, dy) in [(0, -2), (0, -1), (-2, 0), (-1, 0), (1, 0), (2, 0), (0, 1), (0, 2)] where big || (abs(dx) < 2 && abs(dy) < 2) {
                block(CGPoint(x: p.x + CGFloat(dx) * k, y: p.y + CGFloat(dy) * k), .hex("#FFE070"))
            }
            block(p, .white)
        }

        // the gotcha crown, with a one-pixel bounce
        if let c = o.crownBox {
            let b = CGRect(origin: o.v(c.box.origin), size: c.box.size)
            let bounce: CGFloat = o.now - c.born < 0.12 ? -k : 0
            grid(Self.crown, Self.crownColors, at: CGPoint(x: b.midX - 4 * k, y: b.minY - 8 * k + bounce))
        }

        // score pops ("bonk!", "+1"), rising and fading
        for p in o.pops {
            let t = o.now - p.born
            let at = o.v(p.at)
            let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(12), .foregroundColor: NSColor.white.withAlphaComponent(1 - t / 0.7),
                                                    .strokeColor: NSColor.black, .strokeWidth: -3]
            (p.text as NSString).draw(at: CGPoint(x: at.x + 8, y: at.y - 22 - t * 30), withAttributes: a)
        }

        // the HUD chip: time · score · Esc, bottom right; fades near the cursor
        if let h = o.hud {
            let r = o.hudRect
            let m = o.v(o.app.mouseTopLeft)
            let near = hypot(max(r.minX - m.x, 0, m.x - r.maxX), max(r.minY - m.y, 0, m.y - r.maxY)) < 80
            let alpha: CGFloat = near ? 0.4 : 1
            let pop = o.now - o.streakPopAt < 0.14 ? 1 + 0.2 * (1 - (o.now - o.streakPopAt) / 0.14) : 1
            NSColor(white: 0.07, alpha: 0.86 * alpha).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            NSColor(white: 1, alpha: 0.25 * alpha).setStroke()
            let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()
            let font = Theme.mono(11)
            let main: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
            let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.5 * alpha)]
            let s = NSMutableAttributedString(string: h.time, attributes: main)
            s.append(NSAttributedString(string: "  ·  ", attributes: dim))
            let score = NSAttributedString(string: h.score, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11 * pop, weight: .bold),
                                                                         .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
            s.append(score)
            s.append(NSAttributedString(string: "  ·  Esc", attributes: dim))
            let size = s.size()
            s.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
        }

        // PIXL_DEBUG=1: hitboxes and timers
        for d in o.debug {
            switch d {
            case .circle(let c, let radius, let color):
                color.withAlphaComponent(0.9).setStroke()
                let p = o.v(c)
                let path = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
                path.lineWidth = 1.5
                path.stroke()
            case .point(let c, let color):
                color.setFill()
                let p = o.v(c)
                NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            case .text(let s):
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
                                                        .backgroundColor: NSColor(white: 0, alpha: 0.7)]
                (s as NSString).draw(at: CGPoint(x: 16, y: 16), withAttributes: a)
            }
        }
    }
}

extension NSColor {
    static func hex(_ s: String) -> NSColor {
        let v = Int(s.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
