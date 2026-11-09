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
    var pond: PropPanel?
    var webs: [(panel: PropPanel, at: Date)] = []
    var wasOn = false
    var lastChatter = Date.distantPast

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
    /// `kick`: you just switched it on, so the first outing starts right away.
    func refresh() {
        if planner.style != Self.style { planner = RoamPlanner(style: Self.style, seed: UInt64(Date().timeIntervalSince1970)) }
        timer?.invalidate(); watch?.invalidate()
        defer { wasOn = on }
        guard on else {
            clearWebs()
            if app.roamHanging != nil { app.roamHanging = nil; app.userPlaced = false; app.reposition(force: true) }
            return
        }
        if !wasOn {
            // just switched on (or launched with it on): off on an outing almost at once
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.go(debug: true) }
            }
        } else {
            schedule()
        }
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
        func r(_ x: CGRect) -> String { "\(Int(x.minX)),\(Int(x.minY)) \(Int(x.width))×\(Int(x.height))" }
        Debug.log("roam world: screen \(r(w.screen)) active \(w.active.map(r) ?? "none") others \(w.others.count) folders \(w.folders.count) avoid [\(w.avoid.map(r).joined(separator: "; "))] sprite \(Int(w.sprite.width))×\(Int(w.sprite.height)) foot \(Int(w.foot.x)),\(Int(w.foot.y))")
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
        if case .pond = o { showPond(at: w.foot) }
        let webCorners: [CGPoint]
        // a cobweb in the top corner of any wall it climbs
        if case .crawl(let legs, _) = o, let wall = legs.first(where: { $0.surface == .rightWall || $0.surface == .leftWall }), wall.to.y < wall.from.y {
            webCorners = [wall.to]
        } else { webCorners = [] }
        app.run(c, target: nil, roam: true) { [weak self] in
            guard let self else { return }
            self.outingSince = nil
            self.lastOutingEnd = Date()
            self.app.roamHanging = end.thread
            self.app.userPlaced = true   // stay here until you switch windows
            if end.surface != .floor { self.app.holdSurface(end) }   // on its thread or a wall: stays there
            self.hidePond()
            webCorners.forEach { self.leaveWeb(at: $0) }
            self.flourish()
            if let anchor = end.thread, Bool.random() { self.leaveWeb(at: anchor, small: true) }
            self.schedule()
        }
    }

    /// Between outings: now and then a little show in place (its signature, an idle quirk), or
    /// what it's up to in its own words ("Weaving…"), at most every 90 s.
    func flourish() {
        guard app.roamHanging == nil, app.frogg.surface == .floor, !app.presence.typing else { return }
        let roll = Int.random(in: 0..<10)
        if roll < 3, Date().timeIntervalSince(lastChatter) > 90 {
            lastChatter = Date()
            app.voice(PixlVoice.doing(ui: app.ui), for: 2.4)
        } else if roll < 6 {
            app.later(0.4) { [weak self] in self?.app.signature() }
        }
    }

    // MARK: reading along

    /// After a long stretch of typing in a code app, the Pixl comes to read along.
    func watchTyping() {
        if pond != nil, !outing { hidePond() }   // an outing cut short leaves no pond behind
        webs.removeAll { w in
            guard Date().timeIntervalSince(w.at) > 600 else { return false }   // webs fade after 10 min
            w.panel.orderOut(nil); return true
        }
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

    // MARK: props

    /// Frogg's pond: a little drawn pool at its feet while it's under.
    func showPond(at foot: CGPoint) {
        let w = app.spriteSize.width * 1.15, h: CGFloat = 26
        let panel = PropPanel(size: NSSize(width: w, height: h)) { r in
            let scale: CGFloat = 2
            for y in stride(from: 0, to: r.height, by: scale) {
                for x in stride(from: 0, to: r.width, by: scale) {
                    let nx = (x + scale / 2 - r.midX) / (r.width / 2), ny = (y + scale / 2 - r.midY) / (r.height / 2)
                    let d = nx * nx + ny * ny
                    guard d <= 1 else { continue }
                    let rim = d > 0.72
                    let ripple = !rim && Int(x / scale + y / scale) % 9 == 0 && ny > -0.2
                    (rim ? NSColor(srgbRed: 0.25, green: 0.45, blue: 0.72, alpha: 1)
                         : ripple ? NSColor(srgbRed: 0.72, green: 0.86, blue: 1, alpha: 1) : NSColor(srgbRed: 0.35, green: 0.62, blue: 0.92, alpha: 1)).setFill()
                    NSRect(x: x, y: y, width: scale, height: scale).fill()
                }
            }
        }
        panel.place(center: CGPoint(x: foot.x, y: foot.y - 8), primaryHeight: app.primaryHeight)
        pond = panel
    }

    func hidePond() { pond?.orderOut(nil); pond = nil }

    /// Silk's cobweb: in a corner it climbed past, or where it hung. At most four; each fades after 10 min.
    func leaveWeb(at p: CGPoint, small: Bool = false) {
        let size: CGFloat = small ? 46 : 92
        let sc = app.screensTopLeft.first { $0.insetBy(dx: -8, dy: -8).contains(p) } ?? app.screensTopLeft.first ?? .zero
        let right = p.x > sc.midX
        // tucked into the corner: its radial lines start from the corner point
        let origin = small ? CGPoint(x: p.x - size / 2, y: p.y) : CGPoint(x: right ? sc.maxX - size : sc.minX, y: sc.minY)
        let panel = PropPanel(size: NSSize(width: size, height: size)) { r in
            NSColor(srgbRed: 0.86, green: 0.88, blue: 0.93, alpha: 0.85).setStroke()
            // corner at the top (AppKit y-up: maxY); radials fan out down and inward
            let c = small ? CGPoint(x: r.midX, y: r.maxY) : CGPoint(x: right ? r.maxX : r.minX, y: r.maxY)
            let dir: CGFloat = right ? -1 : 1
            let angles: [CGFloat] = small ? [-150, -120, -90, -60, -30].map { $0 * .pi / 180 } : [0, 22, 45, 68, 90].map { $0 * .pi / 180 }
            func point(_ a: CGFloat, _ rad: CGFloat) -> CGPoint {
                small ? CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad) : CGPoint(x: c.x + dir * cos(a) * rad, y: c.y - sin(a) * rad)
            }
            let reach = small ? size / 2 : size
            let path = NSBezierPath(); path.lineWidth = 1
            for a in angles { path.move(to: c); path.line(to: point(a, reach)) }
            for k in stride(from: 0.3, through: 0.9, by: 0.3) {
                let rad = reach * k
                path.move(to: point(angles[0], rad))
                for a in angles.dropFirst() { path.line(to: point(a, rad)) }
            }
            path.stroke()
        }
        panel.place(center: CGPoint(x: origin.x + size / 2, y: origin.y + size / 2), primaryHeight: app.primaryHeight)
        webs.append((panel, Date()))
        if webs.count > 4 { webs.removeFirst().panel.orderOut(nil) }
        Debug.log("roam: a web at (\(Int(p.x)),\(Int(p.y)))")
    }

    func clearWebs() { webs.forEach { $0.panel.orderOut(nil) }; webs = [] }

    // MARK: backing off

    /// Poked right after (or during) an outing: it gets the message.
    func poked() {
        guard on, outing || Date().timeIntervalSince(lastOutingEnd) < 10 else { return }
        quietUntil = Date().addingTimeInterval(180)
        app.chatter("Okay, okay. I'll sit still for a bit.")
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
                         codeContext: isCodeApp, hanging: app.roamHanging, surface: app.frogg.surface)
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

/// A drawn prop (a pond, a cobweb): click-through, above other windows, on every Space.
@MainActor
final class PropPanel: NSPanel {
    init(size: NSSize, draw: @escaping (NSRect) -> Void) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = PropView(draw: draw)
    }

    /// Centre at `center` (top-left global coordinates).
    func place(center: CGPoint, primaryHeight: CGFloat) {
        setFrameOrigin(NSPoint(x: center.x - frame.width / 2, y: primaryHeight - center.y - frame.height / 2))
        orderFrontRegardless()
    }
}

final class PropView: NSView {
    let drawing: (NSRect) -> Void
    init(draw: @escaping (NSRect) -> Void) { drawing = draw; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { drawing(bounds) }
}
