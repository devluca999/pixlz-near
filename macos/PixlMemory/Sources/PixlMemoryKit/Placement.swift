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

/// Where typing is about to happen, and where the Pixl can sit clear of it (top-left global).
public enum TypingZone {
    /// A small field (a search box, a chat input): the whole field and a margin. A big editor:
    /// the caret's line, mostly ahead of it and a little below, where the next words appear.
    public static func zone(field: CGRect?, caret: CGRect?) -> CGRect? {
        if let f = field, f.height <= 140, f.width > 0 { return f.insetBy(dx: -16, dy: -12) }
        if let c = caret { return CGRect(x: c.minX - 80, y: c.minY - 30, width: 480, height: c.height + 90) }
        return field.map { $0.insetBy(dx: -16, dy: -12) }
    }

    /// The nearest x in `span` (in half-sprite steps) where the Pixl standing at `footY` clears `zone`.
    public static func nearestClearX(from x: CGFloat, span: ClosedRange<CGFloat>, footY: CGFloat, sprite: CGSize, zone: CGRect) -> CGFloat? {
        func clear(_ x: CGFloat) -> Bool { !CGRect(x: x - sprite.width / 2, y: footY - sprite.height, width: sprite.width, height: sprite.height).intersects(zone) }
        let step = max(sprite.width / 2, 8)
        var k: CGFloat = 1
        while k * step <= span.upperBound - span.lowerBound + step {
            for c in [x + k * step, x - k * step] where span.contains(c) && clear(c) { return c }
            k += 1
        }
        return nil
    }
}
