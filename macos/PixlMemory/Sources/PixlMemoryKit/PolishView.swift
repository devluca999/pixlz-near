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
    public var onDropped: ((PolishResult) -> Void)?
    public var onResize: (() -> Void)?

    public static let width: CGFloat = 460
    let content: Content
    private let stack = NSStackView()
    private var details: NSView?
    private var detailsButton: PixelButton?

    public init(_ content: Content, showDetails: Bool = false) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        appearance = NSAppearance(named: .aqua)  // paper-and-ink design: always light, even in dark mode
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
            stack.addArrangedSubview(wrapping(v.summary, font: .systemFont(ofSize: 12), color: Theme.muted))
            if let rc = r.receipt {
                let line = rc.status == "paid"
                    ? "🐸 Frogg paid \(rc.amountNear ?? "?") Ⓝ to \(rc.to ?? "?") from its own testnet wallet"
                        + (rc.balanceAfterNear.map { " · \($0) Ⓝ left" } ?? "")
                    : "🐸 " + rc.bubble
                let f = wrapping(line, font: Theme.mono(11, .bold), color: rc.status == "paid" ? Theme.ink : Theme.partial)
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
            let diff = wrapping("", font: .systemFont(ofSize: 13), color: Theme.ink)
            diff.attributedStringValue = DiffText.attributed(r.diff)
            stack.addArrangedSubview(diff)
            let card = SuggestionCard(text: r.suggestion, width: innerWidth)
            card.onDropped = { [weak self] in self?.onDropped?(r) }
            stack.addArrangedSubview(card)
            let details = checksList(v.checks, deployment: v.deployment)
            self.details = details
            details.isHidden = !showDetails
            let copy = PixelButton(title: "Copy", primary: false) { [weak self] in self?.onCopy?(r.suggestion) }
            let more = PixelButton(title: showDetails ? "Hide checks" : "Show \(v.checks.count) checks", primary: false) { [weak self] in self?.toggleDetails() }
            detailsButton = more
            let close = PixelButton(title: "Done", primary: true) { [weak self] in self?.onClose?() }
            stack.addArrangedSubview(buttonRow([copy, more, close]))
            stack.addArrangedSubview(details)

        case .error(let e, let app):
            stack.addArrangedSubview(header(frame: "emotion_annoyed", title: e.bubble, subtitle: app ?? "Pixl Memory"))
            stack.addArrangedSubview(wrapping(e.detail, font: .systemFont(ofSize: 12), color: Theme.ink))
            if case .attestationFailed(_, let v?) = e {
                stack.addArrangedSubview(VerdictBadge(verification: v))
                stack.addArrangedSubview(checksList(v.checks.filter { $0.status != "pass" }, deployment: nil))
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
        t.textColor = Theme.ink
        let s = NSTextField(labelWithString: subtitle)
        s.font = Theme.mono(11)
        s.textColor = Theme.muted
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
        c.textColor = Theme.muted
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

    private func checksList(_ checks: [Check], deployment: String?) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        for c in checks {
            let mark: String, color: NSColor
            switch c.status {
            case "pass": (mark, color) = ("✔", Theme.verified)
            case "warn": (mark, color) = ("!", Theme.partial)
            case "fail": (mark, color) = ("✖", Theme.failed)
            default: (mark, color) = ("–", Theme.muted)
            }
            let s = NSMutableAttributedString(string: "\(mark) ", attributes: [.font: Theme.mono(11, .bold), .foregroundColor: color])
            s.append(NSAttributedString(string: c.label, attributes: [.font: Theme.mono(11, .bold), .foregroundColor: Theme.ink]))
            s.append(NSAttributedString(string: "  \(c.detail)", attributes: [.font: Theme.mono(10), .foregroundColor: Theme.muted]))
            let f = wrapping("", font: Theme.mono(11), color: Theme.ink)
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
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let primary: Bool
    let action: () -> Void
    private var pressed = false

    init(title: String, primary: Bool, action: @escaping () -> Void) {
        self.title = title
        self.primary = primary
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static let font = Theme.mono(12, .bold)
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let s = (title as NSString).size(withAttributes: [.font: Self.font])
        return NSSize(width: ceil(s.width) + 28 + 3, height: ceil(s.height) + 14 + 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        let o: CGFloat = pressed ? 1 : 3
        let card = NSRect(x: pressed ? 2 : 0, y: pressed ? 2 : 0, width: bounds.width - 3, height: bounds.height - 3)
        Theme.ink.setFill()
        NSBezierPath(rect: NSRect(x: 3, y: 3, width: bounds.width - 3, height: bounds.height - 3)).fill()
        (primary ? Theme.accent : NSColor.white).setFill()
        NSBezierPath(rect: card).fill()
        Theme.ink.setStroke()
        let p = NSBezierPath(rect: card.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        p.stroke()
        _ = o
        let s = (title as NSString).size(withAttributes: [.font: Self.font])
        (title as NSString).draw(at: NSPoint(x: card.midX - s.width / 2, y: card.midY - s.height / 2),
                                 withAttributes: [.font: Self.font, .foregroundColor: Theme.ink])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
        Debug.log("button down \(title)")
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        Debug.log("button up \(title) inside=\(inside)")
        if inside { action() }
    }
}
