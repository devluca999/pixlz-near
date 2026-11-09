import CoreGraphics
import Foundation

/// How big the Pixl is: 1× to 6× its art, in half steps. On a Retina display (2 device pixels
/// per point) a half step is still a whole number of device pixels per art pixel, so the art
/// stays crisp; on a 1× display it snaps to whole steps.
public enum PixlScale {
    public static let range: ClosedRange<Double> = 1...6
    public static let presets: [Double] = [1, 2, 3, 4, 6]

    public static func snap(_ s: Double, backing: CGFloat = 2) -> Double {
        let step = backing >= 2 ? 0.5 : 1
        return min(max((s / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    /// "2×", "2.5×".
    public static func label(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%.1f×", s)
    }

    /// Dragging a corner of the Pixl's box (corners relative to its feet, which stay planted):
    /// the new scale is the start scale times how far along the corner's direction the mouse
    /// went. Top corners grow and shrink diagonally; bottom corners sideways.
    /// `corner` is the corner's start position relative to the feet (top-left coordinates).
    public static func fromDrag(start: Double, corner: CGVector, mouse: CGPoint, feet: CGPoint) -> Double {
        let len2 = corner.dx * corner.dx + corner.dy * corner.dy
        guard len2 > 1 else { return start }
        let m = CGVector(dx: mouse.x - feet.x, dy: mouse.y - feet.y)
        let ratio = Double((m.dx * corner.dx + m.dy * corner.dy) / len2)
        return start * max(ratio, 0)
    }
}
