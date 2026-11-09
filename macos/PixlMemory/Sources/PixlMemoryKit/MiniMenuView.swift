import AppKit

/// The mini menu (SPEC §11.5): name, Pixl card, behaviour toggles, size, hotkeys,
/// distracting apps for Focus, and Pixl Memory's own status (service, model, wallet).
@MainActor
public final class MiniMenuView: NSView, NSTextFieldDelegate {
    public var onChange: ((PixlSettings) -> Void)?
    public var onClose: (() -> Void)?
    public var onOpenWallet: (() -> Void)?
    public private(set) var settings: PixlSettings
    public static let width: CGFloat = 400

    private let stack = NSStackView()
    private var closeButton: NSView?
    private var serviceLabel: NSTextField!
    private var modelLabel: NSTextField!
    private var lastLabel: NSTextField!
    private var walletLabel: NSTextField!
    private var walletButton: NSView!

    /// Centre of the ✕ button in this view's coordinates (for the app's self-test).
    public var closeButtonCenter: NSPoint? {
        guard let b = closeButton else { return nil }
        layoutSubtreeIfNeeded()
        return convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), from: b)
    }
    private var nameField: NSTextField!
    private var appsField: NSTextField!

    public let look: SurfaceView.Look

    public init(settings: PixlSettings, status: ServiceStatus, look: SurfaceView.Look = .init(glass: false, variant: .light, dim: 1)) {
        self.settings = settings
        self.look = look
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        appearance = look.appearance  // light or dark text, per the legibility pick
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18 - Theme.shadowOffset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16 - Theme.shadowOffset),
        ])
        build(status)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        return  // the shared SurfaceView draws the material; see SurfaceView.card
        let card = NSRect(x: 0, y: 0, width: bounds.width - Theme.shadowOffset, height: bounds.height - Theme.shadowOffset)
        Theme.ink.setFill(); NSBezierPath(rect: card.offsetBy(dx: Theme.shadowOffset, dy: Theme.shadowOffset)).fill()
        Theme.paper.setFill(); NSBezierPath(rect: card).fill()
        Theme.ink.setStroke()
        let p = NSBezierPath(rect: card.insetBy(dx: Theme.border / 2, dy: Theme.border / 2)); p.lineWidth = Theme.border; p.stroke()
    }

    public func fit() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: fittingSize.height))
    }

    private var inner: CGFloat { Self.width - 36 - Theme.shadowOffset }

    private func build(_ status: ServiceStatus) {
        // Pixl card: Frogg, name, species
        let img = NSImageView(image: FroggArt.shared.nsImage("idle_0", scale: 1) ?? NSImage())
        nameField = NSTextField(string: settings.name)
        nameField.font = Theme.mono(15, .bold)
        nameField.delegate = self
        nameField.placeholderString = "Name"
        nameField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let species = label(PixlData.manifest.species, Theme.mono(10), Theme.textMuted)
        let nameCol = NSStackView(views: [nameField, species]); nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 4
        let close = PixelButton(title: "✕", primary: false) { [weak self] in self?.onClose?() }
        closeButton = close
        let card = NSStackView(views: [img, nameCol, NSView(), close]); card.orientation = .horizontal; card.spacing = 10
        card.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(card)

        stack.addArrangedSubview(section("PIXL"))
        let picker = SkinPickerView(selected: settings.skinID, look: look, compact: true)
        picker.widthAnchor.constraint(equalToConstant: picker.frame.width).isActive = true
        picker.heightAnchor.constraint(equalToConstant: picker.frame.height).isActive = true
        picker.onPick = { [weak self] id in self?.settings.skin = id; self?.changed() }
        stack.addArrangedSubview(picker)

        stack.addArrangedSubview(section("SIZE"))
        let size = NSSegmentedControl(labels: PixlScale.presets.map(PixlScale.label), trackingMode: .selectOne, target: self, action: #selector(sizeChanged(_:)))
        size.selectedSegment = PixlScale.presets.firstIndex(of: settings.scale) ?? -1
        stack.addArrangedSubview(size)
        stack.addArrangedSubview(label("Now \(PixlScale.label(settings.scale)). Or hover \(settings.name) and drag a corner.", Theme.mono(10), Theme.textMuted))

        stack.addArrangedSubview(section("BEHAVIOR"))
        let behavior = NSSegmentedControl(labels: ["Calm", "Roam"], trackingMode: .selectOne, target: self, action: #selector(behaviorChanged(_:)))
        behavior.selectedSegment = settings.roams ? 1 : 0
        behavior.setToolTip("Stays with you and waits for you", forSegment: 0)
        behavior.setToolTip("Explores on its own: folders, window tops, reading along. Never while you type.", forSegment: 1)
        stack.addArrangedSubview(behavior)
        stack.addArrangedSubview(label(settings.roams ? "Explores now and then. Poke it to make it sit still." : "Stays with you and waits.",
                                       Theme.mono(10), Theme.textMuted))
        stack.addArrangedSubview(check("Perch on the window I'm using", settings.perchOnWindows, #selector(perchChanged(_:))))
        stack.addArrangedSubview(check("Hide when an app goes fullscreen", settings.hideInFullscreen, #selector(fullscreenChanged(_:))))

        stack.addArrangedSubview(section("FOCUS · DISTRACTING APPS"))
        appsField = NSTextField(string: settings.distractingApps.joined(separator: ", "))
        appsField.placeholderString = "e.g. Safari, Slack, Music"
        appsField.font = Theme.mono(12)
        appsField.delegate = self
        appsField.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(appsField)

        stack.addArrangedSubview(section("HOTKEYS"))
        let chips = NSStackView(views: [chip("⌃⌥P  menu"), chip("⌃⌥Space  chat"), chip("⌃⌥H  hide")])
        chips.spacing = 8
        stack.addArrangedSubview(chips)

        stack.addArrangedSubview(section("PIXL MEMORY"))
        serviceLabel = label("", Theme.mono(11), Theme.text)
        modelLabel = label("", Theme.mono(11), Theme.text)
        lastLabel = label("", Theme.mono(11), Theme.text)
        walletLabel = label("", Theme.mono(11), Theme.partial)
        walletButton = PixelButton(title: "Set up \(settings.name)'s wallet", primary: true) { [weak self] in self?.onOpenWallet?() }
        [serviceLabel, modelLabel, lastLabel, walletLabel, walletButton].forEach { stack.addArrangedSubview($0!) }
        update(status: status)

        let talk = NSTextField(string: "")
        talk.placeholderString = "Talk to \(settings.name) · coming soon"
        talk.isEnabled = false
        talk.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(talk)
    }

    /// Fills in service and wallet status in place (the menu opens before it's known).
    public func update(status: ServiceStatus) {
        serviceLabel.stringValue = "Service: \(status.service)"
        modelLabel.stringValue = "Model: \(status.model ?? "…") (NEAR AI Cloud TEE)"
        modelLabel.isHidden = status.model == nil
        lastLabel.stringValue = "Last reply: \(status.lastVerdict ?? "")"
        lastLabel.isHidden = status.lastVerdict == nil
        walletLabel.stringValue = "Wallet: \(status.wallet ?? "checking…")"
        walletLabel.textColor = status.walletReady ? Theme.verified : Theme.partial
        walletButton.isHidden = status.walletReady
        fit()
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font; l.textColor = color
        l.preferredMaxLayoutWidth = inner
        return l
    }

    private func section(_ s: String) -> NSTextField { label(s, Theme.mono(10, .bold), Theme.textMuted) }

    private func check(_ title: String, _ on: Bool, _ action: Selector?) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        b.font = Theme.mono(12)
        return b
    }

    private func chip(_ s: String) -> NSView {
        let l = label(s, Theme.mono(11, .bold), Theme.ink)
        l.drawsBackground = true
        l.backgroundColor = .white
        l.wantsLayer = true
        l.layer?.borderWidth = 2
        l.layer?.borderColor = Theme.ink.cgColor
        return l
    }

    private func changed() {
        settings.save()
        onChange?(settings)
    }

    @objc private func sizeChanged(_ s: NSSegmentedControl) { settings.scale = PixlScale.presets[max(0, s.selectedSegment)]; changed() }
    @objc private func behaviorChanged(_ c: NSSegmentedControl) { settings.roams = c.selectedSegment == 1; changed() }
    @objc private func perchChanged(_ b: NSButton) { settings.perchOnWindows = b.state == .on; changed() }
    @objc private func fullscreenChanged(_ b: NSButton) { settings.hideInFullscreen = b.state == .on; changed() }

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
