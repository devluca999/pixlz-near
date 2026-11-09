import AppKit

/// A row of small square pictures under an answer. Clicking one opens it large beneath the row
/// (with its name and a link to its page); clicking it again, or Esc on the card, closes it.
@MainActor
public final class PictureStrip: NSView {
    let pictures: [AnswerPicture]
    let look: SurfaceView.Look
    let width: CGFloat
    var onOpenURL: ((URL) -> Void)?
    /// Called when the strip changes height (a picture opened or closed): the card refits.
    var onResize: (() -> Void)?

    static let side: CGFloat = 56
    static let gap: CGFloat = 6
    var thumbs: [PictureThumb] = []
    var images: [Int: NSImage] = [:]
    var openIndex: Int?
    let row = NSStackView()
    let column = NSStackView()
    var large: NSView?

    init(pictures: [AnswerPicture], look: SurfaceView.Look, width: CGFloat) {
        let fit = max(1, Int((width + Self.gap) / (Self.side + Self.gap)))
        self.pictures = Array(pictures.prefix(fit))
        self.look = look
        self.width = width
        super.init(frame: .zero)
        row.orientation = .horizontal
        row.spacing = Self.gap
        for (i, p) in self.pictures.enumerated() {
            let t = PictureThumb(look: look, side: Self.side) { [weak self] in self?.toggle(i) }
            t.setAccessibilityLabel("Picture of \(p.title). Click to enlarge.")
            thumbs.append(t)
            row.addArrangedSubview(t)
        }
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.addArrangedSubview(row)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Thumbnails load in parallel; each square fills in when its picture arrives.
    func load() {
        for (i, p) in pictures.enumerated() {
            Task { @MainActor [weak self] in
                var r = URLRequest(url: p.thumb, timeoutInterval: 8)
                r.setValue("PixlMemory/1.0 (desktop pet; pictures for answers)", forHTTPHeaderField: "User-Agent")
                guard let (d, _) = try? await URLSession.shared.data(for: r), let img = NSImage(data: d), let self else { return }
                self.images[i] = img
                self.thumbs[i].image = img
                if self.openIndex == i { self.showLarge(i) }
            }
        }
    }

    func toggle(_ i: Int) {
        if openIndex == i { close() } else { showLarge(i) }
    }

    public func close() {
        large?.removeFromSuperview(); large = nil
        if let o = openIndex { thumbs[o].selected = false }
        openIndex = nil
        onResize?()
    }

    func showLarge(_ i: Int) {
        large?.removeFromSuperview()
        if let o = openIndex { thumbs[o].selected = false }
        openIndex = i
        thumbs[i].selected = true
        let p = pictures[i]
        let img = images[i]
        let aspect = img.map { $0.size.width > 0 ? $0.size.height / $0.size.width : 0.75 } ?? 0.75
        let h = min(max(width * aspect, 120), 260)
        let view = PictureThumb(look: look, side: width, height: h, fit: true) { [weak self] in self?.close() }
        view.image = img
        view.setAccessibilityLabel("\(p.title), enlarged. Click to close.")
        let tk = look.tokens
        let name = NSTextField(labelWithString: p.title)
        name.font = .systemFont(ofSize: 12.5, weight: .semibold)
        name.textColor = tk.text
        let link = LinkLabel(title: "Wikipedia  ↗", look: look) { [weak self] in self?.onOpenURL?(p.page) }
        let caption = NSStackView(views: [name, NSView(), link])
        caption.orientation = .horizontal
        caption.widthAnchor.constraint(equalToConstant: width).isActive = true
        let box = NSStackView(views: [view, caption])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        column.addArrangedSubview(box)
        large = box
        onResize?()
    }
}

/// One picture, cropped to fill a square (or, enlarged, shown whole on the card's surface).
@MainActor
final class PictureThumb: NSView {
    let look: SurfaceView.Look
    let fitWhole: Bool
    let action: () -> Void
    var image: NSImage? { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    var radius: CGFloat { fitWhole ? 8 : 6 }

    init(look: SurfaceView.Look, side: CGFloat, height: CGFloat? = nil, fit: Bool = false, action: @escaping () -> Void) {
        self.look = look
        self.fitWhole = fit
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: height ?? side).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let tk = look.tokens
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        tk.chip.setFill()
        shape.fill()
        if let img = image, img.size.width > 0, img.size.height > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            // fill the square (cropping the long side), or fit the whole picture when enlarged
            let sx = bounds.width / img.size.width, sy = bounds.height / img.size.height
            let k = fitWhole ? min(sx, sy) : max(sx, sy)
            let w = img.size.width * k, h = img.size.height * k
            img.draw(in: NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
        if selected || hovering {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
            ring.lineWidth = selected ? 2 : 1
            (selected ? tk.text : tk.text2).setStroke()
            ring.stroke()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { action() } }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}

/// A small clickable caption link.
@MainActor
final class LinkLabel: NSTextField {
    let onClick: () -> Void
    init(title: String, look: SurfaceView.Look, action: @escaping () -> Void) {
        self.onClick = action
        super.init(frame: .zero)
        stringValue = title
        isEditable = false; isBordered = false; drawsBackground = false; isSelectable = false
        font = Theme.mono(9)
        textColor = look.tokens.text2
        setAccessibilityRole(.link)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
