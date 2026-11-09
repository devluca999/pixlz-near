import AppKit
import PixlzCore

// The C12 Settings controls: pixel-drawn, keyboard-focusable (Tab moves, Space/Return acts,
// an accent ring shows focus) and labelled for VoiceOver.

/// Shared behaviour: focus, press with mouse or keyboard, an accent focus ring.
@MainActor
public class PixelControl: NSView {
    public var onPress: (() -> Void)?
    let look: SurfaceView.Look
    var hovering = false { didSet { needsDisplay = true } }
    var tokens: MaterialTokens { look.tokens }

    init(look: SurfaceView.Look, size: NSSize) {
        self.look = look
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        setAccessibilityElement(true)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var canBecomeKeyView: Bool { true }
    public override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override func mouseEntered(with event: NSEvent) { hovering = true }
    public override func mouseExited(with event: NSEvent) { hovering = false }
    public override func mouseDown(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { press() } }
    public override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { press() } else { super.keyDown(with: event) }   // Return, Space, Enter
    }
    public override func accessibilityPerformPress() -> Bool { press(); return true }
    func press() { onPress?() }
    var focused: Bool { window?.firstResponder === self }

    /// A pixel plate: hard 2 pt shadow, flat fill, 2 pt outline (accent when selected).
    func plate(_ r: NSRect, selected: Bool, fill: NSColor? = nil) {
        let s = r.insetBy(dx: 1, dy: 1)
        tokens.shadow.withAlphaComponent(look.glass ? 0.35 : 1).setFill()
        NSBezierPath(roundedRect: s.offsetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
        (fill ?? (selected ? Accent.color.blended(withFraction: look.variant == .dark ? 0.75 : 0.82, of: tokens.fill.withAlphaComponent(1)) ?? tokens.fill
                  : hovering ? tokens.chip.blended(withFraction: 0.5, of: tokens.fill.withAlphaComponent(1)) ?? tokens.fill : tokens.fill.withAlphaComponent(1))).setFill()
        let p = NSBezierPath(roundedRect: s, xRadius: 6, yRadius: 6); p.fill()
        p.lineWidth = 2
        (selected ? Accent.color : tokens.line).setStroke()
        p.stroke()
        if focused {
            let f = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 8, yRadius: 8)
            f.lineWidth = 2; f.setLineDash([3, 2], count: 2, phase: 0)
            Accent.color.setStroke(); f.stroke()
        }
    }

    func text(_ s: String, at p: NSPoint, font: NSFont, color: NSColor? = nil, center: CGFloat? = nil) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? tokens.text]
        var q = p
        if let c = center { q.x = c - (s as NSString).size(withAttributes: a).width / 2 }
        (s as NSString).draw(at: q, withAttributes: a)
    }
}

/// An on/off switch drawn in pixels.
@MainActor
public final class PixelToggle: PixelControl {
    public var isOn: Bool { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
    let title: String
    public init(_ title: String, on: Bool, look: SurfaceView.Look, width: CGFloat) {
        self.title = title
        isOn = on
        super.init(look: look, size: NSSize(width: width, height: 26))
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(on ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func press() { isOn.toggle(); super.press() }
    public override func draw(_ dirtyRect: NSRect) {
        text(title, at: NSPoint(x: 0, y: 4), font: .systemFont(ofSize: 13, weight: .medium))
        let r = NSRect(x: bounds.width - 40, y: 3, width: 38, height: 20)
        tokens.shadow.withAlphaComponent(look.glass ? 0.3 : 1).setFill(); NSRect(x: r.minX + 2, y: r.minY + 2, width: r.width, height: r.height).fill()
        (isOn ? Accent.color : tokens.chip.blended(withFraction: 0.6, of: tokens.fill.withAlphaComponent(1)) ?? tokens.fill).setFill(); r.fill()
        tokens.outline.setStroke(); let o = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)); o.lineWidth = 2; o.stroke()
        let knob = NSRect(x: isOn ? r.maxX - 18 : r.minX + 4, y: r.minY + 4, width: 14, height: 12)
        Theme.paper.setFill(); knob.fill()
        tokens.outline.setStroke(); let k = NSBezierPath(rect: knob.insetBy(dx: 1, dy: 1)); k.lineWidth = 2; k.stroke()
        if focused { Accent.color.setStroke(); let f = NSBezierPath(rect: r.insetBy(dx: -3, dy: -3)); f.lineWidth = 2; f.setLineDash([3, 2], count: 2, phase: 0); f.stroke() }
    }
}

/// A choice card: an icon, a title, a line under it (Calm / Roam / Chaos).
@MainActor
public final class ChoiceCard: PixelControl {
    public var selected: Bool { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
    let title: String, detail: String, glyph: String
    public init(_ title: String, detail: String, glyph: String, selected: Bool, look: SurfaceView.Look, width: CGFloat) {
        self.title = title; self.detail = detail; self.glyph = glyph; self.selected = selected
        super.init(look: look, size: NSSize(width: width, height: 62))
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(title): \(detail)")
        setAccessibilityValue(selected ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override func draw(_ dirtyRect: NSRect) {
        plate(bounds, selected: selected)
        text(glyph, at: NSPoint(x: 9, y: 7), font: Theme.mono(13, .bold), color: selected ? Accent.color : tokens.text)
        text(title, at: NSPoint(x: 27, y: 7), font: .systemFont(ofSize: 13, weight: .bold))
        let d = NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: tokens.text2])
        d.draw(with: NSRect(x: 9, y: 27, width: bounds.width - 16, height: 30), options: [.usesLineFragmentOrigin])
    }
}

/// One of a Pixl's frames, animated through its own idle slot (holds from its manifest, 12 fps
/// ticks). Only a floating Pixl (Boo) bobs.
@MainActor
public final class PetPreview: NSView {
    let skin: PixlSkins.Skin
    let scale: CGFloat
    var tick = 0
    var timer: Timer?
    var frame0 = "idle_0"
    public init(skin: PixlSkins.Skin, scale: CGFloat, size: NSSize) {
        self.skin = skin
        self.scale = scale
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { false }
    public override func viewDidMoveToWindow() {
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
    }
    /// The frame for tick `t`: idle_0…2 with the slot's holds (in 12 fps ticks), then a blink.
    public static func idleFrame(_ manifest: PixlManifest, tick t: Int) -> String {
        let holds = manifest.slots[.idle]?.holds ?? [6, 2, 8]
        let total = holds.reduce(0, +) + 2
        var k = t % max(total, 1)
        for (i, h) in holds.enumerated() { if k < h { return "idle_\(i)" }; k -= h }
        return "blink"
    }
    func step() {
        tick += 1
        let f = Self.idleFrame(skin.manifest, tick: tick)
        if f != frame0 || skin.manifest.movement == .float { frame0 = f; needsDisplay = true }
    }
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let art = skin.activeArt
        let name = art.frames[frame0] != nil ? frame0 : "idle_0"
        let bob = skin.manifest.movement == .float ? (2 * sin(Double(tick) / 12 * .pi)).rounded() : 0
        let r = bounds.offsetBy(dx: 0, dy: 4 + bob)
        art.draw(name, in: r, scale: scale, context: ctx, squash: CGSize(width: 1, height: 1), mirrored: false, lean: 0)
    }
}

/// A Pixl card in the picker: its own idle animation, its name, its accent; a check when picked.
@MainActor
public final class PetCard: PixelControl {
    public let skin: PixlSkins.Skin
    public var selected: Bool { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
    public init(skin: PixlSkins.Skin, selected: Bool, look: SurfaceView.Look) {
        self.skin = skin
        self.selected = selected
        super.init(look: look, size: NSSize(width: 58, height: 70))
        let art = skin.art.size("idle_0")
        let s = max(0.5, min(1, 46 / max(art.width, art.height) * 1))
        let pv = PetPreview(skin: skin, scale: s, size: NSSize(width: 54, height: 50))
        addSubview(pv)
        pv.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
        pv.topAnchor.constraint(equalTo: topAnchor, constant: 2).isActive = true
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(skin.manifest.name), \(skin.ui.description ?? skin.manifest.species)")
        setAccessibilityValue(selected ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override func draw(_ dirtyRect: NSRect) {
        plate(bounds, selected: selected)
        let c = RGB(hex: skin.ui.accent)
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
        NSRect(x: 8, y: bounds.height - 6, width: bounds.width - 16, height: 3).fill()
        text(skin.manifest.name, at: NSPoint(x: 0, y: bounds.height - 21), font: Theme.mono(9, .bold), center: bounds.midX)
        if selected {   // the check badge
            let b = NSRect(x: bounds.width - 15, y: 3, width: 12, height: 12)
            Accent.color.setFill(); NSBezierPath(ovalIn: b).fill()
            Accent.onAccent.setStroke()
            let p = NSBezierPath(); p.move(to: NSPoint(x: b.minX + 3, y: b.midY)); p.line(to: NSPoint(x: b.minX + 5, y: b.maxY - 3)); p.line(to: NSPoint(x: b.maxX - 2, y: b.minY + 3))
            p.lineWidth = 1.6; p.stroke()
        }
    }
}

/// A size step: the Pixl drawn at that size (scaled to fit), the letter and the multiplier.
@MainActor
public final class SizeCard: PixelControl {
    public let value: Double
    public var selected: Bool { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
    let letter: String
    public init(letter: String, value: Double, selected: Bool, look: SurfaceView.Look, width: CGFloat) {
        self.letter = letter; self.value = value; self.selected = selected
        super.init(look: look, size: NSSize(width: width, height: 64))
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(PixlScale.label(value))   // "3×": what the end-to-end test looks for
        setAccessibilityValue(selected ? 1 : 0)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override func draw(_ dirtyRect: NSRect) {
        plate(bounds, selected: selected)
        if let ctx = NSGraphicsContext.current?.cgContext {
            let art = FroggArt.shared, a = art.size("idle_0")
            let s = max(0.2, min(value / 5 * 0.55, 30 / max(a.height, 1)))   // bigger steps, bigger preview
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)   // the art draws y-up
            art.draw("idle_0", in: NSRect(x: 0, y: 26, width: bounds.width, height: 34), scale: s, context: ctx,
                     squash: CGSize(width: 1, height: 1), mirrored: false, lean: 0)
            ctx.restoreGState()
        }
        text(letter, at: .zero, font: Theme.mono(11, .bold), center: bounds.midX)
        text(PixlScale.label(value), at: NSPoint(x: 0, y: bounds.height - 15), font: Theme.mono(9), color: tokens.text2, center: bounds.midX)
    }
}

/// An alternate skin: a swatch of its accent, its name; selected or locked.
@MainActor
public final class SwatchCard: PixelControl {
    public let option: PixlSkinOption
    public var selected: Bool { didSet { needsDisplay = true; setAccessibilityValue(selected ? 1 : 0) } }
    public init(option: PixlSkinOption, selected: Bool, look: SurfaceView.Look) {
        self.option = option; self.selected = selected
        let w = max(64, (option.name as NSString).size(withAttributes: [.font: Theme.mono(9, .bold)]).width + 34)
        super.init(look: look, size: NSSize(width: w, height: 30))
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(option.name + (option.locked == true ? ", locked" : ""))
        setAccessibilityValue(selected ? 1 : 0)
        setAccessibilityEnabled(option.locked != true)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func press() { if option.locked != true { super.press() } }
    public override func draw(_ dirtyRect: NSRect) {
        plate(bounds, selected: selected)
        let c = RGB(hex: option.accent ?? "#999999")
        let sw = NSRect(x: 8, y: 9, width: 12, height: 12)
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: option.locked == true ? 0.45 : 1).setFill(); sw.fill()
        tokens.outline.setStroke(); let o = NSBezierPath(rect: sw.insetBy(dx: 0.5, dy: 0.5)); o.lineWidth = 1; o.stroke()
        text(option.name, at: NSPoint(x: 25, y: 8), font: Theme.mono(9, .bold), color: option.locked == true ? tokens.text2 : tokens.text)
        if option.locked == true {   // a little pixel padlock
            let x = bounds.width - 14, y: CGFloat = 9
            tokens.text2.setFill()
            NSRect(x: x, y: y + 5, width: 9, height: 7).fill()
            NSRect(x: x + 1, y: y, width: 2, height: 5).fill(); NSRect(x: x + 6, y: y, width: 2, height: 5).fill(); NSRect(x: x + 1, y: y, width: 7, height: 2).fill()
        }
    }
}

/// A key cap (⌃⌥P): drawn like a pixel key.
@MainActor
public final class Keycap: NSView {
    let key: String, look: SurfaceView.Look
    public init(_ key: String, look: SurfaceView.Look) {
        self.key = key; self.look = look
        let w = (key as NSString).size(withAttributes: [.font: Theme.mono(11, .bold)]).width + 14
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: w).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(key)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        let t = look.tokens, r = bounds.insetBy(dx: 1, dy: 1)
        t.shadow.withAlphaComponent(look.glass ? 0.35 : 1).setFill(); NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: r.height - 2).fill()
        t.fill.withAlphaComponent(1).setFill(); NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 3).fill()
        t.outline.setStroke(); let o = NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 3)); o.lineWidth = 1.5; o.stroke()
        (key as NSString).draw(at: NSPoint(x: 7, y: 2), withAttributes: [.font: Theme.mono(11, .bold), .foregroundColor: t.text])
    }
}

/// A collapsible row: ▸/▾, an icon, a title, a summary on the right; the content shows when open.
@MainActor
public final class DisclosureRow: PixelControl {
    public var open: Bool { didSet { needsDisplay = true; content.isHidden = !open; setAccessibilityExpanded(open); onToggle?() } }
    public var onToggle: (() -> Void)?
    public let content: NSView
    let title: String, icon: String
    var summary: String { didSet { needsDisplay = true } }
    public init(_ title: String, icon: String, summary: String, content: NSView, open: Bool, look: SurfaceView.Look, width: CGFloat) {
        self.title = title; self.icon = icon; self.summary = summary; self.content = content; self.open = open
        super.init(look: look, size: NSSize(width: width, height: 30))
        content.isHidden = !open
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title)
        setAccessibilityExpanded(open)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    public func setSummary(_ s: String) { summary = s }
    override func press() { open.toggle(); super.press() }
    public override func draw(_ dirtyRect: NSRect) {
        if hovering || focused { tokens.chip.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        if focused { Accent.color.setStroke(); let f = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6); f.lineWidth = 2; f.setLineDash([3, 2], count: 2, phase: 0); f.stroke() }
        // a pixel chevron
        tokens.text.setFill()
        for i in 0..<4 {
            if open { NSRect(x: 8 + CGFloat(i) * 2, y: 12 + CGFloat(min(i, 3 - i)) * 2, width: 2, height: 2).fill() }
            else { NSRect(x: 9 + CGFloat(min(i, 3 - i)) * 2, y: 9 + CGFloat(i) * 2, width: 2, height: 2).fill() }
        }
        if let img = BubbleIcons.image(icon, dark: look.variant == .dark, scale: 1.5) { img.draw(in: NSRect(x: 22, y: 6, width: 18, height: 18)) }
        text(title, at: NSPoint(x: 46, y: 6), font: .systemFont(ofSize: 13, weight: .bold))
        let a: [NSAttributedString.Key: Any] = [.font: Theme.mono(10), .foregroundColor: tokens.text2]
        let room = bounds.width - 60 - (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]).width
        let s = NSAttributedString(string: summary, attributes: a)
        let w = min(s.size().width, room)
        s.draw(with: NSRect(x: bounds.width - w - 6, y: 8, width: w, height: 16), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }
}
