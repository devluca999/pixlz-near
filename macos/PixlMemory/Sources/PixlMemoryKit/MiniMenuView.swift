import AppKit
import PixlzCore

/// Settings (design C12): a header with the Pixl's own idle animation, its name (rename), its
/// description, its status line and alternate skins; then Pet, Size, Behavior, and collapsible
/// Focus, Shortcuts, Privacy & Memory and Wallet. Every change applies at once. Keyboard: Tab
/// moves between controls, Space/Return acts, Esc closes. On the shared card material.
@MainActor
public final class MiniMenuView: NSView, NSTextFieldDelegate {
    public enum Section: String { case focus, shortcuts, privacy, wallet }

    public var onChange: ((PixlSettings) -> Void)?
    public var onClose: (() -> Void)?
    public var onOpenWallet: (() -> Void)?
    public var onOpenMemory: (() -> Void)?
    public var onAdjustSize: (() -> Void)?
    /// A section opened or closed: the panel should take the new height.
    public var onResize: (() -> Void)?
    public private(set) var settings: PixlSettings
    public static let width: CGFloat = 432

    private let stack = NSStackView()
    private var closeButton: NSView?
    private var nameField: NSTextField!
    private var appsField: NSTextField!
    private var verifiedLabel: NSTextField!
    private var privacyRow: DisclosureRow!
    private var walletRow: DisclosureRow!
    private var privacyBody: NSStackView!
    private var walletBody: NSStackView!
    private var petCards: [PetCard] = []
    private var sizeCards: [SizeCard] = []
    private var choice: [ChoiceCard] = []
    private var swatches: [SwatchCard] = []
    private var firstControl: NSView?

    /// Centre of the ✕ button in this view's coordinates (for the app's self-test).
    public var closeButtonCenter: NSPoint? {
        guard let b = closeButton else { return nil }
        layoutSubtreeIfNeeded()
        return convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), from: b)
    }

    public let look: SurfaceView.Look
    /// The Pixl's status line ("Frogg is practicing his croak."), under its name.
    let statusLine: String?
    let openSection: Section?

    public init(settings: PixlSettings, status: ServiceStatus, look: SurfaceView.Look = .init(glass: false, variant: .light, dim: 1),
                statusLine: String? = nil, open: Section? = nil) {
        self.settings = settings
        self.statusLine = statusLine
        self.look = look
        self.openSection = open
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        appearance = look.appearance
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        build(status)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    public override var isFlipped: Bool { true }

    public func fit() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    /// The control the keyboard starts on.
    public var initialFocus: NSView? { firstControl }

    private var inner: CGFloat { Self.width - 36 }
    private var t: MaterialTokens { look.tokens }

    // MARK: building

    private func build(_ status: ServiceStatus) {
        // title bar: "Settings" and ✕
        let title = label("Settings", Theme.mono(13, .bold), t.text)
        let close = PixelButton(title: "✕", primary: false) { [weak self] in self?.onClose?() }
        closeButton = close
        close.setAccessibilityLabel("Close settings")
        stack.addArrangedSubview(row([title, NSView(), close], width: inner))

        // header: the Pixl's own idle animation, name, description, status, skins, privacy
        let skin = PixlSkins.current
        let a = skin.activeArt.size("idle_0")
        let tile = TileView(look: look, size: NSSize(width: 118, height: 100))
        let pv = PetPreview(skin: skin, scale: max(0.5, min(1.4, 80 / max(a.width, a.height))), size: NSSize(width: 110, height: 92))
        tile.addSubview(pv)
        pv.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 4).isActive = true
        pv.topAnchor.constraint(equalTo: tile.topAnchor, constant: 2).isActive = true

        nameField = NSTextField(string: settings.name)
        nameField.font = .systemFont(ofSize: 20, weight: .bold)
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.textColor = t.text
        nameField.delegate = self
        nameField.placeholderString = "Name"
        nameField.setAccessibilityLabel("Name")
        nameField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let rename = PixelButton(title: "✎ Rename", primary: false) { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.nameField)
            self.nameField.currentEditor()?.selectAll(nil)
        }
        let nameRow = NSStackView(views: [nameField, rename]); nameRow.spacing = 4
        var col: [NSView] = [nameRow, label(skin.ui.description ?? skin.manifest.species, .systemFont(ofSize: 12), t.text2, width: 270)]
        if let statusLine { col.append(label(statusLine, .systemFont(ofSize: 12, weight: .medium), t.text, width: 270)) }
        verifiedLabel = label("", Theme.mono(10, .bold), Theme.verified, width: 270)
        col.append(verifiedLabel)
        let nameCol = NSStackView(views: col); nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 3
        stack.addArrangedSubview(row([tile, nameCol], width: inner, spacing: 12))

        // alternate skins (in place of a raw colour): small swatches, selected and locked
        if let options = skin.ui.skins, !options.isEmpty {
            stack.addArrangedSubview(section("ALTERNATE SKINS"))
            let chosen = settings.looks?[settings.skinID] ?? "default"
            swatches = options.map { o in
                let c = SwatchCard(option: o, selected: o.id == chosen, look: look)
                c.onPress = { [weak self] in
                    guard let self else { return }
                    var l = self.settings.looks ?? [:]
                    l[self.settings.skinID] = o.id
                    self.settings.looks = l
                    self.swatches.forEach { $0.selected = $0.option.id == o.id }
                    self.changed()
                }
                return c
            }
            let wrap = NSStackView(views: swatches); wrap.spacing = 6
            stack.addArrangedSubview(wrap)
        }

        // Pet: every Pixl with its own idle animation; picking one puff-swaps it
        stack.addArrangedSubview(section("PET"))
        petCards = PixlSkins.all.map { s in
            let c = PetCard(skin: s, selected: s.id == settings.skinID, look: look)
            c.onPress = { [weak self] in
                guard let self else { return }
                self.settings.skin = s.id
                self.petCards.forEach { $0.selected = $0.skin.id == s.id }
                self.changed()
            }
            return c
        }
        let pets = NSStackView(views: petCards); pets.spacing = 4
        stack.addArrangedSubview(pets)
        firstControl = petCards.first { $0.selected }

        // Size: S M L XL steps, or resize on screen
        stack.addArrangedSubview(row([section("SIZE"), NSView(), linkButton("⤡ Resize on screen…") { [weak self] in self?.onAdjustSize?() }], width: inner))
        let steps: [(String, Double)] = [("S", 2), ("M", 3), ("L", 4), ("XL", 5)]
        let cw = (inner - 3 * 6) / 4
        sizeCards = steps.map { l, v in
            let c = SizeCard(letter: l, value: v, selected: settings.scale == v, look: look, width: cw)
            c.onPress = { [weak self] in
                guard let self else { return }
                self.settings.scale = v
                self.sizeCards.forEach { $0.selected = $0.value == v }
                self.changed()
            }
            return c
        }
        let sizes = NSStackView(views: sizeCards); sizes.spacing = 6
        stack.addArrangedSubview(sizes)

        // Behavior: Calm / Roam / Chaos, then toggles
        stack.addArrangedSubview(section("BEHAVIOR"))
        let b = settings.behavior ?? "calm"
        let w3 = (inner - 2 * 6) / 3
        choice = [("Calm", "Stays put, naps a lot", "☾", "calm"), ("Roam", "Wanders and perches", "⁘", "roam"), ("Chaos", "Roam plus mischief", "ϟ", "chaos")].map { title, d, g, id in
            let c = ChoiceCard(title, detail: d, glyph: g, selected: b == id, look: look, width: w3)
            c.onPress = { [weak self] in
                guard let self else { return }
                self.settings.behavior = id
                self.choice.forEach { $0.selected = $0 === c }
                self.changed()
            }
            return c
        }
        let ch = NSStackView(views: choice); ch.spacing = 6
        stack.addArrangedSubview(ch)
        stack.addArrangedSubview(toggle("Perch on the window I'm using", settings.perchOnWindows) { [weak self] on in self?.settings.perchOnWindows = on })
        stack.addArrangedSubview(toggle("Hide when an app goes fullscreen", settings.hideInFullscreen) { [weak self] on in self?.settings.hideInFullscreen = on })
        stack.addArrangedSubview(toggle("Let me wake them by hovering", settings.hoverWakes ?? false) { [weak self] on in self?.settings.hoverWakes = on })
        let sleepiness = settings.sleepiness ?? "normal"
        var sleepyButtons: [PixelButton] = []
        sleepyButtons = [("Night owl", "nightOwl"), ("Normal", "normal"), ("Sleepy", "sleepy")].map { title, id in
            PixelButton(title: title, primary: sleepiness == id) { [weak self] in
                self?.settings.sleepiness = id
                self?.changed()
            }
        }
        stack.addArrangedSubview(row([label("Sleepiness", .systemFont(ofSize: 13, weight: .medium), t.text), NSView()] + sleepyButtons, width: inner, spacing: 4))

        // Focus (collapsed)
        appsField = NSTextField(string: settings.distractingApps.joined(separator: ", "))
        appsField.placeholderString = "Distracting apps, e.g. Safari, Slack, Music"
        appsField.font = .systemFont(ofSize: 12)
        appsField.delegate = self
        appsField.widthAnchor.constraint(equalToConstant: inner - 24).isActive = true
        let focusBody = bodyStack([label("Focus nudges you gently when one of these comes to the front.", .systemFont(ofSize: 12), t.text2, width: inner - 24), appsField])
        let apps = settings.distractingApps.count
        addRow("Focus", icon: "search", summary: apps == 0 ? "No distracting apps" : "\(apps) distracting app\(apps == 1 ? "" : "s")", body: focusBody, open: openSection == .focus)

        // Shortcuts (collapsed): pixel keycaps
        let keys: [(String, String)] = [("⌃⌥P", "Open Settings"), ("⌃⌥Space", "Ask"), ("⌃⌥H", "Hide or show")]
        let keyRows = keys.map { k, what in row([Keycap(k, look: look), label(what, .systemFont(ofSize: 12), t.text)], width: inner - 24, spacing: 8) }
        addRow("Shortcuts", icon: "more", summary: "⌃⌥P settings · ⌃⌥Space ask", body: bodyStack(keyRows), open: openSection == .shortcuts)

        // Privacy & Memory (collapsed): model, where it runs, last attestation, highlights
        privacyBody = bodyStack([])
        privacyRow = addRow("Privacy & Memory", icon: "memory", summary: "", body: privacyBody, open: openSection == .privacy)

        // Wallet (collapsed)
        walletBody = bodyStack([])
        walletRow = addRow("Wallet", icon: "wallet", summary: "", body: walletBody, open: openSection == .wallet)
        update(status: status)
    }

    /// Fills in service, privacy and wallet details in place (Settings opens before they're known).
    public func update(status: ServiceStatus) {
        let verified = status.lastVerdict?.lowercased().contains("verified") == true && status.lastVerdict?.lowercased().contains("not") == false
        verifiedLabel.stringValue = status.service == "running" ? (verified ? "■ Private · verified (NEAR AI TEE)" : "■ Private · checks the enclave before sending")
                                                               : "■ Memory service: \(status.service)"
        verifiedLabel.textColor = status.service == "running" ? Theme.verified : Theme.partial
        // Privacy & Memory
        privacyBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let model = status.model ?? "z-ai/glm-5.3-flash"
        for (k, v) in [("Model", "\(model) · NEAR AI Cloud"), ("Runs in", "Confidential TEE (Intel TDX + NVIDIA GPU)"),
                       ("Last reply", status.lastVerdict ?? "Not yet this session"),
                       ("Saved highlights", status.highlights.map { "\($0), kept encrypted on this Mac" } ?? "Kept encrypted on this Mac")] {
            privacyBody.addArrangedSubview(row([label(k, .systemFont(ofSize: 12), t.text2, width: 110), label(v, .systemFont(ofSize: 12, weight: .medium), t.text, width: inner - 150)], width: inner - 24, spacing: 6))
        }
        privacyBody.addArrangedSubview(PixelButton(title: "Open memory", primary: false) { [weak self] in self?.onOpenMemory?() })
        privacyRow.setSummary(status.service == "running" ? (verified ? "Verified" : "On") + (status.highlights.map { " · \($0) highlights" } ?? "") : status.service)
        // Wallet
        walletBody.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if status.walletReady {
            walletBody.addArrangedSubview(label((status.balance ?? "…") + " NEAR", Theme.mono(22, .bold), t.text, width: inner - 24))
            if let w = status.spentWeek { walletBody.addArrangedSubview(label("Spent this week: \(w) NEAR", .systemFont(ofSize: 12), t.text2, width: inner - 24)) }
            walletBody.addArrangedSubview(PixelButton(title: "Open wallet", primary: false) { [weak self] in self?.onOpenWallet?() })
            walletRow.setSummary((status.balance.map { "\($0) Ⓝ" } ?? "Ready"))
        } else {
            walletBody.addArrangedSubview(label(status.wallet ?? "Checking…", .systemFont(ofSize: 12), t.text2, width: inner - 24))
            walletBody.addArrangedSubview(PixelButton(title: "Set up \(settings.name)'s wallet", primary: true) { [weak self] in self?.onOpenWallet?() })
            walletRow.setSummary("Not set up")
        }
        fit()
    }

    // MARK: pieces

    @discardableResult
    private func addRow(_ title: String, icon: String, summary: String, body: NSView, open: Bool) -> DisclosureRow {
        let r = DisclosureRow(title, icon: icon, summary: summary, content: body, open: open, look: look, width: inner)
        r.onToggle = { [weak self] in self?.fit(); self?.onResize?() }
        stack.addArrangedSubview(rule())
        stack.addArrangedSubview(r)
        stack.addArrangedSubview(body)
        return r
    }

    private func bodyStack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .leading; s.spacing = 6
        s.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 4, right: 0)
        return s
    }

    private func row(_ views: [NSView], width: CGFloat, spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views); r.spacing = spacing; r.alignment = .centerY
        r.widthAnchor.constraint(equalToConstant: width).isActive = true
        return r
    }

    private func toggle(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> PixelToggle {
        let tg = PixelToggle(title, on: on, look: look, width: inner)
        tg.onPress = { [weak self, weak tg] in set(tg?.isOn ?? false); self?.changed() }
        return tg
    }

    private func linkButton(_ title: String, _ action: @escaping () -> Void) -> NSView {
        let b = PixelButton(title: title, primary: false, action: action)
        return b
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor, width: CGFloat? = nil) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font; l.textColor = color
        l.preferredMaxLayoutWidth = width ?? inner
        return l
    }

    private func section(_ s: String) -> NSTextField { label(s, Theme.mono(10, .bold), t.text2) }

    private func rule() -> NSView {
        let v = NSBox(); v.boxType = .custom; v.borderWidth = 0; v.fillColor = t.line
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: inner).isActive = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    /// Instant apply: every change is saved and handed to the app at once.
    private func changed() {
        settings.save()
        onChange?(settings)
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField {
            let n = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.name = n.isEmpty ? PixlSkins.current.manifest.name : String(n.prefix(24))
        } else if field === appsField {
            settings.distractingApps = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        changed()
    }
}

/// The header's pet tile: a soft plate the preview stands in.
@MainActor
final class TileView: NSView {
    let look: SurfaceView.Look
    init(look: SurfaceView.Look, size: NSSize) {
        self.look = look
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let t = look.tokens, r = bounds.insetBy(dx: 1, dy: 1)
        t.chip.setFill(); NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        t.line.setStroke(); let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8); p.lineWidth = 2; p.stroke()
        t.line.setFill(); NSRect(x: 18, y: bounds.height - 16, width: bounds.width - 36, height: 2).fill()   // the floor line
    }
}
