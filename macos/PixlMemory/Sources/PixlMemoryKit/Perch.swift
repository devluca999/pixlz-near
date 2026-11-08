import CoreGraphics

/// Where Frogg sits. All rects are in global "top-left" coordinates, the ones the
/// Accessibility API and CGWindowList use: origin at the top-left of the primary
/// display, y grows downward. `foot` is the bottom-centre of Frogg's feet.
public enum Perch {
    public enum Place: Equatable, Sendable {
        case windowTop   // standing on the active window's top edge (SPEC §7.1)
        case ground      // bottom of the screen, above the Dock (floor of last resort)
    }

    public struct Spot: Equatable, Sendable {
        public let foot: CGPoint
        public let place: Place
    }

    /// Room kept clear of the traffic lights on the left of a title bar.
    static let leftClearance: CGFloat = 90
    /// Where on the title bar Frogg sits, measured from the window's right edge.
    static let rightOffset: CGFloat = 140
    /// The 2 pt band at the focused window's top edge the hitbox may overlap (SPEC §6.4).
    static let band: CGFloat = 2

    /// - Parameters:
    ///   - window: the active window's frame, or nil (no window, no Accessibility).
    ///   - screens: each display's visible frame (below the menu bar, above the Dock).
    ///   - sprite: Frogg's on-screen size in pt.
    public static func spot(window: CGRect?, screens: [CGRect], sprite: CGSize) -> Spot? {
        guard !screens.isEmpty else { return nil }
        if let w = window, let screen = screens.first(where: { $0.contains(CGPoint(x: w.midX, y: max(w.minY, $0.minY))) })
            ?? screens.first(where: { $0.intersects(w) }) {
            let roomAbove = w.minY - screen.minY
            let wideEnough = w.width >= sprite.width + leftClearance + 20
            if roomAbove >= sprite.height - band, wideEnough {
                let lo = w.minX + leftClearance + sprite.width / 2
                let hi = w.maxX - sprite.width / 2 - 8
                let x = clamp(w.maxX - rightOffset, lo, hi)
                let sx = clamp(x, screen.minX + sprite.width / 2, screen.maxX - sprite.width / 2)
                return Spot(foot: CGPoint(x: sx.rounded(), y: (w.minY + band).rounded()), place: .windowTop)
            }
            return ground(on: screen, sprite: sprite)
        }
        return ground(on: screens[0], sprite: sprite)
    }

    static func ground(on screen: CGRect, sprite: CGSize) -> Spot {
        Spot(foot: CGPoint(x: (screen.maxX - sprite.width / 2 - 24).rounded(), y: screen.maxY), place: .ground)
    }

    /// Converts a top-left-origin rect to AppKit's bottom-left origin.
    public static func toAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The panel frame (AppKit coordinates) that puts Frogg's feet on `foot`.
    public static func panelFrame(foot: CGPoint, canvas: CGSize, primaryHeight: CGFloat) -> CGRect {
        let topLeft = CGRect(x: foot.x - canvas.width / 2, y: foot.y - canvas.height, width: canvas.width, height: canvas.height)
        return toAppKit(topLeft, primaryHeight: primaryHeight)
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi) }
}
