import AppKit

/// The one surface material every overlay uses (C8): speech bubble, option bubbles, the More
/// list, the polish card, settings, wallet, memory and ask cards.
///
/// - Liquid Glass (macOS 26+, unless Reduce Transparency is on): a real NSGlassEffectView,
///   tinted light or dark, with the design's rim highlights, specular gloss and hairline ring
///   drawn inside the glass, and a soft shadow.
/// - Fallback (older macOS, or Reduce Transparency): opaque paper, 2 pt ink ring, hard 3 pt ink
///   drop shadow, no blur (C8 "Fallback").
///
/// `dim` is the tint opacity: the backdrop dim that keeps text legible (see `Legibility`).
@MainActor
public final class SurfaceView: NSView {
    public enum Shape: Equatable, Sendable { case circle, rounded(CGFloat) }

    public struct Look: Equatable, Sendable {
        public var glass: Bool
        public var variant: Legibility.Variant
        public var dim: CGFloat
        public init(glass: Bool, variant: Legibility.Variant, dim: CGFloat) { self.glass = glass; self.variant = variant; self.dim = dim }

        /// Whether real Liquid Glass can be used here.
        public static var glassAvailable: Bool {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { return false }
            if #available(macOS 26.0, *) { return true }
            return false
        }

        /// For surfaces with text: the variant and dim that keep 4.5:1 over any backdrop
        /// (we never see the screen), never below the design's own fill.
        public static func text(designFill: Double, prefersDark: Bool, glass: Bool = glassAvailable) -> Look {
            guard glass else { return Look(glass: false, variant: prefersDark ? .dark : .light, dim: 0.94) }
            let pick = Legibility.pick(backdrop: 0...1, prefersDark: prefersDark, floor: designFill)
            return Look(glass: true, variant: pick.variant, dim: CGFloat(pick.alpha))
        }

        /// For icon-only bubbles (non-text, self-outlined icons): the design's glass fill.
        public static func icon(prefersDark: Bool, glass: Bool = glassAvailable) -> Look {
            guard glass else { return Look(glass: false, variant: prefersDark ? .dark : .light, dim: 0.94) }
            return Look(glass: true, variant: prefersDark ? .dark : .light, dim: prefersDark ? 0.32 : 0.18)
        }

        public var textColor: NSColor { tokens.text }
        /// The fill behind a hovered (or pressed) row, chosen per theme so this look's text
        /// stays legible on it: pale green on light paper, an accent tint on dark.
        @MainActor public func rowFill(pressed: Bool) -> NSColor {
            if glass {
                return variant == .dark ? NSColor.white.withAlphaComponent(pressed ? 0.2 : 0.12)
                                        : NSColor.white.withAlphaComponent(pressed ? 0.6 : 0.4)
            }
            if variant == .dark { return Accent.color.withAlphaComponent(pressed ? 0.3 : 0.2) }
            return pressed ? (Theme.selected.blended(withFraction: 0.08, of: Theme.ink) ?? Theme.selected) : Theme.selected
        }
        public var mutedColor: NSColor { tokens.text2 }
        public var appearance: NSAppearance? { NSAppearance(named: variant == .dark ? .darkAqua : .aqua) }
    }

    public let shape: Shape
    public private(set) var look: Look
    /// Put your subviews here; it sits above the material (inside the glass on macOS 26+).
    /// Where callers put their views: flipped (y down), like every other Pixl view.
    public let content: NSView = FlippedView()
    private let overlay: SurfaceOverlay
    private var glassView: NSView?

    public var pressed = false { didSet { if pressed != oldValue { overlay.pressed = pressed; overlay.needsDisplay = true; layoutContent() } } }
    public var lit = false { didSet { if lit != oldValue { overlay.lit = lit; overlay.needsDisplay = true } } }
    /// Keyboard focus ring in the Pixl's accent.
    public var focused = false { didSet { if focused != oldValue { overlay.focused = focused; overlay.needsDisplay = true } } }
    public var accent: NSColor = Theme.accent { didSet { overlay.accent = accent } }

    public init(frame: NSRect, shape: Shape, look: Look) {
        self.shape = shape
        self.look = look
        overlay = SurfaceOverlay(shape: shape, look: look)
        super.init(frame: frame)
        appearance = look.appearance
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isOpaque: Bool { false }
    public override var isFlipped: Bool { true }

    var radius: CGFloat {
        switch shape { case .circle: min(bounds.width, bounds.height) / 2; case .rounded(let r): r }
    }

    /// The paper fallback's hard shadow sits under the surface; glass gets a soft one.
    var shadowInset: CGFloat { look.glass ? 0 : 3 }

    private func build() {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - shadowInset)
        overlay.frame = body
        content.frame = body
        if look.glass, #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: body)
            g.cornerRadius = radius
            g.style = .regular
            g.tintColor = NSColor(rgb: Legibility.fill(look.variant)).withAlphaComponent(look.dim * 0.5)
            let inner = NSView(frame: NSRect(origin: .zero, size: body.size))
            overlay.frame = inner.bounds
            content.frame = inner.bounds
            inner.addSubview(overlay)
            inner.addSubview(content)
            g.contentView = inner
            addSubview(g)
            glassView = g
            wantsLayer = true
            layer?.shadowColor = NSColor(srgbRed: 16 / 255, green: 22 / 255, blue: 40 / 255, alpha: 1).cgColor
            layer?.shadowOpacity = look.variant == .dark ? 0.4 : 0.16
            layer?.shadowRadius = 8
            layer?.shadowOffset = CGSize(width: 0, height: -6)
        } else {
            addSubview(overlay)
            addSubview(content)
        }
    }

    public override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - shadowInset)
        if let g = glassView {
            g.frame = body
            if #available(macOS 26.0, *), let glass = g as? NSGlassEffectView {
                glass.cornerRadius = radius
                glass.contentView?.frame = NSRect(origin: .zero, size: body.size)
            }
            overlay.frame = NSRect(origin: .zero, size: body.size)
            content.frame = NSRect(origin: .zero, size: body.size)
        } else {
            // paper: pressing sinks the surface onto its shadow
            let sink: CGFloat = pressed ? 2 : 0
            overlay.frame = body
            content.frame = body.offsetBy(dx: 0, dy: sink)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // the surface itself (and its material layers) count as the surface; controls inside stay themselves
        if hit === overlay || hit === glassView || hit === content || hit.superview === glassView { return self }
        return hit
    }
}

/// Draws the material details: glass tint, rim and gloss, or the paper fill, ring and shadow.
@MainActor
final class SurfaceOverlay: NSView {
    let shape: SurfaceView.Shape
    let look: SurfaceView.Look
    var pressed = false
    var lit = false
    var focused = false
    var accent: NSColor = Theme.accent

    init(shape: SurfaceView.Shape, look: SurfaceView.Look) {
        self.shape = shape
        self.look = look
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func path(_ r: NSRect) -> NSBezierPath {
        switch shape {
        case .circle: NSBezierPath(ovalIn: r)
        case .rounded(let radius): NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if look.glass {
            // tint = the backdrop dim; lit (hover) brightens it a little
            let fill = NSColor(rgb: Legibility.fill(look.variant))
            fill.withAlphaComponent(min(1, look.dim + (lit ? 0.14 : 0) - (pressed ? 0.1 : 0))).setFill()
            path(r).fill()
            if pressed {
                NSColor.black.withAlphaComponent(0.12).setFill()
                path(r).fill()
            }
            // top-left rim highlight and hairline ring (C8 inset shadows)
            let rim = path(r.insetBy(dx: 1.5, dy: 1.5))
            rim.lineWidth = 1.5
            NSColor.white.withAlphaComponent(look.variant == .dark ? 0.35 : 0.8).setStroke()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: r.width * 0.6, height: r.height * 0.6)).addClip()
            rim.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let ring = path(r)
            ring.lineWidth = 0.5
            NSColor.white.withAlphaComponent(look.variant == .dark ? 0.24 : 0.6).setStroke()
            ring.stroke()
            if case .circle = shape {  // specular gloss
                let gloss = NSRect(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.09, width: r.width * 0.5, height: r.height * 0.27)
                NSGradient(starting: NSColor.white.withAlphaComponent(look.variant == .dark ? 0.27 : 0.6),
                           ending: NSColor.white.withAlphaComponent(0))?.draw(in: NSBezierPath(ovalIn: gloss), relativeCenterPosition: NSPoint(x: -0.1, y: -0.2))
            }
        } else {
            // C10 Solid (every Pixl but the ghost): hard 3 pt shadow, 94 % fill with a 2 px
            // ordered-dither grain, 2 pt outline with a 1 pt halo, inner top light / bottom shade
            let t = look.tokens
            let face = r.insetBy(dx: 0.5, dy: 0).offsetBy(dx: 0, dy: pressed ? 2 : 0)
            t.shadow.setFill()
            path(r.offsetBy(dx: 0, dy: pressed ? 1 : 3)).fill()
            let body = path(face)
            (lit ? (t.fill.blended(withFraction: 0.1, of: accent) ?? t.fill) : t.fill).setFill()
            body.fill()
            if let grain = t.grain {
                NSGraphicsContext.saveGraphicsState()
                body.addClip()
                grain.setFill()
                let bayer = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]
                for y in stride(from: Int(face.minY), to: Int(face.maxY), by: 2) {
                    for x in stride(from: Int(face.minX), to: Int(face.maxX), by: 2) where bayer[(y / 2) & 3][(x / 2) & 3] < 4 {
                        NSRect(x: x, y: y, width: 2, height: 2).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            // inner light along the top, shade along the bottom
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            t.highlight.setFill(); NSRect(x: face.minX, y: face.minY + 2, width: face.width, height: 2).fill()
            t.lowlight.setFill(); NSRect(x: face.minX, y: face.maxY - 4, width: face.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            body.lineWidth = 2
            t.outline.setStroke()
            body.stroke()
            let halo = path(face.insetBy(dx: -0.5, dy: -0.5))
            halo.lineWidth = 1
            t.halo.setStroke()
            halo.stroke()
        }
        if focused {
            let ring = path(bounds.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 2.5
            accent.setStroke()
            ring.stroke()
        }
    }
}

extension NSColor {
    convenience init(rgb c: RGB, alpha: CGFloat = 1) {
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
}

/// A plain container with y going down.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
