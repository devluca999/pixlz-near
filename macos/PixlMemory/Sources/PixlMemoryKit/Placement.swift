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

    /// Where a bubble of `size` goes by the Pixl without ever covering it (AppKit coordinates,
    /// y up): above its head, else below its feet, else to its left or right, each kept on
    /// `screen`. A spot only counts if it still clears the Pixl once kept on screen.
    public static func beside(pet: CGRect, size: CGSize, in screen: CGRect, gap: CGFloat = 4, margin: CGFloat = 4) -> CGRect {
        let keepOff = pet.insetBy(dx: -1, dy: -1)
        let tries = [
            CGRect(x: pet.midX - size.width / 2, y: pet.maxY + gap, width: size.width, height: size.height),            // above
            CGRect(x: pet.midX - size.width / 2, y: pet.minY - gap - size.height, width: size.width, height: size.height), // below
            CGRect(x: pet.minX - gap - size.width, y: pet.midY - size.height / 2, width: size.width, height: size.height), // left
            CGRect(x: pet.maxX + gap, y: pet.midY - size.height / 2, width: size.width, height: size.height),              // right
        ]
        for t in tries {
            let r = fit(t, in: screen, margin: margin)
            if !r.intersects(keepOff) { return r }
        }
        // a Pixl as big as the screen: above it anyway
        return fit(tries[0], in: screen, margin: margin)
    }

        /// A flipped view's sub-rect in screen coordinates, for a window whose content view it is.
    public static func screenRect(of r: NSRect, inFlippedViewOfHeight h: CGFloat, windowOrigin o: NSPoint) -> NSRect {
        NSRect(x: o.x + r.minX, y: o.y + (h - r.maxY), width: r.width, height: r.height)
    }
}
