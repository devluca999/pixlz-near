import CoreGraphics
import Foundation

/// The C8 option-bubble menu, as data and maths (no views): slots, the arc over the Pixl's
/// head, placement that stays on screen and off the caret/selection, and the motion curves.
/// Coordinates are top-left global (y down), like the rest of the motion code.
public enum BubbleMenuModel {
    public struct Slot: Equatable, Sendable {
        public let id: String
        public let label: String
        public let sub: String?
        public init(id: String, label: String, sub: String? = nil) { self.id = id; self.label = label; self.sub = sub }
        /// "Wallet, 4.20 NEAR" for VoiceOver.
        public var accessibilityLabel: String { sub.map { "\(label), \($0)" } ?? label }
    }

    // tokens/colors.css
    public static let bubbleSize: CGFloat = 44
    public static let arcStep: Double = 32            // degrees between bubbles
    public static let stagger: TimeInterval = 0.045
    public static let openTime: TimeInterval = 0.32
    public static let closeTime: TimeInterval = 0.17
    public static let closeStagger: TimeInterval = 0.03
    public static let popTime: TimeInterval = 0.13
    public static let ringTime: TimeInterval = 0.22
    public static let hoverTime: TimeInterval = 0.12
    public static let longPress: TimeInterval = 0.45
    public static let labelHeight: CGFloat = 22

    /// Slot 1 is Polish while text is selected, Ask otherwise; Send to device only with a peer.
    /// Agents (SPEC §16) comes second, once Claude Code is connected or a session is running.
    public static func slots(selection: Bool, peer: String?, walletSub: String?, agentsSub: String? = nil) -> [Slot] {
        var s = [selection ? Slot(id: "polish", label: "Polish", sub: "selection") : Slot(id: "ask", label: "Ask")]
        if let agentsSub { s.append(Slot(id: "agents", label: "Agents", sub: agentsSub)) }
        s += [Slot(id: "memory", label: "Memory"),
                 Slot(id: "wallet", label: "Wallet", sub: walletSub)]
        if let peer { s.append(Slot(id: "send", label: "Send to \(peer)")) }
        s.append(Slot(id: "play", label: "Play"))
        s.append(Slot(id: "more", label: "More"))
        return s
    }

    /// Arc radius: 88 pt at 2×, 104 pt at 3× (design tiles), growing with the Pixl.
    public static func radius(scale: CGFloat) -> CGFloat { 56 + 16 * scale }

    public enum Direction: CaseIterable, Sendable { case up, left, right, down
        var angle: Double {
            switch self { case .up: -90; case .down: 90; case .left: 180; case .right: 0 }
        }
    }

    /// Bubble centres, `arcStep` apart, centred on `direction` from `head`.
    public static func arc(count n: Int, head: CGPoint, radius r: CGFloat, direction: Direction = .up) -> [CGPoint] {
        (0..<n).map { i in
            let a = (direction.angle + (Double(i) - Double(n - 1) / 2) * arcStep) * .pi / 180
            return CGPoint(x: head.x + r * CGFloat(cos(a)), y: head.y + r * CGFloat(sin(a)))
        }
    }

    /// The box a bubble and its hover label need.
    public static func footprint(_ c: CGPoint) -> CGRect {
        let half = bubbleSize / 2
        let bubble = CGRect(x: c.x - half - 6, y: c.y - half - 4, width: bubbleSize + 12, height: bubbleSize + 10)
        let label = CGRect(x: c.x - 70, y: c.y - half - 9 - labelHeight, width: 140, height: labelHeight)
        return bubble.union(label)
    }

    public struct Placement: Equatable, Sendable {
        public let direction: Direction
        public let offset: CGVector   // nudge applied to every bubble to stay on screen
        public let centers: [CGPoint]
    }

    /// Up first (the design), then left, right, down: the first direction whose bubbles and
    /// labels fit on screen and miss every `avoid` rect (the caret, the selection being polished).
    /// If none fit cleanly, the one that overlaps least, nudged onto the screen.
    public static func place(count: Int, head: CGPoint, radius: CGFloat, screen: CGRect, avoid: [CGRect]) -> Placement {
        var best: (score: CGFloat, p: Placement)?
        for d in Direction.allCases {
            let pts = arc(count: count, head: head, radius: radius, direction: d)
            let box = pts.map(footprint).reduce(CGRect.null) { $0.union($1) }
            let dx = box.minX < screen.minX ? screen.minX - box.minX : (box.maxX > screen.maxX ? screen.maxX - box.maxX : 0)
            let dy = box.minY < screen.minY ? screen.minY - box.minY : (box.maxY > screen.maxY ? screen.maxY - box.maxY : 0)
            let moved = pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            let overlap = moved.map(footprint).reduce(CGFloat(0)) { acc, r in
                acc + avoid.reduce(0) { $0 + area(r.intersection($1)) }
            }
            let p = Placement(direction: d, offset: CGVector(dx: dx, dy: dy), centers: moved)
            if overlap == 0 && dx == 0 && dy == 0 { return p }
            let score = overlap * 10 + abs(dx) + abs(dy)
            if best == nil || score < best!.score { best = (score, p) }
        }
        return best!.p
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull || r.isEmpty ? 0 : r.width * r.height }

    // MARK: motion (C8): each returns q = 0 at the head … 1 at the slot, s = scale, op = opacity

    public struct Frame: Equatable, Sendable {
        public var q: CGFloat, s: CGFloat, op: CGFloat
        public static let rest = Frame(q: 1, s: 1, op: 1)
    }

    static func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    /// Puff out: 320 ms spring 0.2 → 1.14 → 0.95 → 1.02 → 1. Nil before it starts.
    public static func open(_ t: TimeInterval) -> Frame? {
        let p = t / openTime
        if p <= 0 { return nil }
        if p >= 1 { return .rest }
        var q = 1.0, s: Double
        if p < 0.45 { let u = easeOutCubic(p / 0.45); q = u; s = 0.2 + 0.94 * u }
        else if p < 0.7 { s = 1.14 - 0.19 * ((p - 0.45) / 0.25) }
        else if p < 0.85 { s = 0.95 + 0.07 * ((p - 0.7) / 0.15) }
        else { s = 1.02 - 0.02 * ((p - 0.85) / 0.15) }
        return Frame(q: q, s: s, op: min(1, p / 0.2))
    }

    /// Close: swell to 1.06, then accelerate back into the head while fading. Nil when gone.
    public static func close(_ t: TimeInterval) -> Frame? {
        let p = t / closeTime
        if p <= 0 { return .rest }
        if p >= 1 { return nil }
        if p < 0.25 { return Frame(q: 1, s: 1 + 0.06 * p / 0.25, op: 1) }
        let u = pow((p - 0.25) / 0.75, 2)
        return Frame(q: 1 - u, s: 1.06 - 0.86 * u, op: 1 - u)
    }

    /// Drag start: every bubble pops at once (scale to 1.28, fading). Nil when gone.
    public static func pop(_ t: TimeInterval) -> Frame? {
        let p = t / popTime
        if p >= 1 { return nil }
        let e = easeOutCubic(max(p, 0))
        return Frame(q: 1, s: 1 + 0.28 * e, op: 1 - e)
    }

    /// Bubble `i` of `n`: open staggers 45 ms forward; close 30 ms in reverse (last opened closes first).
    public static func openDelay(_ i: Int) -> TimeInterval { Double(i) * stagger }
    public static func closeDelay(_ i: Int, of n: Int) -> TimeInterval { Double(n - 1 - i) * closeStagger }
    public static func openDuration(count n: Int) -> TimeInterval { openDelay(n - 1) + openTime }
    public static func closeDuration(count n: Int) -> TimeInterval { closeDelay(0, of: n) + closeTime }

    /// Hover lifts 3 pt and grows to 1.1; press shrinks to 0.9 (glass) or sinks 2 pt to 0.96 (paper).
    public static func hoverPress(hover h: CGFloat, press p: CGFloat, paper: Bool) -> (scale: CGFloat, lift: CGFloat) {
        let pressScale: CGFloat = paper ? 0.96 : 0.9
        let scale = (1 + 0.1 * h) * (1 - (1 - pressScale) * p)
        let lift = -3 * h * (1 - p) + (paper ? 2 * p : 0)
        return (scale, lift)
    }

    /// Eases a state value toward its target over `hoverTime`.
    public static func approach(_ value: CGFloat, to target: CGFloat, dt: TimeInterval) -> CGFloat {
        let step = CGFloat(dt / hoverTime)
        return value < target ? min(target, value + step) : max(target, value - step)
    }
}
