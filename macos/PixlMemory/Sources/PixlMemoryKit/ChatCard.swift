import AppKit

/// Agent mode (SPEC §16): one Claude Code session's chat, newest at the bottom, and a reply
/// field while the session is held open for one (Reply from Pixlz).
public final class ChatCard: PixlCard {
    public struct Line: Sendable {
        public enum Who: Sendable { case you, claude, tool }
        public var who: Who
        public var text: String
        public init(_ who: Who, _ text: String) { self.who = who; self.text = text }
    }

    public var onReply: ((String) -> Void)?
    public let input: PixlField
    public var field: NSTextField { input.field }

    public init(title: String, lines: [Line], replyOpen: Bool, replyNote: String, look: SurfaceView.Look,
                emptyNote: String = "Nothing to show yet. The chat appears once this session does something.",
                footer: (button: String, hint: String)? = nil, placeholder: String = "Reply to Claude…") {
        input = PixlField(placeholder: placeholder, icon: "agents", look: look, label: "Reply to this session")
        super.init(title: title, icon: "agents", look: look)
        if lines.isEmpty {
            stack.addArrangedSubview(text(emptyNote, muted: true))
        }
        for l in lines {
            switch l.who {
            case .you:
                stack.addArrangedSubview(text("You", size: 11, weight: .bold, muted: true))
                stack.addArrangedSubview(text(Self.cut(l.text, 1200), size: 13))
            case .claude:
                stack.addArrangedSubview(text("Claude", size: 11, weight: .bold, muted: true))
                let t = text("", size: 13)
                t.attributedStringValue = AskCard.styled(Self.cut(l.text, 4000), font: .systemFont(ofSize: 13), color: tokens.text)
                t.isSelectable = true
                stack.addArrangedSubview(t)
            case .tool:
                stack.addArrangedSubview(text("▸ " + Self.cut(l.text, 200), size: 11, muted: true, mono: true))
            }
        }
        // The reply field is always here: a reply to a session that's still working waits and
        // goes when it finishes (`replyNote` says so).
        input.widthAnchor.constraint(equalToConstant: inner).isActive = true
        input.onReturn = { [weak self] in self?.submit() }
        input.onEscape = { [weak self] in self?.onClose?() }
        stack.addArrangedSubview(input)
        setFooter([PixelButton(title: footer?.button ?? (replyOpen ? "Reply" : "Queue reply"), style: .primary, hint: "↵") { [weak self] in self?.submit() }],
                  hint: footer?.hint ?? (replyOpen ? "Claude is waiting for you" : replyNote))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    func submit() {
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onReply?(t)
    }

    /// How far the view sits above the newest turn (0: at the end), to keep a reader's place
    /// when the chat redraws with new turns.
    public var distanceFromEnd: CGFloat {
        guard let doc = bodyScroll.documentView else { return 0 }
        return max(0, doc.bounds.height - bodyScroll.contentView.bounds.height - bodyScroll.contentView.bounds.origin.y)
    }

    public func scroll(toDistanceFromEnd d: CGFloat) {
        guard let doc = bodyScroll.documentView else { return }
        layoutSubtreeIfNeeded()
        doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - bodyScroll.contentView.bounds.height - d)))
    }

    /// The newest turn in view.
    public func scrollToEnd() {
        guard let doc = bodyScroll.documentView else { return }
        layoutSubtreeIfNeeded()
        doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - bodyScroll.contentView.bounds.height)))
    }
}
