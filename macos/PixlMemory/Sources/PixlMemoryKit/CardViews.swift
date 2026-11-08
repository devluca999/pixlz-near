import AppKit

extension SurfaceView {
    /// Puts a card's content on the shared surface material (glass or paper), sized to fit.
    public static func card(_ content: NSView, look: Look) -> SurfaceView {
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize.width > 0 ? content.fittingSize : content.frame.size
        // room on the edge where the Pixl's decal sits (top or bottom), so it never covers a control
        let r = DecalArt.reserve(PixlData.ui)
        let s = SurfaceView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + r.top + r.bottom + (look.glass ? 0 : 3)),
                            shape: .rounded(16), look: look)
        content.frame = NSRect(origin: NSPoint(x: 0, y: r.top), size: size)
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
    /// The user picked a weekly limit (NEAR, as text).
    public var onSetLimit: ((String) -> Void)?
    /// Pause (true) or resume (false) all spending.
    public var onPause: ((Bool) -> Void)?

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
        if !ready { stack.addArrangedSubview(text(info.setup ?? "Not set up yet.", size: 12)) }
        if info.paused == true {
            stack.addArrangedSubview(text("Spending is paused. \(PixlData.manifest.name) won't pay for anything until you resume.", size: 12, weight: .semibold))
        }
        // this week: spent against the user's weekly limit
        if let c = info.caps, let week = c.perWeekNear {
            let spent = Double(info.spentWeekNear ?? "0") ?? 0, limit = Double(week) ?? 0
            stack.addArrangedSubview(caption("THIS WEEK", look: look))
            stack.addArrangedSubview(MeterView(fraction: limit > 0 ? spent / limit : 0, look: look, width: inner))
            stack.addArrangedSubview(text("\(info.spentWeekNear ?? "0") of \(week) NEAR · today \(info.spentTodayNear ?? "0") of \(c.perDayNear) · ≤ \(c.perRequestNear) a request · resets Monday",
                                          size: 11, muted: true))
            // the weekly limit: presets up to the owner's ceiling
            let ceiling = Double(info.ceilings?.perWeekNear ?? week) ?? limit
            let presets = ["0.05", "0.1", "0.25", "0.5", "1"].filter { (Double($0) ?? 0) <= ceiling + 1e-9 }
            var chips: [NSView] = [caption("WEEKLY LIMIT", look: look)]
            for v in presets {
                let on = abs((Double(v) ?? 0) - limit) < 1e-9
                let b = PixelButton(title: v, style: on ? .primary : .secondary) { [weak self] in self?.onSetLimit?(v) }
                b.setAccessibilityLabel("Weekly limit \(v) NEAR\(on ? ", selected" : "")")
                chips.append(b)
            }
            let row = NSStackView(views: chips)
            row.spacing = 6
            row.alignment = .centerY
            stack.addArrangedSubview(row)
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
        let paused = info.paused == true
        b.append(PixelButton(title: paused ? "Resume" : "Pause", style: paused ? .primary : .secondary) { [weak self] in self?.onPause?(!paused) })
        if let e = info.explorer, let url = URL(string: e) {
            b.append(PixelButton(title: ready ? "Receipts ↗" : "Explorer ↗", style: .secondary) { [weak self] in self?.onOpenURL?(url) })
        }
        setFooter(b, hint: "testnet")
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
    /// Save a note: (text, folder). The app writes it and reopens the card.
    public var onSaveNote: ((String, String?) -> Void)?
    let all: [HighlightItem]
    let list = NSStackView()
    public let search: PixlField
    let folderRow = NSStackView()
    public private(set) var folder: String?
    var query = ""
    var composer: PixlField?

    public init(highlights: [HighlightItem], look: SurfaceView.Look) {
        all = highlights
        search = PixlField(placeholder: highlights.isEmpty ? "Nothing to search yet" : "Search \(highlights.count) highlights",
                           icon: "search", look: look, label: "Search highlights")
        super.init(title: "Memory", icon: "memory", look: look)
        search.widthAnchor.constraint(equalToConstant: inner).isActive = true
        search.onChange = { [weak self] q in self?.filter(q) }
        search.onEscape = { [weak self] in self?.onClose?() }
        stack.addArrangedSubview(search)
        // folders: All, then every folder path (subfolders shown as "Parent › Child")
        folderRow.spacing = 6
        folderRow.alignment = .centerY
        let names = Array(Set(highlights.compactMap(\.folder))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if !names.isEmpty {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasHorizontalScroller = false
            scroll.documentView = folderRow
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: 34).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: inner).isActive = true
            folderRow.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(scroll)
            renderFolders(names)
        }
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        stack.addArrangedSubview(list)
        render(highlights)
        let note = PixelButton(title: "+ Note", style: .secondary) { [weak self] in self?.startNote() }
        note.setAccessibilityLabel("New note")
        setFooter([note], hint: highlights.isEmpty ? "encrypted on this Mac" : "click one to reopen it")
    }

    var folderNames: [String] = []
    func renderFolders(_ names: [String]) {
        folderNames = names
        folderRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for name in [nil] + names.map(Optional.some) {
            let label = name.map { $0.replacingOccurrences(of: "/", with: " › ") } ?? "All"
            let on = name == folder
            let chip = PixelButton(title: label, style: on ? .primary : .secondary) { [weak self] in self?.choose(folder: name) }
            chip.setAccessibilityLabel("Folder \(label)\(on ? ", selected" : "")")
            folderRow.addArrangedSubview(chip)
        }
        folderRow.layoutSubtreeIfNeeded()
        folderRow.setFrameSize(folderRow.fittingSize)
    }

    public func choose(folder f: String?) {
        folder = f
        renderFolders(folderNames)
        filter(query)
    }

    /// A one-line composer for a note or a to-do, saved into the current folder (or "Notes").
    func startNote() {
        guard composer == nil else { window?.makeFirstResponder(composer?.field); return }
        let c = PixlField(placeholder: "A note, a to-do… ↵ to save", icon: "memory", look: look, label: "New note")
        c.widthAnchor.constraint(equalToConstant: inner).isActive = true
        c.onReturn = { [weak self, weak c] in
            guard let self, let text = c?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            Debug.log("note saved (\(text.count) chars) to \(self.folder ?? "Notes")")
            self.onSaveNote?(text, self.folder ?? "Notes")
        }
        c.onEscape = { [weak self] in self?.composer?.removeFromSuperview(); self?.composer = nil; self?.fit() }
        stack.insertArrangedSubview(c, at: 1)
        composer = c
        fit()
        window?.makeFirstResponder(c.field)
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
        query = q
        let q = q.lowercased()
        let inFolder = folder.map { f in all.filter { $0.folder == f || ($0.folder ?? "").hasPrefix(f + "/") } } ?? all
        render(q.isEmpty ? inFolder : inFolder.filter { $0.text.lowercased().contains(q) || ($0.title ?? "").lowercased().contains(q) })
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
        lastQuestion = q
        hint.stringValue = "checking the enclave…"
        hint.textColor = tokens.text2
        Debug.log("ask submitted (\(q.count) chars)")
        onAsk?(q)
    }

    /// Save the answer into memory (folder "Answers"), with its sources' links.
    public var onSaveAnswer: ((String, String, [HighlightItem]) -> Void)?
    /// Hand the answer to another app's text field (the app shows a list of apps).
    public var onHandOff: ((String) -> Void)?
    var lastQuestion = ""

    public func show(_ r: AskResult) {
        answer.stringValue = r.answer
        answer.isHidden = false
        let saveB = PixelButton(title: "Save answer", style: .secondary) { [weak self] in
            guard let self else { return }
            self.onSaveAnswer?(self.lastQuestion, r.answer, r.highlights ?? [])
        }
        let hand = PixelButton(title: "Hand off ▸", style: .secondary) { [weak self] in self?.onHandOff?(r.answer) }
        hand.setAccessibilityLabel("Hand off to another app")
        setFooter([saveB, hand], hint: nil)
        let v = r.verification
        // the verdict sits under the answer (the footer is for the buttons)
        sources.forEach { $0.removeFromSuperview() }
        sources = []
        let verdict = text((v.verdict == "verified" ? "✔ " : "! ") + "\(v.badge)" + (v.checks.isEmpty ? "" : " · \(v.passed)/\(v.checks.count) checks") + (r.receipt.map { " · " + $0.bubble } ?? ""),
                           size: 10, weight: .bold, mono: true)
        verdict.textColor = v.verdict == "verified" ? Theme.verified : v.verdict == "partial" ? Theme.partial : Theme.failed
        stack.addArrangedSubview(verdict)
        sources.append(verdict)
        hint.stringValue = ""
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

    /// An answer the Mac knew itself (screens, devices, "jump to…"): no model, nothing sent.
    public func showLocal(_ text: String) {
        answer.stringValue = text
        answer.isHidden = false
        hint.stringValue = "answered on this Mac · nothing sent"
        hint.textColor = tokens.text2
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

/// A slim progress bar in the Pixl's accent (turns the failure colour when the limit is reached).
@MainActor
final class MeterView: NSView {
    let fraction: Double
    let look: SurfaceView.Look
    init(fraction: Double, look: SurfaceView.Look, width: CGFloat) {
        self.fraction = min(max(fraction, 0), 1)
        self.look = look
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityValue("\(Int((self.fraction * 100).rounded())) percent of the weekly limit")
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 0.5)
        look.tokens.chip.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        guard fraction > 0 else { return }
        (fraction >= 0.999 ? Theme.failed : Accent.color).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: max(8, r.width * fraction), height: r.height), xRadius: 4, yRadius: 4).fill()
    }
}
