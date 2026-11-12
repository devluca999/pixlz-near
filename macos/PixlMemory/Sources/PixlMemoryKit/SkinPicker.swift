import AppKit
import PixlzCore

/// Pick a Pixl: one tile per skin with its idle frame, name, species and accent. Used in the
/// More ▸ "Change Pixl" card and in settings. Click, or ←/→ and Return; Esc closes the card.
@MainActor
public final class SkinPickerView: NSView {
    public var onPick: ((String) -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) var selected: String
    public private(set) var focusIndex: Int?
    let tiles: [SkinTile]
    public static let tileSize = NSSize(width: 92, height: 112)

    /// - Parameter compact: smaller tiles without species (settings).
    public init(selected: String, look: SurfaceView.Look, compact: Bool = false) {
        self.selected = selected
        let size = compact ? NSSize(width: 64, height: 78) : Self.tileSize
        tiles = PixlSkins.all.map { SkinTile(skin: $0, size: size, look: look, compact: compact) }
        let gap: CGFloat = 8
        let perRow = compact ? tiles.count : min(tiles.count, 3)
        let rows = Int(ceil(Double(tiles.count) / Double(perRow)))
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(perRow) * size.width + CGFloat(perRow - 1) * gap,
                                 height: CGFloat(rows) * size.height + CGFloat(rows - 1) * gap))
        for (i, t) in tiles.enumerated() {
            t.frame.origin = NSPoint(x: CGFloat(i % perRow) * (size.width + gap), y: CGFloat(i / perRow) * (size.height + gap))
            t.onPress = { [weak self] in self?.pick(i) }
            t.onHover = { [weak self] inside in if inside { self?.setFocus(nil) } }
            t.isCurrent = t.skin.id == selected
            addSubview(t)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Choose a Pixl")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var intrinsicContentSize: NSSize { frame.size }
    public override func accessibilityChildren() -> [Any]? { tiles }

    /// Centre of tile `i`, in this view's coordinates.
    public func center(of i: Int) -> NSPoint? { tiles.indices.contains(i) ? NSPoint(x: tiles[i].frame.midX, y: tiles[i].frame.midY) : nil }
    public func index(of id: String) -> Int? { tiles.firstIndex { $0.skin.id == id } }

    public func pick(_ i: Int) {
        guard tiles.indices.contains(i) else { return }
        selected = tiles[i].skin.id
        tiles.forEach { $0.isCurrent = $0.skin.id == selected }
        Debug.log("skin picked \(selected)")
        onPick?(selected)
    }

    public func setFocus(_ i: Int?) {
        focusIndex = i
        for (j, t) in tiles.enumerated() { t.focused = j == i }
    }

    public override func keyDown(with event: NSEvent) {
        let cur = focusIndex ?? index(of: selected) ?? 0
        switch event.keyCode {
        case 123, 126: setFocus((cur - 1 + tiles.count) % tiles.count)   // ← ↑
        case 124, 125, 48: setFocus((cur + 1) % tiles.count)              // → ↓ Tab
        case 36, 76, 49: pick(focusIndex ?? cur)                          // Return Enter Space
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
    public override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class SkinTile: NSView {
    let skin: PixlSkins.Skin
    let look: SurfaceView.Look
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var isCurrent = false { didSet { needsDisplay = true; setAccessibilityValue(isCurrent ? "selected" : nil) } }
    var focused = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var down = false { didSet { needsDisplay = true } }
    var accent: NSColor { let c = RGB(hex: skin.ui.accent); return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    init(skin: PixlSkins.Skin, size: NSSize, look: SurfaceView.Look, compact: Bool) {
        self.skin = skin
        self.look = look
        super.init(frame: NSRect(origin: .zero, size: size))
        // the preview: idle frame, scaled to fit, nearest-neighbour
        let art = skin.art.size("idle_0")
        let box = NSSize(width: size.width - 12, height: size.height - (compact ? 22 : 40))
        let k = max(1, floor(min(box.width / art.width, box.height / art.height)))
        let img = NSImageView(image: skin.art.nsImage("idle_0", scale: k) ?? NSImage())
        img.imageScaling = .scaleNone
        img.frame = NSRect(x: (size.width - art.width * k) / 2, y: 6 + (box.height - art.height * k), width: art.width * k, height: art.height * k)
        addSubview(img)
        let name = NSTextField(labelWithString: skin.manifest.name)
        name.font = compact ? Theme.mono(9, .bold) : Theme.mono(11, .bold)
        name.textColor = look.textColor
        name.alignment = .center
        name.frame = NSRect(x: 2, y: size.height - (compact ? 16 : 34), width: size.width - 4, height: 14)
        addSubview(name)
        if !compact {
            let sp = NSTextField(labelWithString: skin.manifest.ui?.description ?? skin.manifest.species)
            sp.font = Theme.mono(9)
            sp.textColor = look.mutedColor
            sp.alignment = .center
            sp.lineBreakMode = .byTruncatingTail
            sp.frame = NSRect(x: 2, y: size.height - 19, width: size.width - 4, height: 12)
            addSubview(sp)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(skin.manifest.name), \(skin.manifest.ui?.description ?? skin.manifest.species)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        let base: NSColor = look.tokens.plate ?? look.tokens.chip
        (down ? base.blended(withFraction: 0.12, of: .black) ?? base : hovering ? base.blended(withFraction: 0.08, of: accent) ?? base : base).setFill()
        p.fill()
        // the accent bar along the bottom: the Pixl's colour
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX + 8, y: r.maxY - 4, width: r.width - 16, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        if isCurrent || focused {
            p.lineWidth = isCurrent ? 2.5 : 2
            (isCurrent ? accent : Theme.accent).setStroke()
            p.stroke()
        } else {
            p.lineWidth = 1
            look.tokens.line.setStroke()
            p.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; down = false }
    override func mouseDown(with event: NSEvent) { down = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        down = false
        if inside { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// The Pixl's menu detail (C10): a few pixels on the edge of its surfaces.
@MainActor
public enum DecalArt {
    public static func image(_ d: PixlDecal, accent: String, look: SurfaceView.Look, scale: CGFloat = 2) -> NSImage? {
        let h = d.grid.count, w = d.grid.map(\.count).max() ?? 0
        guard w > 0, h > 0 else { return nil }
        func color(_ ch: Character) -> NSColor? {
            switch ch {
            case ".": return nil
            // outline and fill follow the surface, so the detail shows on dark cards too
            case "k": return look.glass ? NSColor.white.withAlphaComponent(0.92) : look.tokens.outline
            case "f": return look.glass ? NSColor.white.withAlphaComponent(0.34) : (look.variant == .dark ? Theme.ink : Theme.paper)
            default:
                let hex = d.colors[String(ch)] ?? accent
                let c = RGB(hex: hex)
                return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            }
        }
        let img = NSImage(size: NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale), flipped: true) { _ in
            for (y, row) in d.grid.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = color(ch) else { continue }
                    c.setFill()
                    NSRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale).fill()
                }
            }
            return true
        }
        return img
    }

    /// Room to leave for the decal so it never sits on text: a strip along the edge it sits on.
    public static func reserve(_ ui: PixlUI) -> NSEdgeInsets {
        guard let d = ui.decal else { return NSEdgeInsets() }
        let h = CGFloat(d.grid.count) * 2
        if let t = d.pos["top"] { return NSEdgeInsets(top: h + max(3, t) - 4, left: 0, bottom: 0, right: 0) }
        return NSEdgeInsets(top: 0, left: 0, bottom: h + max(3, d.pos["bottom"] ?? 0) - 4, right: 0)
    }

    /// Adds the decal to `view` (flipped). `pos` is a margin from the edges, so the whole
    /// decal sits inside the surface: nothing is ever cut off by the rounded border.
    public static func attach(to view: NSView, ui: PixlUI, look: SurfaceView.Look) {
        guard let d = ui.decal, let img = DecalArt.image(d, accent: ui.accent, look: look) else { return }
        let iv = NSImageView(image: img)
        iv.imageScaling = .scaleNone
        let s = img.size, b = view.bounds
        var x = (b.width - s.width) / 2, y: CGFloat = 0
        if let l = d.pos["left"] { x = max(4, l) }
        if let r = d.pos["right"] { x = b.width - s.width - max(4, r) }
        if let t = d.pos["top"] { y = max(3, t) } else { y = b.height - s.height - max(3, d.pos["bottom"] ?? 0) }
        iv.frame = NSRect(x: x.rounded(), y: y.rounded(), width: s.width, height: s.height)
        // it stays on its edge when the surface grows (an Ask card once its answer lands). The view
        // is flipped, so the flexible margin for a bottom decal is the one above it.
        var pin: NSView.AutoresizingMask = []
        if d.pos["top"] == nil { pin.insert(view.isFlipped ? .minYMargin : .maxYMargin) }
        if d.pos["right"] != nil { pin.insert(.minXMargin) } else if d.pos["left"] == nil { pin.insert([.minXMargin, .maxXMargin]) }
        iv.autoresizingMask = pin
        iv.setAccessibilityElement(false)
        view.addSubview(iv)
    }
}

/// More ▸ Change Pixl: the picker on the shared surface.
@MainActor
public final class SkinCard: PixlCard {
    public let picker: SkinPickerView
    public init(selected: String, look: SurfaceView.Look) {
        picker = SkinPickerView(selected: selected, look: look)
        super.init(title: "Choose a Pixl", icon: "settings", look: look)
        picker.widthAnchor.constraint(equalToConstant: picker.frame.width).isActive = true
        picker.heightAnchor.constraint(equalToConstant: picker.frame.height).isActive = true
        stack.addArrangedSubview(picker)
        stack.addArrangedSubview(text("Memory, wallet, settings and position carry over.", size: 11, muted: true))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
