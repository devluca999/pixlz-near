import AppKit
import ApplicationServices
import PixlMemoryKit

/// Read-only Accessibility access: the active window's frame and the selected text.
/// Never moves windows, never sends keys or clicks (SPEC R4).
@MainActor
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once; the user grants it in System Settings.
    static func requestTrust() {
        // The value of kAXTrustedCheckOptionPrompt; the C global isn't concurrency-safe to read in Swift 6.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        // Chrome and Electron apps only expose web content when asked for it.
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return el
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        attr(app(pid), kAXFocusedWindowAttribute)
    }

    /// Frame in top-left global coordinates (same space as Perch).
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let posV: AXValue = attr(window, kAXPositionAttribute),
              let sizeV: AXValue = attr(window, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV, .cgPoint, &pos)
        AXValueGetValue(sizeV, .cgSize, &size)
        if let minimized: Bool = attr(window, kAXMinimizedAttribute), minimized { return nil }
        return CGRect(origin: pos, size: size)
    }

    /// Whether a window is in native fullscreen (its own Space).
    static func isFullscreen(_ window: AXUIElement) -> Bool {
        let v: Bool? = attr(window, "AXFullScreen")
        return v == true
    }

    /// Screen rects (top-left global) of the selection and the caret in the frontmost app, so
    /// bubbles never cover them. Empty if the app doesn't expose text ranges.
    static func selectionBounds(pid: pid_t) -> [CGRect] {
        guard let focused: AXUIElement = attr(app(pid), kAXFocusedUIElementAttribute),
              let rangeValue: AXValue = attr(focused, kAXSelectedTextRangeAttribute) else { return [] }
        var range = CFRange()
        AXValueGetValue(rangeValue, .cfRange, &range)
        func bounds(_ r: CFRange) -> CGRect? {
            var rr = r
            guard let v = AXValueCreate(.cfRange, &rr) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, v, &out) == .success,
                  let rectValue = out, CFGetTypeID(rectValue) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            AXValueGetValue(rectValue as! AXValue, .cgRect, &rect)
            return rect.width > 0 || rect.height > 0 ? rect : nil
        }
        var rects: [CGRect] = []
        if range.length > 0, let sel = bounds(range) { rects.append(sel.insetBy(dx: -6, dy: -4)) }
        if let caret = bounds(CFRange(location: range.location, length: 0)) ?? bounds(CFRange(location: range.location, length: 1)) {
            rects.append(CGRect(x: caret.minX - 6, y: caret.minY - 4, width: max(caret.width, 2) + 12, height: caret.height + 8))
        }
        return rects
    }

    /// Whether `pid` has a normal window on screen on the current Space. Uses only window
    /// owner and layer from the window list (no titles, no images: no Screen Recording needed).
    static func hasWindowOnThisSpace(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        return list.contains { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    }

    /// The focused element of `pid` (the text field holding the selection).
    static func focusedElement(pid: pid_t) -> AXUIElement? { attr(app(pid), kAXFocusedUIElementAttribute) }

    /// Writes `text` over `original` in `element`, through AX (never keystrokes):
    /// - if the selection is still `original`, replace it;
    /// - else, if `original` appears exactly once in the field, select it again and replace it
    ///   (browsers often collapse the selection when focus moves to another window).
    /// Returns false if neither is safe, so the caller can fall back to copying.
    static func replace(in element: AXUIElement, original: String, with text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue
        else { return false }
        let current: String? = attr(element, kAXSelectedTextAttribute)
        if current != original {
            guard let value: String = attr(element, kAXValueAttribute) else { return false }
            let ns = value as NSString
            let r = ns.range(of: original)
            guard r.location != NSNotFound,
                  ns.range(of: original, range: NSRange(location: r.location + 1, length: ns.length - r.location - 1)).location == NSNotFound
            else { return false }  // missing or ambiguous: don't guess
            var cf = CFRange(location: r.location, length: r.length)
            guard let v = AXValueCreate(.cfRange, &cf),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) == .success,
                  (attr(element, kAXSelectedTextAttribute) as String?) == original
            else { return false }
        }
        let before: String? = attr(element, kAXValueAttribute)
        if AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            // some apps report success but ignore the write (or apply it a beat later): confirm
            for _ in 0..<6 {
                let value: String? = attr(element, kAXValueAttribute)
                if value != before, value?.contains(text) == true { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        // Chromium ignores selected-text writes in web fields but accepts a value write: swap
        // just the original (it must appear exactly once), then select the new text.
        guard let value = before else { return false }
        let ns = value as NSString
        let r = ns.range(of: original)
        guard r.location != NSNotFound,
              ns.range(of: original, range: NSRange(location: r.location + 1, length: ns.length - r.location - 1)).location == NSNotFound
        else { return false }
        var settableValue: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settableValue) == .success, settableValue.boolValue,
              AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, ns.replacingCharacters(in: r, with: text) as CFString) == .success
        else { return false }
        for _ in 0..<6 {
            if (attr(element, kAXValueAttribute) as String?)?.contains(text) == true {
                var sel = CFRange(location: r.location, length: (text as NSString).length)
                if let v = AXValueCreate(.cfRange, &sel) { AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, v) }
                Debug.log("replace: selected-text write ignored, value written instead")
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Chromium browsers build the accessibility tree for web pages only when an assistive app
    /// asks (AXEnhancedUserInterface). Without it a textarea's selection can't be read. Only for
    /// these browsers: in other apps the flag can disturb window animations.
    static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
                                        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
                                        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium"]
    nonisolated(unsafe) static var webEnabled: Set<pid_t> = []

    /// Returns true when the tree was just switched on (the caller may need to wait a moment).
    @discardableResult
    static func enableWebAccessibility(for app: NSRunningApplication?) -> Bool {
        guard let app, let id = app.bundleIdentifier, chromium.contains(id), !webEnabled.contains(app.processIdentifier) else { return false }
        let el = Self.app(app.processIdentifier)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        webEnabled.insert(app.processIdentifier)
        return true
    }

    /// The selected text in the frontmost app, if it exposes one.
    static func selectedText(pid: pid_t) -> String? {
        guard let focused: AXUIElement = attr(app(pid), kAXFocusedUIElementAttribute) else { return nil }
        let text: String? = attr(focused, kAXSelectedTextAttribute)
        return text?.isEmpty == false ? text : nil
    }
}

/// Watches the active window for moves and resizes, and the app for window switches.
@MainActor
final class WindowWatcher {
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var appToken: NSObjectProtocol?
    enum Change { case switched, moved }
    var onChange: ((Change) -> Void)?

    func start() {
        appToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attachToFrontmost() }
        }
        attachToFrontmost()
    }

    func attachToFrontmost() {
        detach()
        guard AX.trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { onChange?(.switched); return }
        let pid = app.processIdentifier
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let moved = [kAXMovedNotification, kAXResizedNotification].contains(notification as String)
            MainActor.assumeIsolated { me.windowEvent(moved ? .moved : .switched) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { onChange?(.switched); return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appEl = AX.app(pid)
        appElement = appEl
        AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        watchWindow()
        onChange?(.switched)
    }

    private func watchWindow() {
        guard let obs = observer, let appEl = appElement else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = windowElement {
            for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
                AXObserverRemoveNotification(obs, old, n as CFString)
            }
        }
        windowElement = AX.attr(appEl, kAXFocusedWindowAttribute)
        if let w = windowElement {
            for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification] {
                AXObserverAddNotification(obs, w, n as CFString, refcon)
            }
        }
    }

    private func windowEvent(_ change: Change) {
        if change == .switched { watchWindow() }
        onChange?(change)
    }

    var activeWindowIsFullscreen: Bool { windowElement.map(AX.isFullscreen) ?? false }

    func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
        windowElement = nil
    }

    var activeWindowFrame: CGRect? {
        guard let w = windowElement else { return nil }
        return AX.frame(of: w)
    }
}
