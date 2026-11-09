import AppKit
import PixlMemoryKit
import PixlzCore

/// Debug only (PIXL_DEBUG=1): an end-to-end driver posts `com.pixl.memory.e2e.dump` and reads
/// back where Frogg and every visible control are, in global top-left points. Costs nothing
/// at idle: it only runs when asked.
@MainActor
enum E2EState {
    static let request = Notification.Name("com.pixl.memory.e2e.dump")
    static let command = Notification.Name("com.pixl.memory.e2e.do")
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/PixlMemory/state.json")
    }

    static func install(_ app: AppController) {
        guard Debug.enabled else { return }
        DistributedNotificationCenter.default().addObserver(forName: request, object: nil, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated { if let app { write(app) } }
        }
        // debug-only commands for driving trips between two copies of the app (object = this
        // device's id, so each copy only obeys its own): send, consent, local ask
        DistributedNotificationCenter.default().addObserver(forName: command, object: app.travel.me.deviceId, queue: .main) { [weak app] n in
            let info = n.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated {
                guard let app else { return }
                switch info["do"] {
                case "send": if let p = app.travel.peers.first(where: { $0.deviceName == info["to"] }) { app.travel.send(to: p) } else { Debug.log("e2e: no peer \(info["to"] ?? "")") }
                case "consent": app.menu.list.flatMap { l in l.rows.firstIndex { $0.id == (info["answer"] == "yes" ? "yes" : "no") }.map { (l, $0) } }
                    .map { l, i in l.onSelect?(l.rows[i]) }
                case "ask": Debug.log("e2e: local answer: \(app.travel.localAnswer(info["q"] ?? "") ?? "(for the model)")")
                case "callback": app.travel.callBack()
                case "behavior": var s = app.settings; s.roams = info["value"] == "roam"; app.apply(s)
                case "skin": var s = app.settings; s.skin = info["id"]; app.apply(s)
                case "roam":
                    app.roam.quietUntil = .distantPast
                    if let k = info["kind"], k != "pond" {
                        var p = app.roam.planner
                        let o = p.outing(named: k, app.roam.world())
                        Debug.log("e2e: roam \(k) → \(o.map { "\($0)" } ?? "doesn't fit now")")
                        if let o { app.roam.go(o, debug: true) }
                    } else { app.roam.go(info["kind"] == "pond" ? .pond(5) : nil, debug: true) }
                case "game": app.game.start()
                case "adjust": app.resizer.beginAdjust()
                case "voice": app.speak(SoundEvent(rawValue: info["event"] ?? "greet") ?? .greet)
                case "notice": app.notify(.copied, voice: .happy)
                case "sleep": app.sleep.debugSleepNow()
                case "awake": app.sleep.debugStayAwake(Double(info["s"] ?? "300") ?? 300)
                case "shell": info["out"] == "1" ? app.shellOut(info["kind"] ?? "vault") : app.shellIn(info["kind"] ?? "vault")
                case "ff": app.sleep.debugFastForward(Double(info["s"] ?? "60") ?? 60)
                case "nap": app.sleep.debugNap()
                case "sleepInput": SleepCycle.Input(rawValue: info["input"] ?? "").map { app.sleep.handle($0) }
                case "finish": app.resizer.finish()
                default: break
                }
            }
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
                   [.button, .menuItem, .link, .textField, .radioButton, .checkBox, .disclosureTriangle].contains(role),
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
            "device": app.travel.me.deviceName,
            "deviceId": app.travel.me.deviceId,
            "surface": app.frogg.surface.rawValue,
            "hanging": app.roamHanging != nil,
            "sleep": app.sleep.stage.rawValue,
            "handles": app.resizer.panel.map { tl($0.frame) } ?? NSNull(),
            "peers": app.travel.peers.map(\.deviceName),
            "awayOn": app.awayOn ?? NSNull(),
            "owns": app.travel.runner?.owned?.name ?? NSNull(),
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
