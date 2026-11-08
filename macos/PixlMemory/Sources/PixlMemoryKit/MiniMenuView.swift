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
    private var nameField: NSTextField!
    private var appsField: NSTextField!

    public init(settings: PixlSettings, status: ServiceStatus) {
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        appearance = NSAppearance(named: .aqua)  // paper-and-ink design: always light, even in dark mode
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
        let species = label("Red-eyed tree frog · the only Pixl in v1", Theme.mono(10), Theme.muted)
        let nameCol = NSStackView(views: [nameField, species]); nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 4
        let close = PixelButton(title: "✕", primary: false) { [weak self] in self?.onClose?() }
        let card = NSStackView(views: [img, nameCol, NSView(), close]); card.orientation = .horizontal; card.spacing = 10
        card.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(card)

        stack.addArrangedSubview(section("SIZE"))
        let size = NSSegmentedControl(labels: ["2×", "3×", "4×"], trackingMode: .selectOne, target: self, action: #selector(sizeChanged(_:)))
        size.selectedSegment = max(0, settings.scale - 2)
        stack.addArrangedSubview(size)

        stack.addArrangedSubview(section("BEHAVIOUR"))
        stack.addArrangedSubview(check("Perch on the window I'm using", settings.perchOnWindows, #selector(perchChanged(_:))))
        stack.addArrangedSubview(check("Hide when an app goes fullscreen", settings.hideInFullscreen, #selector(fullscreenChanged(_:))))
        let soon = check("File ride · mischief (\(settings.mischief)) · coming soon", false, nil)
        soon.isEnabled = false
        stack.addArrangedSubview(soon)

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
        stack.addArrangedSubview(label("Service: \(status.service)", Theme.mono(11), Theme.ink))
        if let m = status.model { stack.addArrangedSubview(label("Model: \(m) (NEAR AI Cloud TEE)", Theme.mono(11), Theme.ink)) }
        if let v = status.lastVerdict { stack.addArrangedSubview(label("Last reply: \(v)", Theme.mono(11), Theme.ink)) }
        let wallet = label("Wallet: \(status.wallet ?? "not set up")", Theme.mono(11), status.walletReady ? Theme.verified : Theme.partial)
        wallet.preferredMaxLayoutWidth = inner
        stack.addArrangedSubview(wallet)
        if !status.walletReady {
            stack.addArrangedSubview(PixelButton(title: "Set up Frogg's wallet", primary: true) { [weak self] in self?.onOpenWallet?() })
        }

        let talk = NSTextField(string: "")
        talk.placeholderString = "Talk to \(settings.name) · coming soon"
        talk.isEnabled = false
        talk.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(talk)
    }

    private func label(_ s: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = font; l.textColor = color
        l.preferredMaxLayoutWidth = inner
        return l
    }

    private func section(_ s: String) -> NSTextField { label(s, Theme.mono(10, .bold), Theme.muted) }

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

    @objc private func sizeChanged(_ s: NSSegmentedControl) { settings.scale = s.selectedSegment + 2; changed() }
    @objc private func perchChanged(_ b: NSButton) { settings.perchOnWindows = b.state == .on; changed() }
    @objc private func fullscreenChanged(_ b: NSButton) { settings.hideInFullscreen = b.state == .on; changed() }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField {
            let n = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.name = n.isEmpty ? "Frogg" : String(n.prefix(24))
        } else if field === appsField {
            settings.distractingApps = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        changed()
    }
}
