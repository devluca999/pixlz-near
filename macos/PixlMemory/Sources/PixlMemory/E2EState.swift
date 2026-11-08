import AppKit
import PixlMemoryKit

/// Debug only (PIXL_DEBUG=1): an end-to-end driver posts `com.pixl.memory.e2e.dump` and reads
/// back where Frogg and every visible control are, in global top-left points. Costs nothing
/// at idle: it only runs when asked.
@MainActor
enum E2EState {
    static let request = Notification.Name("com.pixl.memory.e2e.dump")
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/PixlMemory/state.json")
    }

    static func install(_ app: AppController) {
        guard Debug.enabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated { if let app { write(app) } }
        }
    }

    static func write(_ app: AppController) {
        let h = app.primaryHeight
        func tl(_ r: NSRect) -> [String: Double] {
            ["x": r.minX, "y": h - r.maxY, "w": r.width, "h": r.height, "cx": r.midX, "cy": h - r.midY]
        }
        func controls(_ panel: NSWindow?) -> [[String: Any]] {
            guard let panel, panel.isVisible, let root = panel.contentView else { return [] }
            var out: [[String: Any]] = []
            func walk(_ v: NSView) {
                if let seg = v as? NSSegmentedControl, !v.isHiddenOrHasHiddenAncestor {
                    var x: CGFloat = 0
                    let total = (0..<seg.segmentCount).map { seg.width(forSegment: $0) }.reduce(0, +)
                    for i in 0..<seg.segmentCount {
                        let w = total > 0 && seg.width(forSegment: i) > 0 ? seg.width(forSegment: i) : seg.bounds.width / CGFloat(seg.segmentCount)
                        let r = panel.convertToScreen(seg.convert(NSRect(x: x, y: 0, width: w, height: seg.bounds.height), to: nil))
                        out.append(["label": seg.label(forSegment: i) ?? "", "role": "AXRadioButton", "enabled": seg.isEnabled(forSegment: i), "frame": tl(r)])
                        x += w
                    }
                }
                // editable text fields report their role through the cell
                let role = (v as? NSTextField).map { $0.isEditable ? NSAccessibility.Role.textField : $0.accessibilityRole() } ?? v.accessibilityRole()
                if !v.isHiddenOrHasHiddenAncestor, v.alphaValue > 0.05,
                   [.button, .menuItem, .link, .textField].contains(role),
                   let label = v.accessibilityLabel() ?? (v as? NSTextField)?.placeholderString {
                    let r = panel.convertToScreen(v.convert(v.bounds, to: nil))
                    out.append(["label": label, "role": role?.rawValue ?? "", "enabled": v.isAccessibilityEnabled(), "frame": tl(r)])
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            return out
        }
        func panel(_ p: NSWindow?) -> [String: Any]? {
            guard let p, p.isVisible else { return nil }
            return ["frame": tl(p.frame), "key": p.isKeyWindow, "controls": controls(p)]
        }
        var s: [String: Any] = [
            "time": Date().timeIntervalSince1970,
            "frogg": ["box": tl(app.froggBox), "visible": app.froggPanel.isVisible && app.froggPanel.alphaValue > 0.5,
                      "frame": app.frogg.frameName, "mode": "\(app.mode)", "moving": app.moving,
                      "hidden": app.userHidden, "scale": app.settings.scale, "foot": app.foot.map { ["x": $0.x, "y": $0.y] } ?? [:]],
            "menuOpen": app.menu.isOpen,
            "skin": PixlSkins.currentID,
            "name": app.settings.name,
            "selection": app.pendingSelection?.text ?? NSNull(),
            "speech": (app.bubblePanel.isVisible ? (app.bubblePanel.contentView as? BubbleView)?.text : nil) ?? NSNull(),
            "screens": app.screensTopLeft.map { ["x": $0.minX, "y": $0.minY, "w": $0.width, "h": $0.height] },
        ]
        s["bubbles"] = panel(app.menu.panel)
        s["list"] = panel(app.menu.listPanel)
        s["card"] = panel(app.menu.cardPanel)
        s["result"] = panel(app.resultPanel)
        s["mini"] = panel(app.miniPanel)
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
