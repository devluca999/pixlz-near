import AppKit

/// Draws one Frogg frame bottom-centred at an integer scale. Transparent pixels are
/// left untouched, so the window server passes clicks there through to the app
/// below (SPEC R2: only the Pixl's opaque pixels catch the mouse).
@MainActor
public final class FroggView: NSView {
    public var frameName: String { didSet { if frameName != oldValue { needsDisplay = true } } }
    public var squash = CGSize(width: 1, height: 1) { didSet { if squash != oldValue { needsDisplay = true } } }
    public var mirrored = false { didSet { if mirrored != oldValue { needsDisplay = true } } }
    public var lean: CGFloat = 0 { didSet { if lean != oldValue { needsDisplay = true } } }
    /// On a wall or the ceiling (Roam), the art is turned about the view's centre.
    public var surface: Surface = .floor { didSet { if surface != oldValue { needsDisplay = true } } }
    /// Slugg's shell, drawn as its own layer this many art pixels behind the body (shell lag).
    public var shellOffset: CGPoint = .zero { didSet { if shellOffset != oldValue { needsDisplay = true } } }
    public let scale: CGFloat
    /// Room around the canvas so a stretch or squash never clips (transparent, click-through).
    public static let headroom: CGFloat = 1.3
    public enum MouseEvent { case down, dragged, up, right }
    public var onMouse: ((MouseEvent, NSEvent) -> Void)?
    private let art = FroggArt.shared

    public init(scale: CGFloat = 2, frameName: String = "idle_0") {
        self.scale = scale
        self.frameName = frameName
        let c = FroggArt.shared.canvas
        super.init(frame: NSRect(x: 0, y: 0, width: (c.width * scale * Self.headroom).rounded(),
                                 height: (c.height * scale * Self.headroom).rounded()))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if surface != .floor, let img = art.image(frameName) {
            let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: bounds.midX.rounded(), y: bounds.midY.rounded())
            ctx.rotate(by: surface.rotation)
            if mirrored { ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(img, in: CGRect(x: (-w / 2).rounded(), y: (-h / 2).rounded(), width: w, height: h))
            ctx.restoreGState()
            return
        }
        if art.frames[frameName + "_shell"] != nil {
            // body, then the shell layer offset by its lag
            art.draw(frameName + "_body", in: bounds, scale: scale, context: ctx, squash: squash, mirrored: mirrored, lean: lean)
            ctx.saveGState()
            ctx.translateBy(x: shellOffset.x * scale, y: shellOffset.y * scale)
            art.draw(frameName + "_shell", in: bounds, scale: scale, context: ctx, squash: squash, mirrored: mirrored, lean: lean)
            ctx.restoreGState()
            return
        }
        art.draw(frameName, in: bounds, scale: scale, context: ctx, squash: squash, mirrored: mirrored, lean: lean)
    }

    /// The art pixel under a point in view coordinates is opaque.
    public func hitsArt(at p: NSPoint) -> Bool {
        let s = art.size(frameName)
        if surface != .floor {   // turned: anywhere on its body counts
            return hypot(p.x - bounds.midX, p.y - bounds.midY) < min(s.width, s.height) * scale * 0.45
        }
        let x0 = (bounds.midX - s.width * scale / 2).rounded(.down)
        let ax = Int(((p.x - x0) / scale).rounded(.down))
        let ay = Int(((s.height * scale - p.y) / scale).rounded(.down))  // art rows count from the top
        return art.isOpaque(frameName, x: ax, y: ay)
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hit = hitsArt(at: local)
        if Debug.enabled, let e = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(e.type) {
            Debug.log("frogg hitTest \(e.type == .leftMouseDown ? "down" : "right") at (\(Int(local.x)),\(Int(local.y))) frame=\(frameName) \(hit ? "HIT opaque pixel" : "MISS transparent")")
        }
        return hit ? self : nil
    }

    /// Where a hanging frame's pin (the toe pad held by the cursor) is, in view coordinates.
    public func pinPoint(_ name: String) -> NSPoint? {
        guard let f = art.frames[name], let pin = f.pin, pin.count == 2 else { return nil }
        let x0 = (bounds.midX - CGFloat(f.w) * scale / 2).rounded(.down)
        return NSPoint(x: x0 + (CGFloat(pin[0]) + 0.5) * scale, y: (CGFloat(f.h - pin[1]) - 0.5) * scale)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseDown(with event: NSEvent) {
        Debug.log("frogg down clickCount=\(event.clickCount)")
        onMouse?(.down, event)
    }
    public override func mouseDragged(with event: NSEvent) { onMouse?(.dragged, event) }
    public override func mouseUp(with event: NSEvent) {
        Debug.log("frogg up clickCount=\(event.clickCount)")
        onMouse?(.up, event)
    }
    public override func rightMouseDown(with event: NSEvent) {
        Debug.log("frogg right clickCount=\(event.clickCount)")
        onMouse?(.right, event)
    }
}

/// The speech bubble (SPEC §11.6) on the shared surface material: a rounded glass (or paper)
/// box with a tail toward the Pixl, bold monospace text, legible over any backdrop.
@MainActor
public final class BubbleView: NSView {
    public let text: String
    public let look: SurfaceView.Look
    let surface: SurfaceView
    static let font = Theme.mono(12, .bold)
    static let pad: CGFloat = 10
    static let tail: CGFloat = 9

    public init(text: String, look: SurfaceView.Look = .init(glass: false, variant: .light, dim: 1)) {
        self.text = text
        self.look = look
        // room on the edge where the Pixl's decal sits, so it never covers a word
        let r = DecalArt.reserve(PixlData.ui)
        let text0 = Self.size(for: text)
        let size = NSSize(width: text0.width + r.left + r.right, height: text0.height + r.top + r.bottom)
        let body = NSRect(x: 0, y: 0, width: size.width, height: size.height - Self.tail)
        surface = SurfaceView(frame: body, shape: .rounded(10), look: look)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Self.font
        label.textColor = look.textColor
        let textBox = NSRect(x: r.left, y: r.top, width: body.width - r.left - r.right, height: body.height - r.top - r.bottom)
        label.frame = textBox.insetBy(dx: Self.pad, dy: Self.pad - 2).offsetBy(dx: 0, dy: 1)
        surface.content.addSubview(label)
        DecalArt.attach(to: surface.content, ui: PixlData.ui, look: look)
        super.init(frame: NSRect(origin: .zero, size: size))
        appearance = look.appearance
        addSubview(surface)
        addSubview(BubbleTail(look: look, frame: NSRect(x: size.width / 2 - 9, y: body.height - 3, width: 18, height: Self.tail + 3)))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public static func size(for text: String, maxWidth: CGFloat = 300) -> NSSize {
        let r = (text as NSString).boundingRect(with: NSSize(width: maxWidth, height: 400), options: [.usesLineFragmentOrigin],
                                                attributes: [.font: font])
        return NSSize(width: ceil(r.width) + pad * 2 + 6, height: ceil(r.height) + pad * 2 + 3 + tail)
    }
}

/// The bubble's tail, in the same material colours as the surface.
@MainActor
final class BubbleTail: NSView {
    let look: SurfaceView.Look
    init(look: SurfaceView.Look, frame: NSRect) { self.look = look; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 1, y: 3))
        p.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        p.line(to: NSPoint(x: bounds.maxX - 1, y: 3))
        if look.glass {
            NSColor(rgb: Legibility.fill(look.variant)).withAlphaComponent(min(1, look.dim + 0.1)).setFill()
            p.fill()
        } else {
            Theme.paper.setFill()
            p.fill()
            Theme.ink.setStroke()
            let edge = NSBezierPath()
            edge.move(to: NSPoint(x: 1, y: 3))
            edge.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
            edge.line(to: NSPoint(x: bounds.maxX - 1, y: 3))
            edge.lineWidth = 2
            edge.stroke()
        }
    }
}
