import AppKit

/// The result panel: diff, verdict, the suggestion to drag into your text, and the
/// list of verification checks. Text reaches other apps only by the user dragging it
/// (or copying it): Pixl Memory never types or pastes (SPEC R4).
@MainActor
public final class PolishView: NSView {
    public enum Content {
        case result(PolishResult, instruction: String, app: String?)
        case error(MemoryError, app: String?)
    }

    public var onClose: (() -> Void)?
    public var onCopy: ((String) -> Void)?
    public var onReplace: ((PolishResult) -> Void)?
    public var onDropped: ((PolishResult) -> Void)?
    public var onResize: (() -> Void)?

    public static let width: CGFloat = 460
    let content: Content
    private let stack = NSStackView()
    private var details: NSView?
    private var detailsButton: PixelButton?

    /// On glass, the panel's SurfaceView draws the material; on paper this view draws its own card.
    public let look: SurfaceView.Look

    public init(_ content: Content, showDetails: Bool = false, look: SurfaceView.Look = .init(glass: false, variant: .light, dim: 1)) {
        self.content = content
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        appearance = look.appearance  // light or dark text, per the legibility pick
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset: CGFloat = 18
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - Theme.shadowOffset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset - Theme.shadowOffset),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        build(showDetails: showDetails)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        return  // the shared SurfaceView draws the material (glass or paper); see SurfaceView.card
        // AppKit-flipped view: the card's shadow goes down and right on screen.
        let card = NSRect(x: 0, y: 0, width: bounds.width - Theme.shadowOffset, height: bounds.height - Theme.shadowOffset)
        Theme.ink.setFill()
        NSBezierPath(rect: card.offsetBy(dx: Theme.shadowOffset, dy: Theme.shadowOffset)).fill()
        Theme.paper.setFill()
        NSBezierPath(rect: card).fill()
        Theme.ink.setStroke()
        let p = NSBezierPath(rect: card.insetBy(dx: Theme.border / 2, dy: Theme.border / 2))
        p.lineWidth = Theme.border
        p.stroke()
    }

    /// Lays out and sizes the view to fit its content.
    public func fit() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
        layoutSubtreeIfNeeded()
    }

    // MARK: building

    private var innerWidth: CGFloat { Self.width - 36 - Theme.shadowOffset }

    private func build(showDetails: Bool) {
        switch content {
        case .result(let r, let instruction, let app):
            let v = r.verification
            stack.addArrangedSubview(header(frame: v.verdict == "verified" ? "emotion_proud" : v.verdict == "partial" ? "emotion_curious" : "emotion_annoyed",
                                            title: title(for: instruction), subtitle: [app, v.model].compactMap { $0 }.joined(separator: " · ")))
            stack.addArrangedSubview(VerdictBadge(verification: v))
            stack.addArrangedSubview(wrapping(v.summary, font: .systemFont(ofSize: 12), color: Theme.textMuted))
            if let rc = r.receipt {
                let line = rc.status == "paid"
                    ? "\(PixlSkins.name) paid \(rc.amountNear ?? "?") Ⓝ to \(rc.to ?? "?") from its own testnet wallet"
                        + (rc.balanceAfterNear.map { " · \($0) Ⓝ left" } ?? "")
                    : rc.status == "pending"
                    ? "\(PixlSkins.name) sent \(rc.amountNear ?? "?") Ⓝ to \(rc.to ?? "?"): payment sent, confirming…"
                    : rc.bubble
                let ok = rc.status == "paid" || rc.status == "pending"   // pending: sent, may still land; not a failure
                let f = wrapping(line, font: Theme.mono(11, .bold), color: ok ? Theme.text : Theme.partial)
                if let link = rc.explorer, let url = URL(string: link) {
                    let a = NSMutableAttributedString(attributedString: f.attributedStringValue)
                    a.append(NSAttributedString(string: "  receipt ↗", attributes: [.link: url, .font: Theme.mono(11, .bold)]))
                    f.attributedStringValue = a
                    f.allowsEditingTextAttributes = true
                }
                stack.addArrangedSubview(f)
            }
            let stats = DiffText.stats(r.diff)
            stack.addArrangedSubview(caption("CHANGES  +\(stats.added) −\(stats.removed) words"))
            let diff = wrapping("", font: .systemFont(ofSize: 13), color: Theme.text)
            diff.attributedStringValue = DiffText.attributed(r.diff)
            stack.addArrangedSubview(diff)
            let card = SuggestionCard(text: r.suggestion, width: innerWidth)
            card.onDropped = { [weak self] in self?.onDropped?(r) }
            stack.addArrangedSubview(card)
            inspected = v
            let details = checksList(v.checks, deployment: v.deployment)
            inspected = nil
            self.details = details
            details.isHidden = !showDetails
            let copy = PixelButton(title: "Copy", primary: false) { [weak self] in self?.onCopy?(r.suggestion) }
            let more = PixelButton(title: showDetails ? "Hide checks" : "Show \(v.checks.count) checks", primary: false) { [weak self] in self?.toggleDetails() }
            detailsButton = more
            let replace = PixelButton(title: "Replace", primary: true) { [weak self] in self?.onReplace?(r) }
            let close = PixelButton(title: "Done", primary: false) { [weak self] in self?.onClose?() }
            stack.addArrangedSubview(buttonRow([replace, copy, more, close]))
            stack.addArrangedSubview(details)

        case .error(let e, let app):
            stack.addArrangedSubview(header(frame: "emotion_annoyed", title: e.bubble, subtitle: app ?? "Pixl Memory"))
            stack.addArrangedSubview(wrapping(e.detail, font: .systemFont(ofSize: 12), color: Theme.text))
            switch e {
            case .attestationFailed(_, let v?), .replyRejected(_, let v?):
                stack.addArrangedSubview(VerdictBadge(verification: v))
                inspected = v
                stack.addArrangedSubview(checksList(v.checks.filter { $0.status != "pass" }, deployment: nil))
                inspected = nil
            default: break
            }
            stack.addArrangedSubview(buttonRow([PixelButton(title: "OK", primary: true) { [weak self] in self?.onClose?() }]))
        }
    }

    private func title(for instruction: String) -> String {
        let t = instruction.split(separator: ":").first.map(String.init) ?? instruction
        return t.count > 34 ? String(t.prefix(33)) + "…" : t
    }

    private func toggleDetails() {
        guard let details else { return }
        details.isHidden.toggle()
        if case .result(let r, _, _) = content {
            detailsButton?.title = details.isHidden ? "Show \(r.verification.checks.count) checks" : "Hide checks"
        }
        fit()
        onResize?()
    }

    private func header(frame: String, title: String, subtitle: String) -> NSView {
        let img = NSImageView(image: FroggArt.shared.nsImage(frame, scale: 1) ?? NSImage())
        img.imageScaling = .scaleNone
        let t = NSTextField(labelWithString: title)
        t.font = Theme.mono(15, .bold)
        t.textColor = Theme.text
        let s = NSTextField(labelWithString: subtitle)
        s.font = Theme.mono(11)
        s.textColor = Theme.textMuted
        s.lineBreakMode = .byTruncatingMiddle
        let texts = NSStackView(views: [t, s])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let row = NSStackView(views: [img, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func caption(_ s: String) -> NSTextField {
        let c = NSTextField(labelWithString: s)
        c.font = Theme.mono(10, .bold)
        c.textColor = Theme.textMuted
        return c
    }

    private func wrapping(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = font
        f.textColor = color
        f.isSelectable = true
        f.preferredMaxLayoutWidth = innerWidth
        f.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        return f
    }

    private func buttonRow(_ buttons: [NSView]) -> NSView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    /// When set, checksList leads with the privacy inspector (trust path + plain words) for it.
    private var inspected: Verification?

    private func checksList(_ checks: [Check], deployment: String?) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        if let v = inspected {
            col.addArrangedSubview(caption(v.trust == "refused" ? "WHERE YOUR TEXT WOULD HAVE GONE" : "WHERE YOUR TEXT WENT"))
            let path = NSMutableAttributedString()
            for (i, h) in v.trustPath.enumerated() {
                let color = h.mark == "✔" ? Theme.verified : h.mark == "!" ? Theme.partial : h.mark == "✖" ? Theme.failed : Theme.textMuted
                if i > 0 { path.append(NSAttributedString(string: " → ", attributes: [.font: Theme.mono(10), .foregroundColor: Theme.textMuted])) }
                path.append(NSAttributedString(string: "\(h.mark) ", attributes: [.font: Theme.mono(11, .bold), .foregroundColor: color]))
                path.append(NSAttributedString(string: h.name, attributes: [.font: Theme.mono(10, .bold), .foregroundColor: Theme.text]))
            }
            let p = wrapping("", font: Theme.mono(10), color: Theme.text)
            p.attributedStringValue = path
            col.addArrangedSubview(p)
            col.addArrangedSubview(wrapping(v.plainWords, font: .systemFont(ofSize: 11), color: Theme.textMuted))
            col.addArrangedSubview(caption("CHECKS"))
        }
        for c in checks {
            let mark: String, color: NSColor
            switch c.status {
            case "pass": (mark, color) = ("✔", Theme.verified)
            case "warn": (mark, color) = ("!", Theme.partial)
            case "fail": (mark, color) = ("✖", Theme.failed)
            default: (mark, color) = ("–", Theme.textMuted)
            }
            let s = NSMutableAttributedString(string: "\(mark) ", attributes: [.font: Theme.mono(11, .bold), .foregroundColor: color])
            s.append(NSAttributedString(string: c.label, attributes: [.font: Theme.mono(11, .bold), .foregroundColor: Theme.text]))
            s.append(NSAttributedString(string: "  \(c.detail)", attributes: [.font: Theme.mono(10), .foregroundColor: Theme.textMuted]))
            let f = wrapping("", font: Theme.mono(11), color: Theme.text)
            f.attributedStringValue = s
            col.addArrangedSubview(f)
        }
        return col
    }
}

/// Verdict badge: green, amber or red block with the check count.
@MainActor
final class VerdictBadge: NSView {
    let text: String
    let color: NSColor

    init(verification v: Verification) {
        let mark = v.verdict == "verified" ? "✔" : v.verdict == "partial" ? "!" : "✖"
        text = "\(mark) \(v.badge.uppercased())  ·  \(v.passed)/\(v.checks.count) checks"
        color = v.verdict == "verified" ? Theme.verified : v.verdict == "partial" ? Theme.partial : Theme.failed
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let font = Theme.mono(12, .bold)

    override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(s.width) + 24, height: ceil(s.height) + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
        Theme.ink.setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        p.stroke()
        let s = (text as NSString).size(withAttributes: [.font: Self.font])
        (text as NSString).draw(at: NSPoint(x: 12, y: (bounds.height - s.height) / 2),
                                withAttributes: [.font: Self.font, .foregroundColor: NSColor.white])
    }
}

/// The suggestion, as a card the user drags into their text field.
@MainActor
final class SuggestionCard: NSView, NSDraggingSource {
    let text: String
    var onDropped: (() -> Void)?
    private var downEvent: NSEvent?

    init(text: String, width: CGFloat) {
        self.text = text
        super.init(frame: .zero)
        let cap = NSTextField(labelWithString: "⠿  DRAG INTO YOUR TEXT")
        cap.font = Theme.mono(10, .bold)
        cap.textColor = Theme.verified
        let body = NSTextField(wrappingLabelWithString: text)
        body.font = .systemFont(ofSize: 14)
        body.textColor = Theme.ink
        body.preferredMaxLayoutWidth = width - 28 - Theme.shadowOffset
        let col = NSStackView(views: [cap, body])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14 - Theme.shadowOffset),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12 - Theme.shadowOffset),
        ])
        toolTip = "Drag into the text field to insert it"
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel("Suggestion: \(text). Drag it into your text field.")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let o = Theme.shadowOffset
        let card = NSRect(x: 0, y: 0, width: bounds.width - o, height: bounds.height - o)
        Theme.accent.setFill()
        NSBezierPath(rect: card.offsetBy(dx: o, dy: o)).fill()
        NSColor.white.setFill()
        NSBezierPath(rect: card).fill()
        Theme.ink.setStroke()
        let p = NSBezierPath(rect: card.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = Theme.border
        p.stroke()
    }

    // The whole card is the drag handle, labels included.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        downEvent = event
        Debug.log("suggestion card down")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: text as NSString)
        let snapshot = bitmapImageRepForCachingDisplay(in: bounds).map { rep -> NSImage in
            cacheDisplay(in: bounds, to: rep)
            let img = NSImage(size: bounds.size)
            img.addRepresentation(rep)
            return img
        }
        item.setDraggingFrame(bounds, contents: snapshot)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Debug.log("suggestion drag ended operation=\(operation.rawValue)")
        if operation != [] { onDropped?() }
    }
}

/// Small pixel-style button: ink border, hard shadow.
@MainActor
final class PixelButton: NSView {
    /// C10 buttons: `.primary` (accent fill, hard drop), `.secondary` (chip), `.plain` (the × in headers).
    enum Style { case primary, secondary, plain }
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let style: Style
    /// A key hint drawn after the title ("↵").
    var hint: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let action: () -> Void
    private var pressed = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    var primary: Bool { style == .primary }

    init(title: String, primary: Bool, action: @escaping () -> Void) {
        let close = title == "✕" || title == "×"
        self.title = close ? "×" : title
        self.style = close ? .plain : (primary ? .primary : .secondary)
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(close ? "Close" : title)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    convenience init(title: String, style: Style, hint: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, primary: style == .primary, action: action)
        self.hint = hint
    }

    override func accessibilityPerformPress() -> Bool { action(); return true }
    required init?(coder: NSCoder) { fatalError("not used") }

    static let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let plainFont = Theme.mono(15, .bold)
    static let hintFont = Theme.mono(9)
    override var isFlipped: Bool { true }

    private var titleFont: NSFont { style == .plain ? Self.plainFont : Self.font }

    override var intrinsicContentSize: NSSize {
        let s = (title as NSString).size(withAttributes: [.font: titleFont])
        if style == .plain { return NSSize(width: 26, height: 26) }
        let h = hint.map { ($0 as NSString).size(withAttributes: [.font: Self.hintFont]).width + 8 } ?? 0
        return NSSize(width: ceil(s.width + h) + 26, height: 30 + 2)   // 5 × 11 padding, 2 pt line, 2 pt drop
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = MaterialTokens.forAppearance(effectiveAppearance)
        if style == .plain {
            if hovering || pressed {
                (pressed ? t.line : t.chip).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            }
            let s = (title as NSString).size(withAttributes: [.font: titleFont])
            (title as NSString).draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2 - 1),
                                     withAttributes: [.font: titleFont, .foregroundColor: hovering ? t.text : t.text2])
            return
        }
        let drop: CGFloat = style == .primary ? 2 : 0
        let sink: CGFloat = pressed ? drop : 0
        let face = NSRect(x: 1, y: 1 + sink, width: bounds.width - 2, height: bounds.height - 4)
        if style == .primary, !pressed {
            t.border.setFill()
            NSBezierPath(roundedRect: face.offsetBy(dx: 0, dy: drop), xRadius: 9, yRadius: 9).fill()
        }
        let p = NSBezierPath(roundedRect: face, xRadius: 9, yRadius: 9)
        let fill: NSColor
        if style == .primary {
            fill = hovering ? (Accent.color.blended(withFraction: 0.12, of: .white) ?? Accent.color) : Accent.color
        } else {
            fill = hovering ? t.line : t.chip
        }
        fill.setFill()
        p.fill()
        p.lineWidth = 2
        (style == .primary ? t.border : t.line).setStroke()
        p.stroke()
        let fg = style == .primary ? Accent.onAccent : t.text
        let s = (title as NSString).size(withAttributes: [.font: Self.font])
        var x = face.minX + 12
        if hint == nil { x = face.midX - s.width / 2 }
        (title as NSString).draw(at: NSPoint(x: x, y: face.midY - s.height / 2), withAttributes: [.font: Self.font, .foregroundColor: fg])
        if let hint {
            let hs = (hint as NSString).size(withAttributes: [.font: Self.hintFont])
            (hint as NSString).draw(at: NSPoint(x: x + s.width + 8, y: face.midY - hs.height / 2),
                                    withAttributes: [.font: Self.hintFont, .foregroundColor: fg.withAlphaComponent(0.75)])
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        Debug.log("button down \(title)")
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        Debug.log("button up \(title) inside=\(inside)")
        if inside { action() }
    }
}
