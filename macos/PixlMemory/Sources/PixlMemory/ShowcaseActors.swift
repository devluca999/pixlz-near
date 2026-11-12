import AppKit
import PixlMemoryKit
import PixlzCore

/// Another Pixl on screen at the same time as yours (Showcase's friends and lineups): its own
/// real frames and skin, drawn crisp at any scale, moved by small eased tweens. The app shows
/// one Pixl at a time; these are the others, for the scenes where they meet.
@MainActor
final class ShowcaseActor {
    let skinID: String
    let art: FroggArt
    let panel: OverlayPanel
    let view: ActorView
    /// Feet (bottom middle), top-left global points.
    private(set) var foot: CGPoint
    var scale: CGFloat { didSet { layout() } }
    var frame: String { didSet { view.needsDisplay = true } }
    var mirrored = false { didSet { view.needsDisplay = true } }
    var squash = CGSize(width: 1, height: 1) { didSet { view.needsDisplay = true } }
    unowned let app: AppController
    /// A thread from above (Silky): its top end, top-left global.
    var thread: CGPoint? { didSet { view.needsDisplay = true } }

    init(_ skinID: String, at foot: CGPoint, scale: CGFloat, frame: String = "idle_0", app: AppController) {
        self.skinID = skinID
        self.art = PixlSkins.skin(skinID)?.activeArt ?? FroggArt.shared
        self.foot = foot
        self.scale = scale
        self.frame = frame
        self.app = app
        panel = OverlayPanel(size: NSSize(width: 10, height: 10))
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        view = ActorView(frame: .zero)
        panel.contentView = view
        view.actor = self
        layout()
        panel.orderFrontRegardless()
    }

    /// The panel: the canvas with headroom for squash, feet at the bottom middle.
    func layout() {
        let c = art.canvas
        let w = (c.width * 1.4 * scale).rounded(), h = (c.height * 1.4 * scale).rounded()
        var r = NSRect(x: foot.x - w / 2, y: app.primaryHeight - foot.y, width: w, height: h)
        if let t = thread { let top = app.primaryHeight - t.y; r.size.height = max(h, top - r.minY) }
        panel.setFrame(r, display: true)
        view.frame = NSRect(origin: .zero, size: r.size)
        view.needsDisplay = true
    }

    func place(_ p: CGPoint) { foot = p; layout() }

    /// An eased move along a straight line, cycling `frames` at `fps` (a walk, a trot).
    func walk(to p: CGPoint, duration: TimeInterval, frames: [String], fps: Double = 9) async {
        let a = foot
        mirrored = p.x < a.x
        let start = app.now
        while true {
            let t = min(1, (app.now - start) / duration)
            let e = CGFloat(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
            place(CGPoint(x: a.x + (p.x - a.x) * e, y: a.y + (p.y - a.y) * e))
            frame = frames[Int((app.now - start) * fps) % max(frames.count, 1)]
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        frame = "idle_0"
    }

    /// Dropped from above: falls under gravity, lands with a squash and a little spring.
    func drop(to p: CGPoint, from height: CGFloat, duration: TimeInterval = 0.5) async {
        let start = app.now
        frame = art.frames["move_1"] != nil ? "move_1" : "idle_0"
        while true {
            let t = min(1, (app.now - start) / duration)
            place(CGPoint(x: p.x, y: p.y - height * (1 - CGFloat(t * t))))
            squash = CGSize(width: 0.92, height: 1.1)
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        frame = "idle_0"
        Sfx.shared.play(.thud)
        await land()
    }

    /// The landing spring: squash, overshoot, settle.
    func land() async {
        let s = DampedSpring(dampingRatio: 0.35, omega: 2 * .pi / 0.18)
        let start = app.now
        while app.now - start < 0.45 {
            let v = s.value(from: 0.22, to: 0, at: app.now - start)
            squash = CGSize(width: 1 + v, height: 1 - v)
            try? await Task.sleep(for: .milliseconds(16))
        }
        squash = CGSize(width: 1, height: 1)
    }

    /// A happy hop on the spot.
    func hop(height: CGFloat = 26) async {
        let base = foot, start = app.now, d = 0.36
        frame = art.frames["move_1"] != nil ? "move_1" : "idle_0"
        Sfx.shared.play(.whoosh)
        while true {
            let t = min(1, (app.now - start) / d)
            place(CGPoint(x: base.x, y: base.y - height * CGFloat(4 * t * (1 - t))))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        frame = "idle_0"
        await land()
    }

    /// Scale and move together (the opening zoom-out).
    func zoom(to p: CGPoint, scale target: CGFloat, duration: TimeInterval) async {
        let a = foot, s0 = scale, start = app.now
        while true {
            let t = min(1, (app.now - start) / duration)
            let e = CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
            scale = s0 + (target - s0) * e
            place(CGPoint(x: a.x + (p.x - a.x) * e, y: a.y + (p.y - a.y) * e))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func remove() { panel.orderOut(nil) }
}

@MainActor
final class ActorView: NSView {
    weak var actor: ShowcaseActor?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let a = actor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .none
        if let t = a.thread {
            // Silky's silk: a thin line from above to her back
            NSColor(white: 0.92, alpha: 0.85).setFill()
            NSRect(x: bounds.midX - 0.5, y: a.art.size(a.frame).height * a.scale * 0.7, width: 1, height: bounds.height).fill()
            _ = t
        }
        a.art.draw(a.frame, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height), scale: a.scale, context: ctx,
                   squash: a.squash, mirrored: a.mirrored, lean: 0)
    }
}

/// Titles drawn in a 5×7 pixel alphabet (no font files): "THE PIXLZ", "PIXLZ · POWERED BY NEAR".
enum PixelFont {
    static let glyphs: [Character: [String]] = [
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
        "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
        "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
        "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
        "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
        "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
        "·": [".....", ".....", ".....", "..#..", ".....", ".....", "....."],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ]

    /// The text's size at `px` points per pixel (1 px between letters).
    static func size(_ text: String, px: CGFloat) -> CGSize {
        CGSize(width: CGFloat(text.count * 6 - 1) * px, height: 7 * px)
    }

    /// Draws `text` with its top-left at `o` (flipped view coordinates), white with an ink shadow.
    static func draw(_ text: String, at o: CGPoint, px: CGFloat, color: NSColor = .white, shadow: NSColor = NSColor(srgbRed: 0.106, green: 0.165, blue: 0.102, alpha: 1)) {
        for pass in 0..<2 {
            (pass == 0 ? shadow : color).setFill()
            let off: CGFloat = pass == 0 ? px * 0.6 : 0
            for (i, ch) in text.uppercased().enumerated() {
                guard let g = glyphs[ch] else { continue }
                for (y, row) in g.enumerated() {
                    for (x, c) in row.enumerated() where c == "#" {
                        NSRect(x: o.x + CGFloat(i * 6 + x) * px + off, y: o.y + CGFloat(y) * px + off, width: px, height: px).fill()
                    }
                }
            }
        }
    }
}
