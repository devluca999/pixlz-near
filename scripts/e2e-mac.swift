#!/usr/bin/env swift
// End-to-end pass over the installed Pixl Memory app, driven like a user: real mouse and key
// events through the window server, TextEdit/Chrome selections set through Accessibility.
// Confirms each step from the app's PIXL_DEBUG state dump and log.
//
//   swift scripts/e2e-mac.swift [--live] [--spaces] [--chrome]
//     --live    send real Polish requests (NEAR AI TEE; costs a little)
//     --spaces  switch Spaces with ⌃→ / ⌃← (needs two desktops)
//     --chrome  also polish in a Chrome textarea
//
// Needs Accessibility for the terminal running it. Moves your mouse: don't touch it meanwhile.

import AppKit
import ApplicationServices

let args = Set(CommandLine.arguments.dropFirst())
let live = args.contains("--live"), spaces = args.contains("--spaces"), chrome = args.contains("--chrome")
let home = FileManager.default.homeDirectoryForCurrentUser
let logURL = home.appending(path: "Library/Logs/PixlMemory/debug.log")
let stateURL = home.appending(path: "Library/Logs/PixlMemory/state.json")
let appPath = home.appending(path: "Applications/Pixl Memory.app").path

var results: [(String, String, String)] = []   // (step, PASS/FAIL/SKIP, note)
func record(_ step: String, _ ok: Bool?, _ note: String = "") {
    let r = ok == nil ? "SKIP" : (ok! ? "PASS" : "FAIL")
    results.append((step, r, note))
    print("\(r)  \(step)\(note.isEmpty ? "" : "  — \(note)")")
}

func sleep(_ s: Double) { Thread.sleep(forTimeInterval: s) }

// MARK: app state and log

func state() -> [String: Any] {
    try? FileManager.default.removeItem(at: stateURL)
    DistributedNotificationCenter.default().postNotificationName(.init("com.pixl.memory.e2e.dump"), object: nil, userInfo: nil, deliverImmediately: true)
    for _ in 0..<40 {
        sleep(0.05)
        if let d = try? Data(contentsOf: stateURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
    }
    return [:]
}
func dict(_ any: Any?) -> [String: Any] { any as? [String: Any] ?? [:] }
func controls(_ s: [String: Any], _ panel: String) -> [[String: Any]] { dict(s[panel])["controls"] as? [[String: Any]] ?? [] }
func center(_ c: [String: Any]) -> CGPoint { let f = dict(c["frame"]); return CGPoint(x: f["cx"] as? Double ?? 0, y: f["cy"] as? Double ?? 0) }
func control(_ s: [String: Any], _ panel: String, _ prefix: String) -> [String: Any]? {
    controls(s, panel).first { ($0["label"] as? String ?? "").hasPrefix(prefix) }
}
func frogg(_ s: [String: Any]) -> [String: Any] { dict(s["frogg"]) }
/// A point on Frogg's belly (opaque pixels): centre, lower third.
func belly(_ s: [String: Any]) -> CGPoint {
    let b = dict(frogg(s)["box"])
    return CGPoint(x: b["cx"] as? Double ?? 0, y: (b["y"] as? Double ?? 0) + (b["h"] as? Double ?? 0) * 0.72)
}

var logMark = 0
func markLog() { logMark = (try? Data(contentsOf: logURL))?.count ?? 0 }
func logSince() -> String {
    guard let d = try? Data(contentsOf: logURL), d.count >= logMark else { return "" }
    return String(decoding: d[logMark...], as: UTF8.self)
}
func waitLog(_ needle: String, timeout: Double = 3) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if logSince().contains(needle) { return true }; sleep(0.05) }
    return false
}
/// Bubbles animate open (~0.5 s): read positions once they've settled.
func settledBubbles(timeout: Double = 3, _ ok: @escaping ([String: Any]) -> Bool) -> [String: Any]? {
    guard waitState(timeout: timeout, ok) != nil else { return nil }
    sleep(0.5)
    return state()
}
func waitState(timeout: Double = 3, _ ok: ([String: Any]) -> Bool) -> [String: Any]? {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { let s = state(); if ok(s) { return s }; sleep(0.1) }
    return nil
}

// MARK: input

let src = CGEventSource(stateID: .hidSystemState)
func mouse(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, clicks: Int = 1) {
    let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
    e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
    e.post(tap: .cghidEventTap)
}
func move(_ p: CGPoint) { mouse(.mouseMoved, p); sleep(0.05) }
func click(_ p: CGPoint, clicks: Int = 1) {
    move(p)
    for n in 1...clicks {
        mouse(.leftMouseDown, p, clicks: n); sleep(0.03)
        mouse(.leftMouseUp, p, clicks: n); sleep(0.06)
    }
}
func rightClick(_ p: CGPoint) { move(p); mouse(.rightMouseDown, p, button: .right); sleep(0.03); mouse(.rightMouseUp, p, button: .right) }
func drag(_ a: CGPoint, _ b: CGPoint, steps: Int = 20, duration: Double = 0.4, hold: Double = 0.05) {
    move(a)
    mouse(.leftMouseDown, a); sleep(hold)
    for i in 1...steps {
        let f = Double(i) / Double(steps)
        mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        sleep(duration / Double(steps))
    }
    sleep(0.1)
    mouse(.leftMouseUp, b)
}
func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
        e.flags = flags
        e.post(tap: .cghidEventTap)
        sleep(0.03)
    }
}
enum K { static let esc: CGKeyCode = 53, ret: CGKeyCode = 36, right: CGKeyCode = 124, left: CGKeyCode = 123, h: CGKeyCode = 4, p: CGKeyCode = 35 }

// MARK: other apps

/// Brings an app to the front the way the Dock does (AppleScript `activate` from a background
/// process is ignored on recent macOS).
func front(_ app: String, bundle: String) -> Bool {
    let p = Process(); p.launchPath = "/usr/bin/open"; p.arguments = ["-a", app]; try? p.run(); p.waitUntilExit()
    for _ in 0..<30 {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle { return true }
        sleep(0.1)
    }
    return false
}

@discardableResult
func osa(_ source: String) -> String? {
    var err: NSDictionary?
    let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
    if let err { print("  applescript: \(err[NSAppleScript.errorMessage] ?? err)") }
    return r?.stringValue
}
func pid(_ bundle: String) -> pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier }
func ax<T>(_ el: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v as? T : nil
}
/// The first element with `role` under `root` (depth-first, bounded).
func find(_ root: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
    if depth > 30 { return nil }
    if (ax(root, kAXRoleAttribute) as String?) == role { return root }
    for c in (ax(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
        if let f = find(c, role: role, depth: depth + 1) { return f }
    }
    return nil
}
func selectAll(_ el: AXUIElement) {
    let text: String = ax(el, kAXValueAttribute) ?? ""
    var range = CFRange(location: 0, length: (text as NSString).length)
    let v = AXValueCreate(.cfRange, &range)!
    AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
}
func frameOf(_ el: AXUIElement) -> CGRect? {
    guard let p: AXValue = ax(el, kAXPositionAttribute), let s: AXValue = ax(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt); AXValueGetValue(s, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

// MARK: the pass

guard AXIsProcessTrusted() else { print("Give this terminal Accessibility access (System Settings ▸ Privacy & Security ▸ Accessibility)."); exit(2) }
print("Pixl Memory end-to-end pass\(live ? " (live polish)" : "")\n")

// 0. fresh launch
_ = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.pixlz.PixlMemory").map { $0.forceTerminate() }
let pk = Process(); pk.launchPath = "/usr/bin/pkill"; pk.arguments = ["-x", "PixlMemory"]; try? pk.run(); pk.waitUntilExit()
sleep(0.6)
try? FileManager.default.removeItem(at: logURL)
logMark = 0
let op = Process(); op.launchPath = "/usr/bin/open"; op.arguments = ["--env", "PIXL_DEBUG=1", appPath]; try? op.run(); op.waitUntilExit()
let launched = waitLog("launch pid", timeout: 8)
sleep(2.0)
var s = state()
record("Fresh launch with PIXL_DEBUG=1", launched && (frogg(s)["visible"] as? Bool ?? false), "log: \(launched ? "launch seen" : "no launch line")")

// TextEdit document (also the safe place to click away)
markLog()
osa(#"tell application "TextEdit" to make new document with properties {text:"teh frog sit on the windw and dont move nothing"}"#)
let teFront = front("TextEdit", bundle: "com.apple.TextEdit")
if !teFront { print("  TextEdit didn't come to the front (frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))") }
sleep(1.5)
let tePID = pid("com.apple.TextEdit")
let teArea = tePID.flatMap { p -> AXUIElement? in
    let app = AXUIElementCreateApplication(p)
    guard let w: AXUIElement = ax(app, kAXFocusedWindowAttribute) else { return nil }
    return find(w, role: kAXTextAreaRole)
}
let teFrame = teArea.flatMap(frameOf)
let hopped = waitLog("landing at", timeout: 3) || waitLog("route legs", timeout: 0.5)
s = state()
record("Window hop: Frogg follows to the TextEdit window", hopped, hopped ? "route + landing in log" : "no hop logged (may already have been there)")
let safe = teFrame.map { CGPoint(x: $0.midX, y: $0.maxY - 30) } ?? CGPoint(x: 400, y: 400)

// 1. poke
markLog(); s = state()
click(belly(s))
let poked = waitLog("mouse up clickCount=1", timeout: 1)
sleep(0.1); s = state()
let pokeFrame = frogg(s)["frame"] as? String ?? ""
sleep(NSEvent.doubleClickInterval + 0.2)
record("Poke (single click)", poked && pokeFrame.hasPrefix("poke") && !(state()["menuOpen"] as? Bool ?? true), "frame \(pokeFrame); no menu")

// 2. double-click → bubbles; keyboard; Esc
markLog(); s = state()
click(belly(s), clicks: 2)
let dbl = waitState { ($0["menuOpen"] as? Bool ?? false) && controls($0, "bubbles").count >= 4 }
let labels = dbl.map { controls($0, "bubbles").compactMap { $0["label"] as? String } } ?? []
record("Double-click opens the bubbles", dbl != nil && waitLog("bubbles open via double-click", timeout: 0.5), labels.joined(separator: " · "))
key(K.right); sleep(0.2)
key(K.esc)
let escClosed = waitState { !($0["menuOpen"] as? Bool ?? true) } != nil
record("Keyboard: → focuses, Esc closes", escClosed && waitLog("bubbles close (esc)", timeout: 1))

// 3. right-click → bubbles; click away closes
sleep(0.3); markLog(); s = state()
rightClick(belly(s))
let rc = waitState { $0["menuOpen"] as? Bool ?? false } != nil
record("Right-click opens the bubbles", rc && waitLog("bubbles open via right-click", timeout: 0.5))
click(safe)
let away = waitState { !($0["menuOpen"] as? Bool ?? true) } != nil
record("Click-away closes", away && waitLog("click away", timeout: 1))

// 4. Polish in TextEdit: Replace
func openPolishList(_ el: AXUIElement?, bundle: String = "com.apple.TextEdit", app: String = "TextEdit") -> Bool {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundle { _ = front(app, bundle: bundle) }
    if let el { selectAll(el) }
    sleep(0.3)
    s = state()
    click(belly(s), clicks: 2)
    guard let st = settledBubbles(timeout: 2, { control($0, "bubbles", "Polish") != nil }), let b = control(st, "bubbles", "Polish") else { return false }
    click(center(b))
    return waitState(timeout: 2) { controls($0, "list").count >= 2 } != nil
}
func teText() -> String { teArea.flatMap { ax($0, kAXValueAttribute) as String? } ?? "" }

if let teArea {
    markLog()
    let listOK = openPolishList(teArea)
    record("Polish with a selection: slot 1 is Polish, list opens", listOK)
    if live, listOK, let row = control(state(), "list", "Polish this") ?? controls(state(), "list").first {
        click(center(row))
        let result = waitState(timeout: 60) { control($0, "result", "Replace") != nil || control($0, "result", "OK") != nil }
        let verdict = logSince().contains("Verified") || (result.map { controls($0, "result").contains { ($0["label"] as? String ?? "").contains("checks") } } ?? false)
        record("Polish result with diff and verification", result.flatMap { control($0, "result", "Replace") } != nil, verdict ? "verified badge" : "see log")
        if let r = result, let rep = control(r, "result", "Replace") {
            let before = teText()
            click(center(rep))
            sleep(0.6)
            let after = teText()
            record("Replace writes the suggestion into TextEdit", after != before && waitLog("replace: written via AX", timeout: 1), "“\(after.prefix(60))”")
        }
        // drag-to-apply: fresh text, polish again, drag the suggestion card onto the text
        AXUIElementSetAttributeValue(teArea, kAXValueAttribute as CFString, "i has went to the store yesterday" as CFString)
        sleep(0.3)
        markLog()
        if openPolishList(teArea), let row = controls(state(), "list").first {
            click(center(row))
            if let r = waitState(timeout: 60, { control($0, "result", "Suggestion") != nil }), let card = control(r, "result", "Suggestion"),
               let tf = frameOf(teArea) {
                selectAll(teArea)
                drag(center(card), CGPoint(x: tf.minX + 60, y: tf.minY + 14), steps: 30, duration: 0.8, hold: 0.25)
                sleep(0.8)
                let dropped = waitLog("Dropped in", timeout: 2)
                record("Drag the suggestion into TextEdit", dropped && teText() != "i has went to the store yesterday", "“\(teText().prefix(60))”")
            } else { record("Drag the suggestion into TextEdit", false, "no result card") }
        } else { record("Drag the suggestion into TextEdit", false, "list didn't open") }
    } else {
        record("Polish result with diff and verification", live ? false : nil, live ? "no list row" : "run with --live")
        record("Replace writes the suggestion into TextEdit", nil, "needs --live")
        record("Drag the suggestion into TextEdit", nil, "needs --live")
        key(K.esc)
    }
} else {
    record("Polish in TextEdit", false, "couldn't find TextEdit's text area")
}
key(K.esc); sleep(0.4)

// 5. Polish without a selection: slot 1 is Ask
if let teArea {
    var none = CFRange(location: 0, length: 0)
    AXUIElementSetAttributeValue(teArea, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &none)!)
}
sleep(0.3); markLog(); s = state()
click(belly(s), clicks: 2)
let askFirst = settledBubbles { (controls($0, "bubbles").first?["label"] as? String ?? "").hasPrefix("Ask") }
record("Without a selection slot 1 is Ask", askFirst != nil)
if let st = askFirst, let ask = control(st, "bubbles", "Ask") {
    click(center(ask))
    let card = waitState { control($0, "card", "Question") != nil }
    record("Ask card opens with a question field", card != nil)
    key(K.esc); sleep(0.3)
}

// 6. Memory
func openSlot(_ name: String) -> [String: Any]? {
    sleep(0.3); s = state()
    click(belly(s), clicks: 2)
    guard let st = settledBubbles(timeout: 2, { control($0, "bubbles", name) != nil }), let b = control(st, "bubbles", name) else { return nil }
    click(center(b))
    return waitState(timeout: 4) { $0["card"] is [String: Any] }
}
markLog()
let mem = openSlot("Memory")
record("Memory card opens", mem != nil && waitLog("card open memory", timeout: 1), mem.map { "\(controls($0, "card").filter { ($0["role"] as? String) == "AXLink" }.count) highlights" } ?? "")
key(K.esc); sleep(0.3)

// 7. Wallet
markLog()
let wal = openSlot("Wallet")
let walletLabels = wal.map { controls($0, "card").compactMap { $0["label"] as? String } } ?? []
record("Wallet card opens", wal != nil, walletLabels.joined(separator: " · "))
key(K.esc); sleep(0.3)

// 8. More → settings (mini menu) and size
markLog()
if let more = openSlot("More") ?? waitState(timeout: 2, { controls($0, "list").count > 3 }) {
    _ = more
}
if let st = waitState(timeout: 2, { control($0, "list", "Pixl settings") != nil }), let row = control(st, "list", "Pixl settings") {
    click(center(row))
    let mini = waitState { $0["mini"] is [String: Any] }
    record("More ▸ Pixl settings opens the mini menu", mini != nil)
    if let mini, let three = control(mini, "mini", "3×") ?? control(mini, "mini", "3x") {
        let before = frogg(state())["scale"] as? Int ?? 0
        click(center(three))
        sleep(1.0)
        let after = frogg(state())["scale"] as? Int ?? 0
        record("Size 3× from settings", after == 3, "\(before)× → \(after)×")
        if let st2 = waitState(timeout: 2, { $0["mini"] is [String: Any] }), let two = control(st2, "mini", "2×") ?? control(st2, "mini", "2x") {
            click(center(two)); sleep(1.0)
        }
    } else {
        record("Size 3× from settings", nil, "no size control labelled 3× in the mini menu: \(controls(mini ?? [:], "mini").compactMap { $0["label"] as? String }.prefix(12))")
    }
    key(K.p, [.maskControl, .maskAlternate])   // ⌃⌥P toggles it closed
    let closed = waitState { $0["mini"] == nil || $0["mini"] is NSNull } != nil
    record("⌃⌥P closes the mini menu", closed)
} else {
    record("More ▸ Pixl settings opens the mini menu", false, "More list didn't show")
}

// 9. hide / show (⌃⌥H)
markLog()
key(K.h, [.maskControl, .maskAlternate])
let hid = waitState { !(frogg($0)["visible"] as? Bool ?? true) } != nil
key(K.h, [.maskControl, .maskAlternate])
let back = waitState { frogg($0)["visible"] as? Bool ?? false } != nil
record("⌃⌥H hides and shows (drop-in on show)", hid && back && waitLog("hop start (drop-in)", timeout: 1))

// 10. throw
sleep(1.2); markLog(); s = state()
let b0 = belly(s)
drag(b0, CGPoint(x: b0.x - 260, y: b0.y - 180), steps: 8, duration: 0.12, hold: 0.08)
let thrown = waitLog("motion start", timeout: 3) || logSince().contains("flight") || logSince().contains("throw")
let settled = waitState(timeout: 5) { (frogg($0)["mode"] as? String) == "perched" && !(frogg($0)["moving"] as? Bool ?? true) } != nil
record("Grab and throw, lands and settles", thrown && settled)

// 11. Chrome textarea polish (optional)
if chrome {
    _ = front("Google Chrome", bundle: "com.google.Chrome")
    osa(#"tell application "Google Chrome" to open location "data:text/html,<title>Pixl e2e</title><textarea id=t style='width:500px;height:120px'>me and him is going to the meting tomorow</textarea>""#)
    sleep(2.0)
    if let cp = pid("com.google.Chrome") {
        let app = AXUIElementCreateApplication(cp)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        sleep(0.8)
        let w: AXUIElement? = ax(app, kAXFocusedWindowAttribute)
        let area = w.flatMap { find($0, role: kAXTextAreaRole) }
        markLog()
        let ok = openPolishList(area, bundle: "com.google.Chrome", app: "Google Chrome")
        record("Chrome: selection read, Polish offered", ok && area != nil)
        if live, ok, let row = controls(state(), "list").first {
            click(center(row))
            if let r = waitState(timeout: 60, { control($0, "result", "Replace") != nil }), let rep = control(r, "result", "Replace") {
                let before: String = area.flatMap { ax($0, kAXValueAttribute) } ?? ""
                click(center(rep)); sleep(0.8)
                let after: String = area.flatMap { ax($0, kAXValueAttribute) } ?? ""
                let viaAX = logSince().contains("replace: written via AX")
                record("Chrome: Replace", after != before && viaAX, viaAX ? "“\(after.prefix(60))”" : "fell back to copy")
            } else { record("Chrome: Replace", false, "no result") }
        }
        osa(#"tell application "Google Chrome" to close (tabs of window 1 whose title is "Pixl e2e")"#)
    }
    key(K.esc)
}

// 12. Spaces (optional): fast and slow switches, Frogg never hides or drops
if spaces {
    for (name, pause) in [("slow", 1.6), ("fast", 0.35)] {
        markLog()
        var minVisible = true
        key(K.right, [.maskControl]); sleep(pause)
        if !(frogg(state())["visible"] as? Bool ?? false) { minVisible = false }
        key(K.left, [.maskControl]); sleep(pause)
        if !(frogg(state())["visible"] as? Bool ?? false) { minVisible = false }
        sleep(1.2)
        let log = logSince()
        let seen = log.components(separatedBy: "space: change seen").count - 1
        let drops = log.components(separatedBy: "hop start (drop-in)").count - 1
        let landed = waitState(timeout: 3) { !(frogg($0)["moving"] as? Bool ?? true) } != nil
        record("Space switches (\(name))", seen >= 2 && drops == 0 && minVisible && landed, "\(seen) changes, \(drops) drop-ins, visible \(minVisible)")
    }
}

osa(#"tell application "TextEdit" to close (documents whose name starts with "Untitled") saving no"#)

print("\n| Step | Result | Note |\n|---|---|---|")
for (step, r, note) in results { print("| \(step) | \(r) | \(note.replacingOccurrences(of: "|", with: "/")) |") }
let failed = results.filter { $0.1 == "FAIL" }.count
print("\n\(results.filter { $0.1 == "PASS" }.count) passed, \(failed) failed, \(results.filter { $0.1 == "SKIP" }.count) skipped")
exit(failed == 0 ? 0 : 1)
