import AppKit
import Carbon.HIToolbox
import PixlMemoryKit

/// Global hotkeys via Carbon RegisterEventHotKey: no permission needed (SPEC D14, §11.4).
/// ⌃⌥ avoids the ⌥⌘ system shortcuts.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    enum Key: UInt32 {
        case p = 35       // kVK_ANSI_P
        case h = 4        // kVK_ANSI_H
        case space = 49   // kVK_Space
        case s = 1, f = 3, d = 2, a = 0, n = 45   // debug sleep keys (with ⇧)
    }

    func register(_ key: Key, shift: Bool = false, _ handler: @escaping () -> Void) {
        installIfNeeded()
        let id = UInt32(handlers.count + 1)
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5058_4C5A), id: id)  // 'PXLZ'
        let status = RegisterEventHotKey(key.rawValue, UInt32(controlKey | optionKey | (shift ? shiftKey : 0)), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
        Debug.log("hotkey ⌃⌥\(key) " + (status == noErr ? "registered" : "FAILED (status \(status): taken by another app or macOS)"))
    }

    fileprivate func fire(_ id: UInt32) { Debug.log("hotkey \(id) pressed"); handlers[id]?() }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            MainActor.assumeIsolated { HotKeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
