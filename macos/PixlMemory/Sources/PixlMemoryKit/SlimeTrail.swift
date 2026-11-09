import AppKit

/// Slugg's slime trail (C11, pets-k.js trailPts): a two-pixel line laid at the tail along the path
/// it crawled, a base row with a lighter row above it and sparse white glints near the tail. It
/// dithers away with distance from the tail (solid → 50 % → 25 %, ordered dither) so it's never
/// longer than one body length, and after Slugg stops the whole trail steps down every 0.5 s and is
/// gone by 2 s. Only while crawling; never while sealed.
public enum SlimeTrail {
    /// The design's green slime (pets-m.js), and the brighter one Racer leaves.
    public static let green = ["#0A140A", "#34482A", "#5A7232", "#9AB45A", "#E2F2B4", "#FFFFFF"]
    public static let racer = ["#04140A", "#1A5A24", "#2E9A3A", "#6ADA58", "#E0FFC8", "#FFFFFF"]
    static let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    public struct Pixel: Hashable, Sendable { public let x, y, tone: Int }

    /// How solid the trail is `f` of the way from the tail (0) to its far end (1), `age` steps after stopping.
    public static func level(_ f: Double, age: Int) -> Double { (f < 0.34 ? 1 : f < 0.67 ? 0.5 : 0.25) - Double(age) * 0.25 }

    static func keep(_ x: Int, _ y: Int, _ lv: Double) -> Bool { (Double(bayer[y & 3][x & 3]) + 0.5) / 16 <= lv }

    /// The trail's pixels along `path` (art pixels on the global grid, the tail first), with
    /// `normal` pointing away from the surface (y down: the floor's is (0, -1)).
    public static func pixels(path: [CGPoint], normal: (Int, Int), age: Int) -> [Pixel] {
        guard path.count > 1, age < 4 else { return [] }
        var seg: [Double] = [], total = 0.0
        for i in 1..<path.count { let l = Double(hypot(path[i].x - path[i - 1].x, path[i].y - path[i - 1].y)); seg.append(l); total += l }
        guard total > 0 else { return [] }
        var out: [Pixel] = [], seen = Set<Int>(), acc = 0.0
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i], l = seg[i - 1]
            var s = 0.0
            while s < l {
                let x = Int((a.x + (b.x - a.x) * CGFloat(s / l)).rounded()), y = Int((a.y + (b.y - a.y) * CGFloat(s / l)).rounded())
                s += 0.5
                guard seen.insert(x &* 73_856_093 ^ y &* 19_349_663).inserted else { continue }
                let f = (acc + s) / total, lv = level(f, age: age)
                if keep(x, y, lv) { out.append(Pixel(x: x, y: y, tone: 2)) }
                let x2 = x + normal.0, y2 = y + normal.1
                if f < 0.7, keep(x2, y2, lv - (f < 0.34 ? 0 : 0.25)) { out.append(Pixel(x: x2, y: y2, tone: 3)) }
                if f < 0.4, age < 1, (x + y) % 7 == 0 { out.append(Pixel(x: x2, y: y2, tone: 5)) }
            }
            acc += l
        }
        return out
    }
}

/// Draws trail pixels (global art grid) into a click-through panel's view.
@MainActor
public final class SlimeTrailView: NSView {
    public var pixels: [SlimeTrail.Pixel] = [] { didSet { needsDisplay = true } }
    public var origin = CGPoint.zero      // the art pixel at the view's top-left
    public var scale: CGFloat = 2
    public var palette = SlimeTrail.green
    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override func draw(_ dirtyRect: NSRect) {
        let colors = palette.map { hex -> NSColor in let c = RGB(hex: hex); return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
        for p in pixels.sorted(by: { $0.tone < $1.tone }) {
            colors[min(p.tone, colors.count - 1)].setFill()
            NSRect(x: (CGFloat(p.x) - origin.x) * scale, y: (CGFloat(p.y) - origin.y) * scale, width: scale, height: scale).fill()
        }
    }
}
