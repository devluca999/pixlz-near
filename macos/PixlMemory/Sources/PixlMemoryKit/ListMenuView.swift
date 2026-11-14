import AppKit

/// C8 "More" mini menu: a rounded surface with icon rows (Ask ⌘K, Memory, Wallet, Send to
/// device, Pixl settings, Do a trick, Hide for now). Hover and keyboard focus highlight a
/// row; ↑/↓ move, Return chooses, Esc closes. Disabled rows are dimmed and skipped.
@MainActor
public final class ListMenuView: NSView {
    public struct Row: Equatable, Sendable {
        public let id: String
        public let title: String
        public let icon: String?
        public let trailing: String?
        public let enabled: Bool
        public init(id: String, title: String, icon: String?, trailing: String? = nil, enabled: Bool = true) {
            self.id = id; self.title = title; self.icon = icon; self.trailing = trailing; self.enabled = enabled
        }
    }

    public let rows: [Row]
    public let surface: SurfaceView
    public var onSelect: ((Row) -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) var focusIndex: Int?
    let rowViews: [ListRow]
    static let width: CGFloat = 220
    /// Wide enough for the longest row (a long device name), between 220 and 320 pt.
    static func width(for rows: [Row]) -> CGFloat {
        let title = NSFont.systemFont(ofSize: 13, weight: .semibold), mono = Theme.mono(10)
        let need = rows.map { r in
            (r.title as NSString).size(withAttributes: [.font: title]).width + 42 + 20 + 12 + 4 +   // icon, gaps, the row inset, rounding
            (r.trailing.map { ($0 as NSString).size(withAttributes: [.font: mono]).width + 10 } ?? 0)
        }.max() ?? 0
        return min(max(ceil(need), 220), 320)
    }
    static let rowHeight: CGFloat = 34
    /// The widest a row title can be and still show whole in the widest (320 pt) list.
    public static let maxTitleWidth: CGFloat = 236

    /// `text` broken into row titles that each fit `width` (13 pt semibold), losing nothing:
    /// each source line's pieces joined back give the line. Breaks after a space when one is
    /// near the end, else mid-word (long paths, base64). Empty lines are skipped.
    public static func wrap(_ text: String, width: CGFloat = maxTitleWidth) -> [String] {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        func fits(_ s: Substring) -> Bool { (String(s) as NSString).size(withAttributes: [.font: font]).width <= width }
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = Substring(line)
            while !rest.isEmpty {
                if fits(rest) { out.append(String(rest)); break }
                // the longest prefix that fits (at least one character)
                var lo = 1, hi = rest.count
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if fits(rest.prefix(mid)) { lo = mid } else { hi = mid - 1 }
                }
                var cut = rest.index(rest.startIndex, offsetBy: lo)
                if let sp = rest[..<cut].lastIndex(of: " "), rest.distance(from: rest.startIndex, to: sp) >= lo / 2 {
                    cut = rest.index(after: sp)
                }
                out.append(String(rest[..<cut]))
                rest = rest[cut...]
            }
        }
        return out
    }

    public init(rows: [Row], look: SurfaceView.Look) {
        self.rows = rows
        let h = CGFloat(rows.count) * (Self.rowHeight + 2) + 12
        let w = Self.width(for: rows)
        surface = SurfaceView(frame: NSRect(x: 0, y: 0, width: w, height: h + (look.glass ? 0 : 3)), shape: .rounded(16), look: look)
        rowViews = rows.enumerated().map { i, r in
            ListRow(row: r, look: look, frame: NSRect(x: 6, y: 6 + CGFloat(i) * (Self.rowHeight + 2), width: w - 12, height: Self.rowHeight))
        }
        super.init(frame: surface.frame)
        appearance = look.appearance
        addSubview(surface)
        for (i, v) in rowViews.enumerated() {
            v.onPress = { [weak self] in self?.choose(i) }
            v.onHover = { [weak self] inside in if inside { self?.setFocus(nil) } }
            surface.content.addSubview(v)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("More")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func accessibilityChildren() -> [Any]? { rowViews }

    /// Centre of row `i` in this view's coordinates.
    public func center(of i: Int) -> NSPoint? {
        guard rowViews.indices.contains(i) else { return nil }
        let f = rowViews[i].frame
        return convert(NSPoint(x: f.midX, y: f.midY), from: surface.content)
    }

    func choose(_ i: Int) {
        guard rows.indices.contains(i), rows[i].enabled else { return }
        Debug.log("list chosen \(rows[i].id)")
        onSelect?(rows[i])
    }

    public func setFocus(_ i: Int?) {
        focusIndex = i
        for (j, v) in rowViews.enumerated() { v.focused = (j == i) }
    }

    func step(_ from: Int?, by d: Int) -> Int? {
        let enabled = rows.indices.filter { rows[$0].enabled }
        guard !enabled.isEmpty else { return nil }
        guard let from, let k = enabled.firstIndex(of: from) else { return d > 0 ? enabled.first : enabled.last }
        return enabled[(k + d + enabled.count) % enabled.count]
    }

    public override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "k",
           let i = rows.firstIndex(where: { $0.id == "ask" }) { choose(i); return }
        switch event.keyCode {
        case 126: setFocus(step(focusIndex, by: -1))           // ↑
        case 125, 48: setFocus(step(focusIndex, by: 1))        // ↓ Tab
        case 36, 76, 49: if let i = focusIndex { choose(i) } else { setFocus(step(nil, by: 1)) }
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class ListRow: NSView {
    let row: ListMenuView.Row
    let look: SurfaceView.Look
    var onPress: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var down = false { didSet { needsDisplay = true } }
    var focused = false { didSet { needsDisplay = true } }

    init(row: ListMenuView.Row, look: SurfaceView.Look, frame: NSRect) {
        self.row = row
        self.look = look
        super.init(frame: frame)
        if let name = row.icon, let img = BubbleIcons.image(name, dark: look.variant == .dark) {
            let iv = NSImageView(image: img)
            iv.frame = NSRect(x: 8, y: (frame.height - 24) / 2, width: 24, height: 24)
            addSubview(iv)
        }
        let t = NSTextField(labelWithString: row.title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = look.textColor
        t.lineBreakMode = .byTruncatingTail
        t.sizeToFit()
        t.frame.origin = NSPoint(x: 42, y: (frame.height - t.frame.height) / 2)
        addSubview(t)
        if let trailing = row.trailing {
            let k = NSTextField(labelWithString: trailing)
            k.font = Theme.mono(10)
            k.textColor = look.mutedColor
            k.lineBreakMode = .byTruncatingTail
            k.sizeToFit()
            // the title keeps its full width; the trailing hint shrinks (and truncates) to fit
            let room = frame.width - 10 - (t.frame.maxX + 10)
            k.frame.size.width = min(k.frame.width, max(0, room))
            k.frame.origin = NSPoint(x: frame.width - k.frame.width - 10, y: (frame.height - k.frame.height) / 2)
            k.isHidden = room < 24
            addSubview(k)
        }
        alphaValue = row.enabled ? 1 : 0.38
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(row.trailing.map { "\(row.title), \($0)" } ?? row.title)
        setAccessibilityEnabled(row.enabled)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard row.enabled, hovering || focused || down else { return }
        look.rowFill(pressed: down).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        if focused {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            p.lineWidth = 2
            Accent.color.setStroke()   // the current Pixl's colour
            p.stroke()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; down = false }
    override func mouseDown(with event: NSEvent) { down = true; Debug.log("row down \(row.id)") }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        down = false
        Debug.log("row up \(row.id) inside=\(inside)")
        if inside, row.enabled { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { guard row.enabled else { return false }; onPress?(); return true }
}
