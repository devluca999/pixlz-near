import AppKit

/// The chat panel's text field: the only thing in the app that can make a `TypedMessage`, and
/// only from your own Return key or click on Send (a real input event, not a call from code).
/// Nothing else (the Pixl's AI, memory, NEAR inference) can put text in a session's outbox.
@MainActor
public final class AgentChatInput: NSTextField {
    /// You pressed Return or Send with something typed.
    public var onSend: ((TypedMessage) -> Void)?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = true; isSelectable = true; isBordered = false; drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        setAccessibilityLabel("Message to the session")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sends what's typed, if this comes from your keyboard or pointer. Returns whether it went.
    @discardableResult
    public func sendTyped() -> Bool {
        guard Self.isUserEvent(NSApp.currentEvent), let m = TypedMessage(stringValue) else { return false }
        stringValue = ""
        onSend?(m)
        return true
    }

    /// A key press or a click: the user did it.
    static func isUserEvent(_ e: NSEvent?) -> Bool {
        guard let e else { return false }
        return [.keyDown, .leftMouseUp, .leftMouseDown].contains(e.type)
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        // Return (not Tab, not clicking away) sends; ⇧Return makes a new line
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue { sendTyped() }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 36, event.modifierFlags.contains(.shift), let editor = currentEditor() {
            editor.insertText("\n")   // ⇧Return: a new line instead of sending
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
