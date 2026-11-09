import AppKit

/// A notice card (SPEC §11.6): a small card in the Menus & Bubbles material with a pixel icon and
/// plain English, optionally led by one of the Pixl's own sounds. Never used for the Pixl's voice.
@MainActor
public final class NoticeView: NSView {
    public let notice: Notice
    public let voiceLine: String?
    let surface: SurfaceView
    static let maxText: CGFloat = 250

    public init(_ notice: Notice, voice: String? = nil, look: SurfaceView.Look) {
        self.notice = notice
        self.voiceLine = voice
        let tokens = look.tokens
        // the text, wrapped to a comfortable width
        let text = NSTextField(wrappingLabelWithString: notice.text)
        text.font = .systemFont(ofSize: 12.5, weight: .medium)
        text.textColor = tokens.text
        text.preferredMaxLayoutWidth = Self.maxText
        let textSize = text.sizeThatFits(NSSize(width: Self.maxText, height: 400))
        let icon = NSImageView(image: BubbleIcons.image(notice.icon, dark: look.variant == .dark, scale: 1.5) ?? NSImage())
        var voiceField: NSTextField?
        var voiceH: CGFloat = 0
        if let voice {
            let v = NSTextField(labelWithString: voice)
            v.font = Theme.mono(12, .bold)
            v.textColor = Accent.color
            voiceField = v
            voiceH = 18
        }
        let pad: CGFloat = 10, iconW: CGFloat = 18
        let w = pad + iconW + 8 + ceil(min(textSize.width, Self.maxText)) + pad
        let h = pad + voiceH + max(iconW, ceil(textSize.height)) + pad
        let r = DecalArt.reserve(PixlData.ui)
        surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: w, height: h + r.top + r.bottom + (look.glass ? 0 : 3)), shape: .rounded(10), look: look)
        super.init(frame: surface.frame)
        appearance = look.appearance
        addSubview(surface)
        var y = r.top + pad
        if let v = voiceField {
            v.frame = NSRect(x: pad, y: y - 1, width: w - 2 * pad, height: 16)
            surface.content.addSubview(v)
            y += voiceH
        }
        icon.frame = NSRect(x: pad, y: y, width: iconW, height: iconW)
        surface.content.addSubview(icon)
        text.frame = NSRect(x: pad + iconW + 8, y: y + (textSize.height < iconW ? (iconW - textSize.height) / 2 : 0), width: ceil(textSize.width) + 2, height: ceil(textSize.height))
        surface.content.addSubview(text)
        DecalArt.attach(to: surface.content, ui: PixlData.ui, look: look)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(notice.text)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }
}
