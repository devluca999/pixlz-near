import AppKit
import PixlzCore

/// Landing dust (SPEC §8): two small clouds and a few flecks, from PixlzCore's FX pool
/// (max 24 particles). Drawn in whole art pixels with the design's dust ramp and a 4×4
/// Bayer dither that dissolves each cloud as it ages. Click-through; draws nothing when empty.
@MainActor
public final class DustView: NSView {
    public private(set) var pool = ParticlePool()
    public let scale: CGFloat

    // design/explorations/c3 dust ramp (shadow → highlight)
    static let ramp: [NSColor] = ["#5C4F3F", "#8A7860", "#B09C80"].map {
        let v = Int($0.dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    static let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

    public init(scale: CGFloat, size: NSSize) {
        self.scale = scale
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Puffs at `feet` (view coordinates, unflipped: y up).
    public func emit(at feet: CGPoint, now: Date) {
        let s = scale
        for dir: CGFloat in [-1, 1] {
            pool.emit(.init(effect: .dust, position: CGPoint(x: feet.x + dir * 8 * s, y: feet.y + 2 * s),
                            velocity: CGVector(dx: dir * 30 * s, dy: 6 * s), born: now, lifetime: 0.36))
        }
        for (dx, dy) in [(-9.0, 4.0), (3.0, 5.0), (-3.0, 6.0)] {
            pool.emit(.init(effect: .puff, position: CGPoint(x: feet.x + dx * s, y: feet.y + dy * s),
                            velocity: CGVector(dx: dx * 3 * s, dy: 14 * s), born: now, lifetime: 0.24))
        }
        needsDisplay = true
    }

    /// Advances the pool; returns true while anything is still visible.
    @discardableResult
    public func step(to now: Date, dt: TimeInterval) -> Bool {
        pool.step(to: now, dt: dt)
        needsDisplay = true
        return !pool.isEmpty
    }

    public override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        let s = scale
        for p in pool.particles {
            let age = min(max(now.timeIntervalSince(p.born) / p.lifetime, 0), 1)
            if p.effect == .puff {  // a single fleck, tone 3
                Self.ramp[1].setFill()
                NSRect(x: (p.position.x / s).rounded() * s, y: (p.position.y / s).rounded() * s, width: s, height: s).fill()
                continue
            }
            let rx = 3 + 2 * age, ry = 1.6 + 0.8 * age  // art pixels, growing
            let cx = (p.position.x / s).rounded(), cy = (p.position.y / s).rounded()
            for y in Int(-ry.rounded(.up))...Int(ry.rounded(.up)) {
                for x in Int(-rx.rounded(.up))...Int(rx.rounded(.up)) {
                    let v = pow(Double(x) / rx, 2) + pow(Double(y) / ry, 2)
                    guard v <= 1 else { continue }
                    let gx = Int(cx) + x, gy = Int(cy) + y
                    // dissolve with age: keep a pixel while its Bayer threshold beats the age
                    guard Self.bayer[(gy & 3)][(gx & 3)] / 16 >= age * 0.95 else { continue }
                    Self.ramp[y > 0 ? 2 : (v > 0.6 ? 0 : 1)].setFill()
                    NSRect(x: CGFloat(gx) * s, y: CGFloat(gy) * s, width: s, height: s).fill()
                }
            }
        }
    }
}
