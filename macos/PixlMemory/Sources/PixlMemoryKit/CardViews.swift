import AppKit

extension SurfaceView {
    /// Puts a card's content on the shared surface material (glass or paper), sized to fit.
    public static func card(_ content: NSView, look: Look) -> SurfaceView {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize.width > 0 ? content.fittingSize : content.frame.size
        let s = SurfaceView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + (look.glass ? 0 : 3)),
                            shape: .rounded(16), look: look)
        content.frame = NSRect(origin: .zero, size: size)
        s.content.addSubview(content)
        s.setAccessibilityElement(true)
        s.setAccessibilityRole(.group)
        return s
    }
}

/// Shared card scaffolding: a header (icon, title, close) and a vertical stack, text in the
/// surface's colours. Subclasses fill `stack`.
@MainActor
public class PixlCard: NSView {
    public let look: SurfaceView.Look
    public var onClose: (() -> Void)?
    let stack = NSStackView()
    static let width: CGFloat = 340
    var inner: CGFloat { Self.width - 32 }

    init(title: String, icon: String?, look: SurfaceView.Look) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        appearance = look.appearance
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        var header: [NSView] = []
        if let icon, let img = BubbleIcons.image(icon, dark: look.glass && look.variant == .dark) { header.append(NSImageView(image: img)) }
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 15, weight: .bold)
        t.textColor = Theme.text
        header.append(t)
        header.append(NSView())
        let close = PixelButton(title: "✕", primary: false) { [weak self] in self?.onClose?() }
        header.append(close)
        let row = NSStackView(views: header)
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(row)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }

    func text(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, muted: Bool = false, mono: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = mono ? Theme.mono(size, weight) : .systemFont(ofSize: size, weight: weight)
        f.textColor = muted ? Theme.textMuted : Theme.text
        f.preferredMaxLayoutWidth = inner
        f.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        return f
    }

    func buttons(_ b: [NSView]) -> NSView {
        let r = NSStackView(views: b)
        r.spacing = 10
        return r
    }

    public func fit() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }
}

/// Wallet bubble: Frogg's NEAR balance, caps and recent receipts (C8 slot 3).
@MainActor
public final class WalletCard: PixlCard {
    public var onOpenURL: ((URL) -> Void)?
    public var onSetup: (() -> Void)?

    public init(info: WalletInfo?, payments: [Receipt], look: SurfaceView.Look) {
        super.init(title: "Frogg's wallet", icon: "wallet", look: look)
        guard let info else {
            stack.addArrangedSubview(text("The Pixl Memory service isn't running.", muted: true))
            return
        }
        if let account = info.account { stack.addArrangedSubview(text(account, size: 11, muted: true, mono: true)) }
        if info.ready == true, let bal = info.balanceNear {
            stack.addArrangedSubview(text("\(bal) Ⓝ", size: 26, weight: .bold))
            if let c = info.caps {
                stack.addArrangedSubview(text("Spent today \(info.spentTodayNear ?? "0") of \(c.perDayNear) Ⓝ · at most \(c.perRequestNear) Ⓝ a request · \(c.reserveNear) Ⓝ kept in reserve",
                                              size: 11, muted: true))
            }
            if let payee = info.payee { stack.addArrangedSubview(text("Pays \(payee) for its private inference (testnet).", size: 11, muted: true)) }
        } else {
            stack.addArrangedSubview(text(info.setup ?? "Not set up yet.", size: 12))
        }
        if !payments.isEmpty {
            stack.addArrangedSubview(text("RECEIPTS", size: 10, weight: .bold, muted: true, mono: true))
            for p in payments.prefix(4) {
                let line = p.status == "paid" ? "Paid \(p.amountNear ?? "?") Ⓝ" : "\(p.status.capitalized): \(p.reason ?? "")"
                if let link = p.explorer, let url = URL(string: link) {
                    stack.addArrangedSubview(PixelButton(title: "\(line)  ↗", primary: false) { [weak self] in self?.onOpenURL?(url) })
                } else {
                    stack.addArrangedSubview(text(line, size: 12))
                }
            }
        }
        var b: [NSView] = []
        if info.ready != true { b.append(PixelButton(title: "Set up wallet", primary: true) { [weak self] in self?.onSetup?() }) }
        if let e = info.explorer, let url = URL(string: e) {
            b.append(PixelButton(title: "Explorer ↗", primary: info.ready == true) { [weak self] in self?.onOpenURL?(url) })
        }
        if !b.isEmpty { stack.addArrangedSubview(buttons(b)) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Memory bubble: saved highlights, newest first; each opens its page at the passage.
@MainActor
public final class MemoryCard: PixlCard, NSSearchFieldDelegate {
    public var onOpenURL: ((URL) -> Void)?
    let all: [HighlightItem]
    let list = NSStackView()
    let search = NSSearchField()

    public init(highlights: [HighlightItem], look: SurfaceView.Look) {
        all = highlights
        super.init(title: "Memory", icon: "memory", look: look)
        search.placeholderString = "Search \(highlights.count) highlights"
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: inner).isActive = true
        search.setAccessibilityLabel("Search highlights")
        stack.addArrangedSubview(search)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        stack.addArrangedSubview(list)
        render(highlights)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render(_ items: [HighlightItem]) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if all.isEmpty {
            list.addArrangedSubview(text("Nothing saved yet. In Chrome, select text → right-click → Save to Pixl Memory.", size: 12, muted: true))
            return
        }
        if items.isEmpty { list.addArrangedSubview(text("No matches.", size: 12, muted: true)) }
        for h in items.prefix(6) {
            let snippet = h.text.count > 110 ? String(h.text.prefix(108)) + "…" : h.text
            let source = h.title ?? h.url.flatMap { URL(string: $0)?.host } ?? "Saved text"
            let row = HighlightRow(snippet: snippet, source: source, width: inner) { [weak self] in
                if let u = h.link { self?.onOpenURL?(u) }
            }
            list.addArrangedSubview(row)
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        let q = search.stringValue.lowercased()
        render(q.isEmpty ? all : all.filter { $0.text.lowercased().contains(q) || ($0.title ?? "").lowercased().contains(q) })
        fit()
    }
}

/// One clickable highlight in the Memory card.
@MainActor
final class HighlightRow: NSView {
    let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var down = false

    init(snippet: String, source: String, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let t = NSTextField(wrappingLabelWithString: snippet)
        t.font = .systemFont(ofSize: 12)
        t.textColor = Theme.text
        t.preferredMaxLayoutWidth = width - 16
        let s = NSTextField(labelWithString: "\(source) ↗")
        s.font = Theme.mono(10)
        s.textColor = Theme.textMuted
        let col = NSStackView(views: [t, s])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel("\(snippet), from \(source)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.text.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { down = true }
    override func mouseUp(with event: NSEvent) {
        if down, bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
        down = false
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// Ask bubble: a question for the Pixl, answered privately in a TEE, with the verdict.
@MainActor
public final class AskCard: PixlCard, NSTextFieldDelegate {
    public var onAsk: ((String) -> Void)?
    public let field = NSTextField()
    let answer: NSTextField
    let status: NSTextField
    var askButton: PixelButton!

    public init(placeholder: String, look: SurfaceView.Look) {
        answer = NSTextField(wrappingLabelWithString: "")
        status = NSTextField(labelWithString: "")
        super.init(title: "Ask", icon: "ask", look: look)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: inner).isActive = true
        field.setAccessibilityLabel("Question for Frogg")
        stack.addArrangedSubview(field)
        askButton = PixelButton(title: "Ask privately", primary: true) { [weak self] in self?.submit() }
        status.font = Theme.mono(10)
        status.textColor = Theme.textMuted
        stack.addArrangedSubview(buttons([askButton, status]))
        answer.font = .systemFont(ofSize: 13)
        answer.textColor = Theme.text
        answer.preferredMaxLayoutWidth = inner
        answer.isSelectable = true
        answer.isHidden = true
        stack.addArrangedSubview(answer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func submit() {
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        status.stringValue = "Checking the enclave…"
        Debug.log("ask submitted (\(q.count) chars)")
        onAsk?(q)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        return false
    }

    public func show(_ r: AskResult) {
        answer.stringValue = r.answer
        answer.isHidden = false
        let v = r.verification
        status.stringValue = (v.verdict == "verified" ? "✔ " : "! ") + "\(v.badge) · \(v.passed)/\(v.checks.count)" + (r.receipt.map { " · " + $0.bubble } ?? "")
        status.textColor = v.verdict == "verified" ? Theme.verified : v.verdict == "partial" ? Theme.partial : Theme.failed
        fit()
    }

    public func show(error e: MemoryError) {
        answer.stringValue = e.detail
        answer.isHidden = false
        status.stringValue = e.bubble
        status.textColor = Theme.failed
        fit()
    }
}
