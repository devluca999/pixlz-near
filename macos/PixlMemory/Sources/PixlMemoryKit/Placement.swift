import AppKit

/// Keeps overlays (menus, pickers, bubbles, panels) fully on the visible screen: below the
/// menu bar, above the Dock, inside the display's edges. AppKit coordinates (y up).
@MainActor
public enum Placement {
    /// `r` moved as little as possible to lie inside `bounds` inset by `margin`. If it's larger
    /// than the space, its top-left corner is kept on screen (so titles and close buttons show).
    public static func fit(_ r: CGRect, in bounds: CGRect, margin: CGFloat = 8) -> CGRect {
        let b = bounds.insetBy(dx: margin, dy: margin)
        var o = r.origin
        if r.width >= b.width { o.x = b.minX } else { o.x = min(max(o.x, b.minX), b.maxX - r.width) }
        if r.height >= b.height { o.y = b.maxY - r.height } else { o.y = min(max(o.y, b.minY), b.maxY - r.height) }
        return CGRect(origin: o, size: r.size)
    }

    /// A flipped view's sub-rect in screen coordinates, for a window whose content view it is.
    public static func screenRect(of r: NSRect, inFlippedViewOfHeight h: CGFloat, windowOrigin o: NSPoint) -> NSRect {
        NSRect(x: o.x + r.minX, y: o.y + (h - r.maxY), width: r.width, height: r.height)
    }
}
