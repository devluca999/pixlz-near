import AppKit
import ApplicationServices

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
    var onChange: (() -> Void)?

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
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { onChange?(); return }
        let pid = app.processIdentifier
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.windowEvent() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { onChange?(); return }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appEl = AX.app(pid)
        appElement = appEl
        AXObserverAddNotification(obs, appEl, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, appEl, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        watchWindow()
        onChange?()
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

    private func windowEvent() {
        watchWindow()
        onChange?()
    }

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
