import AppKit
import ApplicationServices
import PixlMemoryKit
import PixlzCore

/// Behavior ▸ Roam. Every 20–45 s, if you aren't typing and nothing is open, the Pixl goes on
/// an outing in its own style (Kit `RoamPlanner`). It reads along in code apps after you stop
/// typing, backs off for a few minutes when poked right after an outing, and never covers your
/// caret or the window you're working in. Uses window frames, desktop folder positions, the
/// caret position and the front app's name: all local; never your text, never the screen.
@MainActor
final class RoamController {
    unowned let app: AppController
    var planner: RoamPlanner
    var timer: Timer?
    var watch: Timer?
    var quietUntil = Date.distantPast
    var lastOutingEnd = Date.distantPast
    var outingSince: Date?
    /// Out on an outing: one was started and the Pixl is still playing it (a cancelled one is over).
    var outing: Bool { outingSince != nil && app.moving }
    var typingSince: Date?
    var typedFor: TimeInterval = 0
    var thread: ThreadPanel?
    var foldersCache: (at: Date, rects: [CGRect])?

    static let codeApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.anthropic.claudefordesktop", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.sublimetext.4", "com.panic.Nova",
    ]

    init(app: AppController) {
        self.app = app
        planner = RoamPlanner(style: Self.style, seed: UInt64(Date().timeIntervalSince1970))
    }

    static var style: RoamStyle {
        RoamStyle.of(id: PixlSkins.currentID, movement: PixlSkins.current.manifest.movement.rawValue)
    }

    var on: Bool { app.settings.roams }

    /// Settings or the skin changed.
    func refresh() {
        if planner.style != Self.style { planner = RoamPlanner(style: Self.style, seed: UInt64(Date().timeIntervalSince1970)) }
        timer?.invalidate(); watch?.invalidate()
        guard on else {
            if app.roamHanging != nil { app.roamHanging = nil; app.userPlaced = false; app.reposition(force: true) }
            return
        }
        schedule(in: 6)   // a first outing soon after you switch it on
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.watchTyping() } }
        watch?.tolerance = 0.3
    }

    func schedule(in seconds: TimeInterval? = nil) {
        timer?.invalidate()
        guard on else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds ?? planner.pause(), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.go() }
        }
        timer?.tolerance = 1
    }

    /// Calm enough to wander: perched, nothing open or running, you're not typing, not told to sit.
    var free: Bool { blocker() == nil }

    /// Why it can't go right now (for the debug log), or nil.
    func blocker(ignoringPresence: Bool = false) -> String? {
        if !on { return "calm" }
        if outing { return "already out" }
        if Date() < quietUntil { return "told to sit still" }
        if app.paused || app.userHidden || app.fullscreenHidden || app.awayOn != nil { return "hidden or away" }
        if app.mode != .perched || app.moving || app.busy { return "busy moving" }
        if app.menu.isOpen || app.game.isOn || app.focusUntil != nil { return "menu, game or focus" }
        if app.foot == nil { return "not placed" }
        if !ignoringPresence, app.presence.typing { return "you're typing" }
        if !ignoringPresence, app.presence.presence.mood == .napping { return "napping (you're away)" }
        return nil
    }

    func go(_ forced: Outing? = nil, debug: Bool = false) {
        if let why = blocker(ignoringPresence: debug) { Debug.log("roam: not now (\(why))"); schedule(in: 8); return }
        let w = world()
        var p = planner
        guard let o = forced ?? p.next(w) else { planner = p; schedule(); return }
        planner = p
        Debug.log("roam: \(o.name) (\(planner.style.rawValue)\(w.codeContext ? ", code app" : ""))")
        let c = RoamPlanner.choreography(o, from: w.foot, style: planner.style, hanging: app.roamHanging) { [unowned self] a, b in
            Choreography.hop(self.app.route(from: a, to: b))
        }
        guard c.duration > 0 else { schedule(); return }
        outingSince = Date()
        let end = c.pose(at: c.duration).pose
        app.run(c, target: nil, roam: true) { [weak self] in
            guard let self else { return }
            self.outingSince = nil
            self.lastOutingEnd = Date()
            self.app.roamHanging = end.thread
            self.app.userPlaced = true   // stay here until you switch windows
            if end.thread != nil { self.app.holdSurface(end) }
            self.schedule()
        }
    }

    // MARK: reading along

    /// After a long stretch of typing in a code app, the Pixl comes to read along.
    func watchTyping() {
        let typing = app.presence.typing
        if typing {
            if typingSince == nil { typingSince = Date() }
            typedFor = Date().timeIntervalSince(typingSince!)
            return
        }
        defer { typingSince = nil; typedFor = 0 }
        guard typingSince != nil, typedFor >= 20, isCodeApp, free else { return }
        var p = planner
        let w = world()
        if let o = p.glanceNow(w) {
            planner = p
            Debug.log("roam: read along after \(Int(typedFor)) s of typing")
            app.later(1.5) { [weak self] in self?.go(o) }
        }
    }

    var isCodeApp: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(Self.codeApps.contains) ?? false }

    // MARK: backing off

    /// Poked right after (or during) an outing: it gets the message.
    func poked() {
        guard on, outing || Date().timeIntervalSince(lastOutingEnd) < 10 else { return }
        quietUntil = Date().addingTimeInterval(180)
        app.say("Okay, okay. I'll sit still for a bit.", for: 2.5)
        Debug.log("roam: poked after an outing, quiet for 3 min")
    }

    /// You put it somewhere: it stays a while.
    func dragged() {
        guard on else { return }
        quietUntil = Date().addingTimeInterval(120)
    }

    // MARK: the world

    func world() -> RoamWorld {
        let me = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        // front to back; window bounds are already top-left global coordinates (no Screen Recording needed)
        let windows: [CGRect] = infos.compactMap { i in
            guard (i[kCGWindowLayer as String] as? Int) == 0, (i[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let b = i[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return r.width > 160 && r.height > 100 ? r : nil
        }
        let active = app.settings.perchOnWindows ? app.watcher.activeWindowFrame : nil
        // other windows whose top edge isn't hidden behind a window in front of them
        var others: [CGRect] = []
        for (i, r) in windows.enumerated() {
            if let a = active, abs(a.minX - r.minX) < 2, abs(a.minY - r.minY) < 2 { continue }
            let top = CGPoint(x: r.midX, y: r.minY - 2)
            if !windows[..<i].contains(where: { $0.contains(top) }) { others.append(r) }
        }
        let folders = desktopFolders().filter { f in !windows.contains { $0.intersects(f) } }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let avoid = AX.trusted && pid != nil ? AX.selectionBounds(pid: pid!) : []
        return RoamWorld(screens: app.screensTopLeft, active: active, others: others, folders: folders, avoid: avoid,
                         cursor: app.mouseTopLeft, foot: app.foot ?? .zero, sprite: app.spriteSize,
                         codeContext: isCodeApp, hanging: app.roamHanging)
    }

    /// Folders on the desktop, from Finder's Accessibility tree (positions only; names are
    /// used just to tell a folder from a file and never leave this function).
    func desktopFolders() -> [CGRect] {
        if let c = foldersCache, Date().timeIntervalSince(c.at) < 30 { return c.rects }
        var rects: [CGRect] = []
        if AX.trusted, let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let root = AXUIElementCreateApplication(finder.processIdentifier)
            let desk = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
            let kids: [AXUIElement] = AX.attr(root, kAXChildrenAttribute) ?? []
            for area in kids where (AX.attr(area, kAXRoleAttribute) as String?) == "AXScrollArea" {
                for group in (AX.attr(area, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    for icon in (AX.attr(group, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                        guard let name: String = AX.attr(icon, kAXTitleAttribute), let r = AX.frame(of: icon) else { continue }
                        var dir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: desk.appendingPathComponent(name).path, isDirectory: &dir), dir.boolValue {
                            rects.append(r)
                        }
                    }
                }
            }
        }
        foldersCache = (Date(), rects)
        return rects
    }
}

/// Silk's thread: a thin line from where it's tied down to the spider.
@MainActor
final class ThreadPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 3, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = ThreadView()
    }

    /// From `anchor` down to `end` (top-left global coordinates).
    func show(from anchor: CGPoint, to end: CGPoint, primaryHeight: CGFloat) {
        let h = max(1, end.y - anchor.y)
        setFrame(NSRect(x: anchor.x - 1.5, y: primaryHeight - end.y, width: 3, height: h), display: true)
        orderFrontRegardless()
    }
}

final class ThreadView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // silk: a light strand with a faint dark edge, visible on light and dark backgrounds
        NSColor(white: 0, alpha: 0.18).setFill(); NSRect(x: 1.5, y: 0, width: 1, height: bounds.height).fill()
        NSColor(srgbRed: 0.86, green: 0.88, blue: 0.93, alpha: 0.95).setFill(); NSRect(x: 0.5, y: 0, width: 1, height: bounds.height).fill()
    }
}
