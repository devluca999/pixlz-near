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
        DecalArt.attach(to: s.content, ui: PixlData.ui, look: look)  // the Pixl's own detail (C10)
        s.setAccessibilityElement(true)
        s.setAccessibilityRole(.group)
        return s
    }
}

/// Shared card scaffolding (C10 `.card`): a header plate (grip, pixel icon, title, ×), a body
/// plate (`stack`), and an optional footer plate (buttons on the left, a hint on the right).
/// Text sits on plates; on Liquid Glass (the ghost) the plates are 80 % paper or ink.
@MainActor
public class PixlCard: NSView {
    public let look: SurfaceView.Look
    public var onClose: (() -> Void)?
    let stack = NSStackView()
    let footer = NSStackView()
    let hint = NSTextField(labelWithString: "")
    private let column = NSStackView()
    private var footerPlate: PlateView!
    static let width: CGFloat = 340
    /// Width of text inside the body plate.
    var inner: CGFloat { Self.width - 10 - 20 }
    var tokens: MaterialTokens { look.tokens }

    init(title: String, icon: String?, look: SurfaceView.Look) {
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        appearance = look.appearance
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        // header: grip · icon · title · ×
        var h: [NSView] = [GripView(color: tokens.text2)]
        if let icon, let img = BubbleIcons.image(icon, dark: look.variant == .dark, scale: 1.5) { h.append(NSImageView(image: img)) }
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .bold)
        t.textColor = tokens.text
        h.append(t)
        h.append(NSView())
        h.append(PixelButton(title: "×", primary: false) { [weak self] in self?.onClose?() })
        let hrow = NSStackView(views: h)
        hrow.spacing = 8
        hrow.alignment = .centerY
        let hp = PlateView.wrap(hrow, look: look, padding: NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 4))
        column.addArrangedSubview(hp)
        hp.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // body
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let bp = PlateView.wrap(stack, look: look, padding: NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10))
        column.addArrangedSubview(bp)
        bp.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        // footer (hidden until something goes in it)
        footer.spacing = 8
        footer.alignment = .centerY
        hint.font = Theme.mono(9)
        hint.textColor = tokens.text2
        hint.lineBreakMode = .byTruncatingTail
        let frow = NSStackView(views: [footer, NSView(), hint])
        frow.alignment = .centerY
        footerPlate = PlateView.wrap(frow, look: look, padding: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 10))
        column.addArrangedSubview(footerPlate)
        footerPlate.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        footerPlate.isHidden = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }

    /// Buttons and a hint in the footer plate.
    func setFooter(_ buttons: [NSView], hint text: String? = nil) {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach { footer.addArrangedSubview($0) }
        hint.stringValue = text ?? ""
        footerPlate.isHidden = buttons.isEmpty && (text ?? "").isEmpty
    }

    func text(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, muted: Bool = false, mono: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = mono ? Theme.mono(size, weight) : .systemFont(ofSize: size, weight: weight)
        f.textColor = muted ? tokens.text2 : tokens.text
        f.preferredMaxLayoutWidth = inner
        f.widthAnchor.constraint(lessThanOrEqualToConstant: inner).isActive = true
        return f
    }

    func buttons(_ b: [NSView]) -> NSView {
        let r = NSStackView(views: b)
        r.spacing = 8
        return r
    }

    /// A hairline between rows (C10 `.rc` top border).
    func rule() -> NSView {
        let v = RuleView(color: tokens.line)
        v.widthAnchor.constraint(equalToConstant: inner).isActive = true
        v.heightAnchor.constraint(equalToConstant: 2).isActive = true
        return v
    }

    public func fit() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }
}

@MainActor
final class RuleView: NSView {
    let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

/// Wallet bubble (C10 `.wl`): the Pixl's NEAR balance, big; recent receipts as rows; caps.
@MainActor
public final class WalletCard: PixlCard {
    public var onOpenURL: ((URL) -> Void)?
    public var onSetup: (() -> Void)?

    public init(info: WalletInfo?, payments: [Receipt], look: SurfaceView.Look) {
        super.init(title: "Wallet · \(PixlData.manifest.name)", icon: "wallet", look: look)
        guard let info else {
            stack.addArrangedSubview(text("The Pixl Memory service isn't running.", muted: true))
            setFooter([], hint: "start it: make -C memory serve")
            return
        }
        let ready = info.ready == true
        // the balance, C10 style: big pixel numerals, small unit
        let big = NSMutableAttributedString(string: ready ? (info.balanceNear ?? "—") : "—",
                                            attributes: [.font: Theme.mono(26, .bold), .foregroundColor: tokens.text])
        big.append(NSAttributedString(string: "  NEAR", attributes: [.font: Theme.mono(11), .foregroundColor: tokens.text2]))
        let bal = NSTextField(labelWithAttributedString: big)
        stack.addArrangedSubview(bal)
        if let account = info.account { stack.addArrangedSubview(text(account, size: 10, muted: true, mono: true)) }
        if ready, let c = info.caps {
            stack.addArrangedSubview(text("Spent today \(info.spentTodayNear ?? "0") of \(c.perDayNear) · at most \(c.perRequestNear) a request · \(c.reserveNear) kept in reserve",
                                          size: 11, muted: true))
        } else if !ready {
            stack.addArrangedSubview(text(info.setup ?? "Not set up yet.", size: 12))
        }
        for p in payments.prefix(4) {
            stack.addArrangedSubview(rule())
            let paid = p.status == "paid"
            let row = ReceiptRow(icon: paid ? "polish" : "hide", title: paid ? "Private inference" : "\(p.status.capitalized): \(p.reason ?? "")",
                                 amount: paid ? "−\(p.amountNear ?? "?")" : "", look: look, width: inner) { [weak self] in
                if let e = p.explorer, let u = URL(string: e) { self?.onOpenURL?(u) }
            }
            stack.addArrangedSubview(row)
        }
        var b: [NSView] = []
        if !ready { b.append(PixelButton(title: "Set up wallet", style: .primary, hint: "↵") { [weak self] in self?.onSetup?() }) }
        if let e = info.explorer, let url = URL(string: e) {
            b.append(PixelButton(title: ready ? "All receipts →" : "Explorer ↗", style: .secondary) { [weak self] in self?.onOpenURL?(url) })
        }
        setFooter(b, hint: ready ? "testnet · pays its own inference" : "testnet")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One receipt: icon, what it was, the amount on the right; opens the transaction.
@MainActor
final class ReceiptRow: NSView {
    let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    let look: SurfaceView.Look

    init(icon: String, title: String, amount: String, look: SurfaceView.Look, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        self.look = look
        super.init(frame: .zero)
        let t = look.tokens
        let iv = NSImageView(image: BubbleIcons.image(icon, dark: look.variant == .dark, scale: 1.5) ?? NSImage())
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12.5, weight: .medium); l.textColor = t.text; l.lineBreakMode = .byTruncatingTail
        let a = NSTextField(labelWithString: amount)
        a.font = Theme.mono(10); a.textColor = t.text
        let row = NSStackView(views: [iv, l, NSView(), a])
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel("\(title) \(amount)")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        look.tokens.chip.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// Memory bubble: saved highlights, newest first; each opens its page at the passage.
@MainActor
public final class MemoryCard: PixlCard {
    public var onOpenURL: ((URL) -> Void)?
    let all: [HighlightItem]
    let list = NSStackView()
    public let search: PixlField

    public init(highlights: [HighlightItem], look: SurfaceView.Look) {
        all = highlights
        search = PixlField(placeholder: highlights.isEmpty ? "Nothing to search yet" : "Search \(highlights.count) highlights",
                           icon: "search", look: look, label: "Search highlights")
        super.init(title: "Memory", icon: "memory", look: look)
        search.widthAnchor.constraint(equalToConstant: inner).isActive = true
        search.onChange = { [weak self] q in self?.filter(q) }
        search.onEscape = { [weak self] in self?.onClose?() }
        stack.addArrangedSubview(search)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        stack.addArrangedSubview(list)
        render(highlights)
        setFooter([], hint: highlights.isEmpty ? "encrypted on this Mac" : "click one to reopen the page there")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func render(_ items: [HighlightItem]) {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if all.isEmpty {
            list.addArrangedSubview(text("Nothing saved yet", size: 13, weight: .semibold))
            list.addArrangedSubview(text("In Chrome, select a passage and press ⌥⇧S (or right-click ▸ Save to Pixl Memory). It's saved here, encrypted, with a link back to that exact spot.", size: 12, muted: true))
            return
        }
        if items.isEmpty { list.addArrangedSubview(text("No matches.", size: 12, muted: true)) }
        for h in items.prefix(6) {
            let snippet = h.text.count > 110 ? String(h.text.prefix(108)) + "…" : h.text
            let source = h.title ?? h.url.flatMap { URL(string: $0)?.host } ?? "Saved text"
            list.addArrangedSubview(HighlightRow(snippet: snippet, source: source, look: look, width: inner) { [weak self] in
                if let u = h.link { self?.onOpenURL?(u) }
            })
        }
    }

    func filter(_ q: String) {
        let q = q.lowercased()
        render(q.isEmpty ? all : all.filter { $0.text.lowercased().contains(q) || ($0.title ?? "").lowercased().contains(q) })
        fit()
    }
}

/// One clickable highlight: an accent bar, the passage, where it's from.
@MainActor
final class HighlightRow: NSView {
    let action: () -> Void
    let look: SurfaceView.Look
    private var hovering = false { didSet { needsDisplay = true } }
    private var down = false

    init(snippet: String, source: String, look: SurfaceView.Look, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        self.look = look
        super.init(frame: .zero)
        let tk = look.tokens
        let t = NSTextField(wrappingLabelWithString: snippet)
        t.font = .systemFont(ofSize: 12.5)
        t.textColor = tk.text
        t.preferredMaxLayoutWidth = width - 22
        let s = NSTextField(labelWithString: "\(source)  ↗")
        s.font = Theme.mono(9)
        s.textColor = tk.text2
        let col = NSStackView(views: [t, s])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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
        let tk = look.tokens
        if hovering {
            tk.chip.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        (hovering ? Accent.color : tk.line).setFill()   // the quote bar
        NSBezierPath(roundedRect: NSRect(x: 3, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
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

/// Ask bubble: a question for the Pixl, answered privately in an attested TEE, with the
/// verdict and the saved highlights it used (each a backlink).
@MainActor
public final class AskCard: PixlCard {
    public var onAsk: ((String) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    public let input: PixlField
    /// The text field itself (for first responder).
    public var field: NSTextField { input.field }
    let answer: NSTextField
    var askButton: PixelButton!
    var sources: [NSView] = []

    public init(placeholder: String, look: SurfaceView.Look) {
        input = PixlField(placeholder: placeholder, icon: "ask", look: look, label: "Question for \(PixlData.manifest.name)")
        answer = NSTextField(wrappingLabelWithString: "")
        super.init(title: "Ask \(PixlData.manifest.name)", icon: "ask", look: look)
        input.widthAnchor.constraint(equalToConstant: inner).isActive = true
        input.onReturn = { [weak self] in self?.submit() }
        input.onEscape = { [weak self] in self?.onClose?() }
        stack.addArrangedSubview(input)
        answer.font = .systemFont(ofSize: 13.5)
        answer.textColor = tokens.text
        answer.preferredMaxLayoutWidth = inner
        answer.isSelectable = true
        answer.isHidden = true
        stack.addArrangedSubview(answer)
        askButton = PixelButton(title: "Ask privately", style: .primary, hint: "↵") { [weak self] in self?.submit() }
        setFooter([askButton], hint: "attested before it's sent")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func submit() {
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        hint.stringValue = "checking the enclave…"
        hint.textColor = tokens.text2
        Debug.log("ask submitted (\(q.count) chars)")
        onAsk?(q)
    }

    public func show(_ r: AskResult) {
        answer.stringValue = r.answer
        answer.isHidden = false
        let v = r.verification
        hint.stringValue = (v.verdict == "verified" ? "✔ " : "! ") + "\(v.badge) · \(v.passed)/\(v.checks.count)" + (r.receipt.map { " · " + $0.bubble } ?? "")
        hint.textColor = v.verdict == "verified" ? Theme.verified : v.verdict == "partial" ? Theme.partial : Theme.failed
        sources.forEach { $0.removeFromSuperview() }
        sources = []
        if let hs = r.highlights, !hs.isEmpty {
            let cap = caption("FROM YOUR HIGHLIGHTS", look: look)
            stack.addArrangedSubview(cap)
            sources.append(cap)
            for h in hs.prefix(3) {
                let source = h.title ?? h.url.flatMap { URL(string: $0)?.host } ?? "Saved text"
                let row = HighlightRow(snippet: h.text.count > 140 ? String(h.text.prefix(140)) + "…" : h.text, source: source, look: look, width: inner) { [weak self] in
                    if let link = h.link { Debug.log("ask: open backlink"); self?.onOpenURL?(link) }
                }
                stack.addArrangedSubview(row)
                sources.append(row)
            }
        }
        fit()
    }

    public func show(error e: MemoryError) {
        answer.stringValue = e.detail
        answer.isHidden = false
        hint.stringValue = e.bubble
        hint.textColor = Theme.failed
        fit()
    }
}
