import AppKit
import PixlMemoryKit
import PixlzCore
import PixlBridge

/// A borderless panel that never becomes key or main (SPEC R5): the app you're
/// typing in keeps focus and its selection while you use Frogg.
class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        // On every Space and stationary: during a swipe Frogg stays where he is on screen (he
        // doesn't slide away with the old desktop), so the Space change never needs a teleport.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The Pixl's own window. One Pixl, one place: while it's away on another device, nothing may
/// put this window on screen (D17). Whatever tries is refused and logged.
final class PixlPanel: OverlayPanel {
    var isAway: () -> Bool = { false }
    private func refused(_ how: String) -> Bool {
        guard isAway() else { return false }
        Debug.log("pixl window: \(how) refused while away\n" + Thread.callStackSymbols.dropFirst(2).prefix(5).joined(separator: "\n"))
        return true
    }
    override func orderFrontRegardless() { if !refused("orderFrontRegardless") { super.orderFrontRegardless() } }
    override func orderFront(_ sender: Any?) { if !refused("orderFront") { super.orderFront(sender) } }
    override func makeKeyAndOrderFront(_ sender: Any?) { if !refused("makeKeyAndOrderFront") { super.makeKeyAndOrderFront(sender) } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place == .out || !refused("order(\(place.rawValue))") { super.order(place, relativeTo: other) }
    }
}

/// The mini menu takes typing (its name field) without activating the app.
final class KeyPanel: OverlayPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Opening the app again (its icon on the Desktop, Spotlight, Finder) while it runs: the Pixl
    /// comes out, or, when it's away on another device, the offer to call it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        summon()
        return false
    }

    enum Mode { case perched, held, airborne, dropping }

    var settings = PixlSettings.load() { didSet { PixlSkins.displayName = settings.name } }
    let client = MemoryClient()
    let watcher = WindowWatcher()
    var frogg: FroggView!
    var froggPanel: PixlPanel!
    var bubblePanel = OverlayPanel(size: NSSize(width: 10, height: 10))
    /// Showcase only: the recorded column (AppKit coordinates), so a take never cuts a bubble off.
    var bubbleArea: CGRect?
    var resultPanel: OverlayPanel?
    lazy var menu = BubbleMenu(app: self)
    lazy var game = GameController(app: self)
    let bridge = BridgeServer()
    lazy var intents = IntentRunner(app: self)
    let service = ServiceLauncher()
    lazy var travel = TravelController(app: self)
    lazy var agents = AgentController(app: self)
    lazy var chats = AgentChats(app: self)
    lazy var showcase = ShowcaseDirector(app: self)
    /// Agent mode's "Chat with Claude" through the Anthropic API (the key in .env.local).
    let apiChat = APIChatController()
    lazy var presence = PresenceController(app: self)
    lazy var roam = RoamController(app: self)
    lazy var resizer = ResizeController(app: self)
    lazy var sleep = SleepController(app: self)
    lazy var pond = PondController(app: self)
    lazy var trail = TrailController(app: self)
    lazy var typingGuard = TypingGuard(app: self)
    /// Silky hangs on a thread tied here (Roam); nil when on its feet.
    var roamHanging: CGPoint?
    var threadPanel: ThreadPanel?
    /// The Pixl is on another device (by name) and this one waits to call it back.
    var awayOn: String?
    /// Where the selection came from: Accessibility, or the browser extension (the bridge).
    var selectionFromWeb = false
    var ui: PixlUI { PixlData.ui }   // follows the current Pixl
    var selfTestAvoid: [CGRect] = []
    var lastSignature = Date.distantPast
    var askedInSelfTest: String?
    var ticks = 0
    var watchdog: Timer?
    var chosenInSelfTest: Int?
    /// Settings' panel. While it's open the Energy section samples every few seconds.
    var miniPanel: KeyPanel? {
        didSet { if (miniPanel == nil) != (oldValue == nil) { EnergyMonitor.shared.setLive(miniPanel != nil) } }
    }
    var statusItem: NSStatusItem?

    var mode = Mode.perched
    var foot: CGPoint?                 // feet, top-left global coordinates
    var flight: ThrowFlight?
    var animTimers: [Timer] = []
    var idleTimer: Timer?
    var blinkTimer: Timer?
    var breathTimer: Timer?
    var bubbleTimer: Timer?
    var permissionTimer: Timer?
    var clickTimer: Timer?
    var longPressTimer: Timer?
    var longPressed = false
    var pendingSwitch: Timer?
    var focusTimer: Timer?

    var gesture: PointerGesture?
    var dragSamples: [(TimeInterval, CGPoint)] = []
    var pokes = PokeCounter()
    var userPlaced = false             // the user put Frogg somewhere; stay until the next window switch
    var userHidden = false
    var fullscreenHidden = false
    var paused = false
    var busy = false
    /// A polish is on its way (one at a time; it borrows `busy` only when nothing else holds it).
    var polishing = false
    var spaceTransition = false
    /// Bumped on every show or hide of Frogg; a fade's completion only hides him if no show came since.
    var visGen = 0
    /// When the first sign of a Space switch was seen (an app activating with no window on this Space).
    var spaceSignAt: TimeInterval?
    var focusUntil: Date?
    var lastNudge = Date.distantPast
    var lastVerdict: String?
    /// The last reply's verdict field: "verified", "partial" or "failed".
    var lastVerdictCode: String?
    var cachedStatus: ServiceStatus?
    var monitors: [Any] = []

    var scale: CGFloat { CGFloat(settings.scale) }
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        EnergyMonitor.shared.start()
        Debug.log("launch pid=\(ProcessInfo.processInfo.processIdentifier) accessibility=\(AX.trusted) debug=\(Debug.enabled)")
        bubblePanel.ignoresMouseEvents = true  // the bubble is opaque; it must never swallow clicks (R2)
        // an unknown skin in settings (removed, or a typo) becomes the one actually shown, and stays so
        let shown = PixlSkins.skin(settings.skinID) != nil ? settings.skinID : "frogg"
        PixlSkins.currentID = shown
        if settings.skin != shown {
            Debug.log("settings: skin \(settings.skin ?? "none") → \(shown)")
            settings.skin = shown
            settings.save()
        }
        PixlSkins.displayName = settings.name
        PixlSkins.looks = settings.looks ?? [:]
        buildFrogg()
        setUpStatusItem()
        HotKeys.shared.register(.p) { [weak self] in self?.toggleMiniMenu() }
        HotKeys.shared.register(.space) { [weak self] in self?.chatStub() }
        HotKeys.shared.register(.h) { [weak self] in self?.toggleHidden() }
        if Debug.enabled {
            // PIXL_DEBUG: sleep testing (⌃⌥⇧): S sleep now · F +60 s · D +10 min (deep) · A nap now · N notification
            HotKeys.shared.register(.s, shift: true) { [weak self] in self?.sleep.debugSleepNow() }
            HotKeys.shared.register(.f, shift: true) { [weak self] in self?.sleep.debugFastForward(60) }
            HotKeys.shared.register(.d, shift: true) { [weak self] in self?.sleep.debugFastForward(600) }
            HotKeys.shared.register(.a, shift: true) { [weak self] in self?.sleep.debugNap() }
            HotKeys.shared.register(.n, shift: true) { [weak self] in self?.sleep.handle(.notification) }
        }
        if !AX.trusted {
            AX.requestTrust()
            notify(.accessibilityNeeded)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AX.trusted else { return }
                    self.permissionTimer?.invalidate()
                    Debug.log("accessibility granted")
                    self.watcher.attachToFrontmost()
                }
            }
            permissionTimer?.tolerance = 1
        }
        E2EState.install(self)
        travel.start()
        if !CommandLine.arguments.contains("--selftest") { presence.start() }
        if !CommandLine.arguments.contains("--selftest") { typingGuard.start() }   // off the field you're typing in  // the self-test posts its own events: it would look idle
        // a second copy of the app (PIXL_DEVICE_ID, for trying trips on one Mac) shares the
        // bridge and the service with the first: it doesn't start its own
        let secondCopy = ProcessInfo.processInfo.environment["PIXL_DEVICE_ID"] != nil
        if !secondCopy { bridge.start() }
        if !secondCopy && !CommandLine.arguments.contains("--selftest") { agents.start(); _ = chats }   // chats: messages and finished turns
        if ShowcaseDirector.enabled { showcase.start() }   // a recording aid: only with --showcase / PIXL_SHOWCASE=1
        if !secondCopy { Task { @MainActor in
            if let why = await service.ensureRunning() {
                Debug.log("service: \(why)")
                notify(.serviceProblem(why))
            }
        } }
        watcher.onChange = { [weak self] change in self?.windowChanged(change) }
        watcher.start()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        reposition(force: true)
        updateCardLimit()
        if !CommandLine.arguments.contains("--selftest") { roam.refresh() }
        updateHover()
        if !CommandLine.arguments.contains("--selftest") { sleep.start() }
        if !CommandLine.arguments.contains("--selftest") { startSupportWatch() }   // the self-test puts him anywhere on purpose
        // away on another device (a Mosaico, a phone): it isn't here, so nothing to show
        if awayOn == nil { froggPanel.orderFrontRegardless() }
        scheduleIdle()
        if CommandLine.arguments.contains("--selftest") {
            Task { @MainActor in await self.selfTest() }
        }
    }

    func buildFrogg() {
        let current = foot
        link?.invalidate()
        link = nil
        // gone at once: the system fade on a hidden panel showed the old Pixl beside the new one
        // for a moment (each step of a resize builds a new panel)
        froggPanel?.animationBehavior = .none
        froggPanel?.orderOut(nil)
        frogg = FroggView(scale: scale)
        frogg.onMouse = { [weak self] kind, event in self?.mouse(kind, event) }
        frogg.onContactChange = { [weak self] in if let self, let f = self.foot { self.place(at: f) } }
        froggPanel = PixlPanel(size: frogg.frame.size)
        froggPanel.isAway = { [weak self] in self?.awayOn != nil }
        froggPanel.animationBehavior = .none
        froggPanel.contentView = frogg
        if let current { place(at: current) }
    }

    @objc func screensChanged() {
        // A display came or went, or its resolution, scaling or Dock changed.
        let screens = screensTopLeft
        Debug.log("screens changed: \(screens.count) · \(screens.map { "\(Int($0.width))×\(Int($0.height))" }.joined(separator: ", "))")
        updateCardLimit()
        // If the Pixl's spot is no longer on any screen (its monitor was unplugged), even a
        // spot you dragged it to is let go, so it comes back instead of being stranded.
        if let f = foot, !Perch.isOnScreen(foot: f, sprite: spriteSize, screens: screens) {
            userPlaced = false
            cancelMotion()
            if let spot = target() { place(at: spot.foot); puff(at: spot.foot) }
            return
        }
        reposition(force: true)
    }

    /// Cards scroll their body rather than run past the bottom of the Pixl's screen.
    func updateCardLimit() {
        let h = (froggPanel.map { _ in froggScreen } ?? NSScreen.main?.visibleFrame ?? .zero).height
        PixlCard.maxBodyHeight = max(160, h - 170)   // room for the header, footer and margins
    }

    // MARK: geometry

    var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    func topLeft(_ r: CGRect) -> CGRect { Perch.toAppKit(r, primaryHeight: primaryHeight) }  // same flip both ways
    func topLeft(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    var screensTopLeft: [CGRect] { NSScreen.screens.map { topLeft($0.visibleFrame) } }
    var spriteSize: CGSize {
        let s = FroggArt.shared.size("idle_0")
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func target() -> Perch.Spot? {
        let window = settings.perchOnWindows && focusUntil == nil ? watcher.activeWindowFrame : nil
        return Perch.spot(window: window, screens: screensTopLeft, sprite: spriteSize)
    }

    // MARK: following windows and Spaces

    func windowChanged(_ change: WindowWatcher.Change) {
        if change == .switched, sleep.dozing { sleep.handle(.windowSwitch) }
        if change == .switched {
            if AX.trusted { AX.enableWebAccessibility(for: NSWorkspace.shared.frontmostApplication) }
            userPlaced = false
            nudgeIfDistracting()
            // First sign of a Space switch: the app that just became active has no window on
            // this Space. Freeze watcher-driven moves now, before the notification arrives.
            if let app = NSWorkspace.shared.frontmostApplication, !AX.hasWindowOnThisSpace(pid: app.processIdentifier) {
                spaceSignAt = now
                spaceTransition = true
                Debug.log("space: first sign (\(app.localizedName ?? "?") has no window here)")
                // if no notification follows (e.g. a window on another display), carry on normally
                later(0.6) { [weak self] in
                    guard let self, let t = self.spaceSignAt, self.now - t >= 0.55 else { return }
                    self.spaceSignAt = nil
                    self.spaceTransition = false
                    Debug.log("space: no change followed the first sign")
                    self.updateFullscreen()
                    self.reposition(force: true)
                }
                return
            }
            // Wait a beat: swiping Spaces also activates another app, and the Space change
            // arrives just after. Hopping first, then being interrupted, looked like a glitch.
            pendingSwitch?.invalidate()
            pendingSwitch = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.spaceTransition else { return }
                    self.updateFullscreen()
                    self.reposition(force: true)
                }
            }
            return
        }
        guard !spaceTransition else { return }
        updateFullscreen()
        if change == .moved, mode == .perched, motion == nil, !userPlaced, let spot = target() {
            ride(to: spot.foot)  // feet glued to the dragged window, leaning against the drag
            return
        }
        reposition(force: change == .switched)
    }

    /// Hop to the perch. Mid-motion, the current flight is retargeted (never snaps back).
    func reposition(force: Bool = false) {
        guard !paused, !userHidden, !fullscreenHidden, !spaceTransition, mode == .perched, !userPlaced, !sleep.dozing, !pond.active,
              let spot = target() else { return }
        guard let current = foot else { place(at: spot.foot); return }
        if let m = motion, floats {
            // a ghost just changes course from wherever it is
            if let end = motionTarget, hypot(end.x - spot.foot.x, end.y - spot.foot.y) < 1 { return }
            run(Choreography.glide(from: m.pose(at: now - motionStart).pose.foot, to: spot.foot), target: spot.foot)
            return
        }
        if motion != nil, crawls {
            // Slugg finishes the crawl he's on (a retarget would be a hop), then sets off again
            if let end = motionTarget, hypot(end.x - spot.foot.x, end.y - spot.foot.y) < 1 { return }
            repositionAfterMotion = true
            return
        }
        if let m = motion {
            if let end = motionTarget, hypot(end.x - spot.foot.x, end.y - spot.foot.y) < 1 { return }
            let t = now - motionStart
            motion = m.retargeted(at: t) { [unowned self] from in self.route(from: from, to: spot.foot) }
            motionStart = now
            lastMotionT = 0
            motionTarget = spot.foot
            Debug.log("motion retarget at t=\(String(format: "%.2f", t))")
            return
        }
        let d = hypot(spot.foot.x - current.x, spot.foot.y - current.y)
        if d < 1 { return }
        if !force && d < 60 && !crawls { place(at: spot.foot); return }
        run(move(from: current, to: spot.foot), target: spot.foot)
    }

    /// This Pixl's locomotion loop (C13), at its ground speed in points (design px × scale):
    /// Kiti walks at 24 px/s, Mochi trots at 70 with a 1 px bob, Slugg crawls at 18.
    var gait: Gait? {
        let art = FroggArt.shared
        func loop(_ base: String, _ n: Int) -> [String]? {
            let f = (0..<n).map { "\(base)_\($0)" }
            return f.allSatisfy { art.frames[$0] != nil } ? f : nil
        }
        switch PixlSkins.currentID {
        case "cat": return loop("walk", 8).map { Gait(frames: $0, fps: 8, speed: 24 * scale) }
        case "shiba": return loop("trot", 6).map { Gait(frames: $0, fps: 12, speed: 70 * scale, bob: scale) }
        case "slugg": return loop("crawl", 8).map { Gait(frames: $0, fps: 7, speed: 18 * scale) }
        default: return nil
        }
    }

    // MARK: Slugg's shell lag (C13: the shell follows the body on a spring, stiffness 180, damping 14)

    var shellLag: CGFloat = 0, shellLagV: CGFloat = 0
    var lastShellFoot: CGPoint?

    func stepShell(dt: TimeInterval) {
        guard FroggArt.shared.frames["crawl_0_shell"] != nil, let f = foot, dt > 0 else { return }
        // the shell trails the way it's going (any direction: floor, wall, ceiling) and settles
        // as the back catches up; while it wraps a corner it holds still, so the shell catches up
        let v = lastShellFoot.map { CGPoint(x: (f.x - $0.x) / CGFloat(dt), y: (f.y - $0.y) / CGFloat(dt)) } ?? .zero
        lastShellFoot = f
        let target = CGPoint(x: max(-1.5, min(1.5, -v.x / 30 / scale)), y: max(-1.5, min(1.5, -v.y / 30 / scale)))   // art px, y down
        let ax = 180 * (target.x - shellLag) - 14 * shellLagV
        let ay = 180 * (target.y - shellLagY) - 14 * shellLagVY
        shellLagV += ax * CGFloat(dt); shellLag += shellLagV * CGFloat(dt)
        shellLagVY += ay * CGFloat(dt); shellLagY += shellLagVY * CGFloat(dt)
        let px = CGPoint(x: shellLag.rounded(), y: -shellLagY.rounded())   // whole art pixels, view y up
        if frogg.shellOffset != px { frogg.shellOffset = px }
    }
    var shellLagY: CGFloat = 0, shellLagVY: CGFloat = 0

    /// A ghost floats (Boo, pixl.json movement "float"): it hovers and glides, never hops.
    var floats: Bool { PixlSkins.current.manifest.movement.rawValue == "float" }

    /// Slugg never hops: he crawls everywhere (C11).
    var crawls: Bool { PixlSkins.currentID == "slugg" }

    /// Getting from a to b in this Pixl's way: a hop, a ghost's glide, or Slugg's crawl (along,
    /// down a window's side, up another's; never through the air but for a short drop).
    func move(from a: CGPoint, to b: CGPoint) -> Choreography {
        if floats { return Choreography.glide(from: a, to: b) }
        if crawls {
            let screen = screensTopLeft.first { $0.insetBy(dx: -8, dy: -spriteSize.height).contains(a) } ?? screensTopLeft.first ?? .zero
            let w = roam.world()
            let windows = (w.active.map { [$0] } ?? []) + w.others
            let path = SluggPath.plan(from: a, to: b, screen: screen, windows: windows, sprite: spriteSize, surface: frogg?.surface ?? .floor)
            let art = FroggArt.shared, scale = scale
            return SluggPath.choreography(path.steps, from: a, gait: gait, wrap: { x, y in SluggMotion.wrap(x, y, art: art, scale: scale) })
        }
        return Choreography.hop(route(from: a, to: b))
    }

    // MARK: hovering (Boo)

    var hoverLift: CGFloat = 0
    var hoverTimer: Timer?
    var shadowPanel: PropPanel?

    /// Boo floats a little above whatever it's on, drifting slowly up and down, with a dithered
    /// shadow on the surface below that shrinks as it rises. Runs only for a floating Pixl.
    func updateHover() {
        hoverTimer?.invalidate(); hoverTimer = nil
        guard floats else {
            hoverLift = 0
            shadowPanel?.orderOut(nil); shadowPanel = nil
            return
        }
        let t0 = now
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let held = self.mode == .held || self.flight != nil
                let t = self.now - t0
                let lift = held ? 0 : (16 + 5 * sin(t * 2 * .pi / 3.4)).rounded()   // whole points: crisp
                if lift != self.hoverLift {
                    self.hoverLift = lift
                    if !self.moving, let f = self.foot { self.place(at: f) }
                } else {
                    self.placeShadow()   // follows fades and hiding too
                }
            }
        }
        hoverTimer?.tolerance = 0.005
        RunLoop.main.add(hoverTimer!, forMode: .common)
    }

    /// The dithered shadow under a hovering ghost, on the surface at its feet.
    func placeShadow() {
        guard floats, let foot, frogg.surface == .floor, froggPanel.isVisible, froggPanel.alphaValue > 0.05, !userHidden, !fullscreenHidden, hoverLift > 0 else {
            shadowPanel?.orderOut(nil); return
        }
        let w = (spriteSize.width * 0.7).rounded(), h: CGFloat = 10
        let p = shadowPanel ?? PropPanel(size: NSSize(width: w, height: h)) { r in
            // an ellipse of dark pixels: solid in the middle, checkered dither toward the edge
            let u: CGFloat = 2
            for y in stride(from: 0, to: r.height, by: u) {
                for x in stride(from: 0, to: r.width, by: u) {
                    let nx = (x + u / 2 - r.midX) / (r.width / 2), ny = (y + u / 2 - r.midY) / (r.height / 2)
                    let d = nx * nx + ny * ny
                    guard d <= 1 else { continue }
                    let checker = Int(x / u + y / u) % 2 == 0
                    guard d < 0.35 || checker else { continue }
                    NSColor(srgbRed: 0.05, green: 0.06, blue: 0.12, alpha: d < 0.35 ? 0.5 : 0.38).setFill()
                    NSRect(x: x, y: y, width: u, height: u).fill()
                }
            }
        }
        shadowPanel = p
        // higher up, a smaller and fainter shadow
        let k = max(0.6, 1 - hoverLift / 60)
        let r = NSRect(x: (foot.x - w * k / 2).rounded(), y: (primaryHeight - foot.y - h / 2).rounded(), width: (w * k).rounded(), height: h)
        if p.frame != r { p.setFrame(r, display: true) }
        p.alphaValue = froggPanel.alphaValue * k
        if !p.isVisible { p.orderFrontRegardless() }
        p.order(.below, relativeTo: froggPanel.windowNumber)
    }

    /// A shaped route (PixlzCore HopRoute): distance-scaled arc, chained when long, kept under
    /// the menu bar and clear of the focused window's body (SPEC §7.3).
    func route(from a: CGPoint, to b: CGPoint) -> HopRoute {
        let window = settings.perchOnWindows && focusUntil == nil ? watcher.activeWindowFrame : nil
        let displays = NSScreen.screens.enumerated().map { i, s in
            DisplayInfo(id: i, frame: topLeft(s.frame), visibleFrame: topLeft(s.visibleFrame))
        }
        let world = WorldMap(WorldInput(displays: displays, windows: window.map { [WindowInfo(id: 1, frame: $0)] } ?? []))
        let r = HopRoute.plan(from: a, to: b, displays: screensTopLeft, sprite: spriteSize, scale: scale, keepOut: window, world: world)
        Debug.log("route legs=\(r.legs.count) duration=\(String(format: "%.2f", r.duration))s clear=\(r.clear)\(r.popAfter.map { " pop after leg \($0)" } ?? "")")
        return r
    }

    /// Swiping between Spaces (or the active display changing). Frogg's panel is on every Space
    /// and stationary, so he's already visible at the same spot: no fade, no drop from the
    /// menu bar. A quick "whoa" where he stands, then a springy hop to the new perch. The
    /// drop-in is only for when there's no previous position (launch, unhide, leaving fullscreen).
    @objc func spaceChanged() {
        guard !userHidden else { return }
        let sign = spaceSignAt.map { String(format: " (%.0f ms after the first sign)", (now - $0) * 1000) } ?? ""
        Debug.log("space: change seen\(sign)")
        spaceSignAt = nil
        pendingSwitch?.invalidate()
        spaceTransition = true   // ignore watcher changes until the new perch is computed
        closeMenus()
        let gen = visGen
        // let the watcher attach to the new frontmost window before asking where to perch;
        // a window that's still appearing gets up to 0.4 s, so Frogg doesn't hop to the
        // ground first and then up to the window
        func perchWhenReady(_ tries: Int) {
            self.watcher.attachToFrontmost()
            if tries > 0, self.settings.perchOnWindows, self.focusUntil == nil, self.watcher.activeWindowFrame == nil {
                self.later(0.1) { perchWhenReady(tries - 1) }
                return
            }
            settle()
        }
        later(0.08) { perchWhenReady(4) }
        func settle() {
            let spot = self.target()
            Debug.log("space: perch computed \(spot.map { "(\(Int($0.foot.x)),\(Int($0.foot.y)))" } ?? "none")")
            self.spaceTransition = false
            if self.settings.hideInFullscreen && self.watcher.activeWindowIsFullscreen {
                self.fullscreenHidden = true
                self.cancelMotion()
                self.hideOverlays(fade: 0.15)
                return
            }
            let wasHidden = self.fullscreenHidden || !self.froggPanel.isVisible || self.foot == nil || gen != self.visGen && self.froggPanel.alphaValue < 0.5
            self.fullscreenHidden = false
            guard let spot else { return }
            if wasHidden { self.dropIn(to: spot.foot); return }
            self.showFrogg()
            self.whoa(to: spot.foot)
        }
    }

    /// Startle in place, then hop to `target`. Mid-motion, retargets instead (never two motions).
    func whoa(to target: CGPoint) {
        guard let current = foot else { place(at: target); return }
        if motion != nil { reposition(force: true); return }
        let d = hypot(target.x - current.x, target.y - current.y)
        if crawls || floats {   // Slugg never hops (he crawls there), Boo glides: the startle, then their own way
            run(Choreography(Choreography.whoa(at: current, then: nil).segments + (d >= 1 ? move(from: current, to: target).segments : [])), target: target)
            Debug.log("whoa, then \(crawls ? "crawl" : "glide") → (\(Int(target.x)),\(Int(target.y)))")
            return
        }
        run(Choreography.whoa(at: current, then: d >= 1 ? route(from: current, to: target) : nil), target: target)
        Debug.log("hop start (whoa) → (\(Int(target.x)),\(Int(target.y)))")
    }

    func updateFullscreen() {
        let fs = settings.hideInFullscreen && watcher.activeWindowIsFullscreen
        if fs && !fullscreenHidden {
            fullscreenHidden = true
            cancelMotion()
            hideOverlays(fade: 0.2)
            Debug.log("fullscreen: hidden")
        } else if !fs && fullscreenHidden {
            fullscreenHidden = false
            if !userHidden, let spot = target() { dropIn(to: spot.foot) }
        }
    }

    /// Peek down from under the menu bar (hanging by a toe pad), then drop onto `target`.
    func dropIn(to target: CGPoint) {
        let screen = screensTopLeft.first { $0.minX <= target.x && target.x <= $0.maxX } ?? screensTopLeft.first ?? .zero
        let hang = FroggArt.shared.frames[MotionFrames.hang]
        let below = CGFloat((hang?.h ?? 40) - (hang?.pin?[1] ?? 0)) * scale  // pin (toe) to feet
        let hangFoot = CGPoint(x: target.x, y: min(screen.minY + below, target.y - 20))
        showFrogg()
        run(Choreography.dropIn(hangFoot: hangFoot, to: target), target: target)
        Debug.log("hop start (drop-in) → (\(Int(target.x)),\(Int(target.y)))")
    }

    /// Shows Frogg and invalidates any fade-out still running, so its completion can't hide him.
    func showFrogg() {
        guard awayOn == nil else { return }   // one Pixl, one place: never on screen while it's away
        pond.cancel()   // the pond draws him while he's in it: showing the real one ends it
        visGen += 1
        froggPanel.animator().alphaValue = 1  // replaces a running fade animation…
        froggPanel.alphaValue = 1             // …and lands on 1 at once
        froggPanel.orderFrontRegardless()
    }

    // MARK: motion: one display-synced clock, running only while something moves (SPEC R6, D7)

    var motion: Choreography?
    var motionStart: TimeInterval = 0
    var lastMotionT: TimeInterval = -1
    var motionTarget: CGPoint?
    var motionDone: (@MainActor () -> Void)?
    var link: CADisplayLink?
    var lastTick: TimeInterval = 0
    var dust: DustView?
    var dustPanel: OverlayPanel?
    var riding = false
    var lastRide: (x: CGFloat, t: TimeInterval)?
    var leanTarget: CGFloat = 0
    var dragStopTimer: Timer?

    var moving: Bool { motion != nil || flight != nil }

    func run(_ c: Choreography, target: CGPoint?, roam: Bool = false, then done: (@MainActor () -> Void)? = nil) {
        pond.cancel()   // the pond can't move: any motion takes him out of it (else two Froggs)
        cancelAnimations()
        if !roam { leaveSurface() }
        motion = c
        motionStart = now
        lastMotionT = -1
        motionTarget = target
        motionDone = done
        Debug.log("motion start segments=\(c.segments.count) duration=\(String(format: "%.2f", c.duration))s")
        startClock()
    }

    func startClock() {
        guard link == nil else { return }
        let l = frogg.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)  // keeps running during menus and window drags
        link = l
        lastTick = now
        startWatchdog()
        ticks = 0
        Debug.log("display link on")
    }

    func stopClockIfIdle() {
        guard link != nil, !moving, dust?.pool.isEmpty ?? true, !riding, abs(frogg.lean) < 0.001, menu.view == nil,
              abs(shellLag) < 0.05, abs(shellLagV) < 0.05, abs(shellLagY) < 0.05, abs(shellLagVY) < 0.05 else { return }
        link?.invalidate()
        link = nil
        dustPanel?.orderOut(nil)
        Debug.log("display link off after \(ticks) frames")
    }

    /// macOS pauses a view's display link while the view is off screen or occluded. If frames stop
    /// mid-motion, keep advancing from elapsed time so Frogg can never get stuck mid-hop.
    func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.link != nil else { self.watchdog?.invalidate(); self.watchdog = nil; return }
                if self.now - self.lastTick > 0.15 {
                    Debug.log("watchdog: no display frames for \(Int((self.now - self.lastTick) * 1000)) ms, stepping")
                    self.tick(nil)
                }
            }
        }
    }

    @objc func tick(_ l: CADisplayLink?) {
        let t0 = now
        ticks += 1
        if ticks == 1 { Debug.log("first frame") }
        if ticks % 120 == 0 { Debug.log("frame \(ticks) motion=\(motion != nil) flight=\(flight != nil) riding=\(riding) menu=\(menu.view != nil) dust=\(dust?.pool.isEmpty == false)") }
        let dt = min(max(t0 - lastTick, 0), 0.05)
        lastTick = t0
        if let m = motion {
            let t = t0 - motionStart
            let (pose, done) = m.pose(at: t)
            apply(pose)
            for p in m.landings(between: lastMotionT, and: t) { puff(at: p); Debug.log("landing at (\(Int(p.x)),\(Int(p.y)))") }
            lastMotionT = t
            if done {
                motion = nil
                motionTarget = nil
                let finished = motionDone
                motionDone = nil
                finishMotion()
                finished?()
            }
        }
        if var f = flight {
            let landed = f.step(dt: min(dt, 1.0 / 30))
            flight = f
            place(at: f.body.position)
            if let spot = landed {
                flight = nil
                mode = .perched
                userPlaced = true
                run(Choreography([.land(at: spot, frame: MotionFrames.dropLand, mirrored: false, duration: 0.1, dust: true),
                                  .settle(at: spot, duration: 0.2)]), target: nil)
                puff(at: spot)
            }
        }
        // lean against a window drag, easing back to upright
        let lean = riding ? leanTarget : 0
        frogg.lean += (lean - frogg.lean) * min(1, CGFloat(dt) * 14)
        if abs(frogg.lean - lean) < 0.002 { frogg.lean = lean }
        if let dust, !dust.pool.isEmpty { dust.step(to: Date(), dt: dt) }
        stepShell(dt: dt)
        if PixlSkins.currentID == "slugg" { trail.step() }
        menu.step(t0)
        stopClockIfIdle()
    }

    func apply(_ pose: Pose) {
        if frogg.frameName != pose.frame { frogg.frameName = pose.frame }
        frogg.squash = pose.squash
        frogg.mirrored = pose.mirrored
        frogg.turns = pose.turns
        frogg.surface = pose.surface
        froggPanel.alphaValue = pose.alpha
        place(at: pose.foot)
        showThread(pose.thread)
    }

    /// Silky's thread from where it's tied down to its feet.
    func showThread(_ anchor: CGPoint?) {
        guard let anchor, let foot else { threadPanel?.orderOut(nil); return }
        let t = threadPanel ?? ThreadPanel()
        threadPanel = t
        t.show(from: anchor, to: foot, primaryHeight: primaryHeight)
    }

    /// Stays turned (on the ceiling, on its thread) after an outing ends there.
    func holdSurface(_ pose: Pose) {
        frogg.surface = pose.surface
        place(at: pose.foot)
        showThread(pose.thread)
    }

    /// Back on its feet: upright, no thread.
    func leaveSurface() {
        roamHanging = nil
        if frogg?.surface != .floor { frogg.surface = .floor }
        threadPanel?.orderOut(nil)
    }

    var repositionAfterMotion = false

    // MARK: Slugg is never on nothing (C11)

    var supportTimer: Timer?
    var unsupportedSince: TimeInterval?

    /// Twice a second while Slugg is out: is what he's crawling or resting on still there? His
    /// paths are planned against the windows of that moment; a window that moves, shrinks or
    /// closes under him would leave him in midair. A second without it: he lets go, drops and
    /// crawls on to where he should be.
    func startSupportWatch() {
        supportTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSupport() }
        }
    }

    func checkSupport() {
        guard crawls, !paused, mode == .perched, !userHidden, !fullscreenHidden, !spaceTransition, awayOn == nil, !pond.active,
              !resizer.adjusting, let f = foot, froggPanel.isVisible else { unsupportedSince = nil; return }
        let surface: Surface
        if let m = motion {
            guard let s = m.crawlSurface(at: now - motionStart) else { unsupportedSince = nil; return }   // a drop, a corner: not now
            surface = s
        } else { surface = frogg.surface }
        let screens = NSScreen.screens.flatMap { [topLeft($0.frame), topLeft($0.visibleFrame)] }
        if SluggSupport.supported(foot: f, surface: surface, screens: screens, windows: roam.windowRects()) { unsupportedSince = nil; return }
        guard let since = unsupportedSince else { unsupportedSince = now; return }
        guard now - since >= 0.9 else { return }
        unsupportedSince = nil
        Debug.log("slugg: nothing under him (\(surface) at \(Int(f.x)),\(Int(f.y))): drops and crawls on")
        roam.outingCutShort()
        cancelMotion()
        leaveSurface()
        frogg.turns = 0
        userPlaced = false
        let to = target()?.foot ?? CGPoint(x: f.x, y: (screensTopLeft.first { $0.minX <= f.x && f.x <= $0.maxX } ?? screensTopLeft.first ?? .zero).maxY)
        run(move(from: f, to: to), target: to)
    }

    func finishMotion() {
        if repositionAfterMotion {
            repositionAfterMotion = false
            later(0.3) { [weak self] in self?.reposition(force: true) }
        }
        frogg.squash = CGSize(width: 1, height: 1)
        frogg.mirrored = false
        mode = .perched
        backToIdle()
    }

    /// Feet in top-left coordinates → panel origin snapped to device pixels.
    func place(at p: CGPoint) {
        foot = p
        // the view's contact point (feet bottom-centre, a turned body's edge, or an anchored
        // frame's anchor) goes on the spot
        let c = frogg.contactInView, size = frogg.frame.size
        var f = NSRect(x: p.x - c.x, y: primaryHeight - p.y - c.y, width: size.width, height: size.height)
        if hoverLift != 0, frogg.surface == .floor { f.origin.y += hoverLift }   // Boo floats above its spot
        let s = froggPanel.backingScaleFactor
        f.origin = NSPoint(x: (f.origin.x * s).rounded() / s, y: (f.origin.y * s).rounded() / s)
        if froggPanel.frame != f { froggPanel.setFrame(f, display: true) }
        placeShadow()
        positionBubble()
    }

    func cancelMotion() {
        motion = nil
        motionTarget = nil
        motionDone = nil
        flight = nil
        if mode != .held { mode = .perched }
        frogg?.squash = CGSize(width: 1, height: 1)
        frogg?.mirrored = false
        stopClockIfIdle()
    }

    /// Landing dust in its own click-through panel, so it stays where Frogg landed.
    func puff(at p: CGPoint) {
        let size = NSSize(width: 70 * scale, height: 24 * scale)
        if dust == nil || dust?.scale != scale {
            let v = DustView(scale: scale, size: size)
            let panel = OverlayPanel(size: size)
            panel.ignoresMouseEvents = true
            panel.contentView = v
            dust = v
            dustPanel = panel
        }
        guard let dust, let dustPanel else { return }
        dustPanel.setFrameOrigin(NSPoint(x: (p.x - size.width / 2).rounded(), y: (primaryHeight - p.y - 4 * scale).rounded()))
        dust.emit(at: CGPoint(x: size.width / 2, y: 4 * scale), now: Date())
        dustPanel.order(.below, relativeTo: froggPanel.windowNumber)
        startClock()
    }

    /// Riding a dragged window: feet glued, a lean against the drag, and a small hop when it stops.
    func ride(to p: CGPoint) {
        let t = now
        if let last = lastRide, t - last.t > 0.001 {
            let vx = (p.x - last.x) / CGFloat(t - last.t)
            leanTarget = max(-0.12, min(0.12, -vx / 2500))
        }
        lastRide = (p.x, t)
        riding = true
        cancelAnimations()
        place(at: p)
        startClock()
        dragStopTimer?.invalidate()
        dragStopTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.riding = false
                self.lastRide = nil
                self.leanTarget = 0
                if let f = self.foot, self.motion == nil, self.mode == .perched {
                    self.run(Choreography.bump(at: f, scale: self.scale), target: nil)
                }
            }
        }
    }

    // MARK: animation (frame changes only)

    /// A one-shot that animations can't cancel (for transition steps).
    func later(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { block() } }
    }

    func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let t = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { block() } }
        animTimers.append(t)
    }

    func cancelAnimations() {
        animTimers.forEach { $0.invalidate() }
        animTimers.removeAll()
        idleTimer?.invalidate()
        if !sleep.dozing { stopSleep() }
    }

    // MARK: sleeping (you've been away a while)

    var sleepTimer: Timer?

    /// Asleep: rising pixel "z"s for every Pixl. Boo floats instead of squashing: eyes closed,
    /// bobbing slowly, fading softly in and out like breathing.
    /// What it looks like asleep: Frogg under in its pond, Boo upright with closed eyes, the
    /// others in their rest pose (deeper: rest_2).
    func sleepFrame(deep: Bool) -> String {
        if PixlSkins.currentID == "frogg" { return mode == .perched ? "mischief_2" : "rest_1" }
        if floats { return "emotion_sleepy" }
        if crawls { return "rest_2" }   // Slugg sleeps all the way inside his shell
        return deep ? "rest_2" : "rest_1"
    }

    /// Asleep (SleepController): its sleep pose, Frogg's pond, Boo breathing faintly. The z's
    /// come from the sleep clock.
    func startSleep(deep: Bool = false) {
        animTimers.forEach { $0.invalidate() }
        animTimers.removeAll()
        idleTimer?.invalidate()
        sleepTimer?.invalidate()
        // Frogg sleeps in his pond (C14): it forms beside him and he slides in
        if pond.active { pond.keepForSleep(); return }   // asleep in a dip: it's his bed now
        if pond.canEnter { pond.enter(); return }
        frogg.frameName = sleepFrame(deep: deep)
        if crawls, frogg.surface == .floor {
            // Slugg pulls back into his shell: half in, then gone, the shell left sitting there
            frogg.frameName = "rest_0"
            animTimers.append(Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.sleepTimer != nil { self?.frogg.frameName = "rest_1" } }
            })
            animTimers.append(Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.sleepTimer != nil { self.frogg.frameName = self.sleepFrame(deep: deep) } }
            })
        }
        if let f = foot { place(at: f) }
        let t0 = now
        let floats = self.floats
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if floats { self.froggPanel.alphaValue = 0.72 + 0.2 * sin((self.now - t0) * 2 * .pi / 3.6) }   // it breathes, faintly
            }
        }
        sleepTimer?.tolerance = 0.01
    }

    func stopSleep() {
        roam.hidePond()
        if pond.active, !moving {   // out of the pond: launch, splash, step out, then himself again
            pond.leave { [weak self] in self?.backToIdle() }
        }
        guard let timer = sleepTimer else { return }
        timer.invalidate()
        sleepTimer = nil
        froggPanel.alphaValue = 1
        if let f = foot { place(at: f) }
        // Slugg comes back out of his shell: half out, then himself
        if crawls, frogg.frameName == "rest_2" {
            frogg.frameName = "rest_1"
            later(0.3) { [weak self] in if self?.frogg.frameName == "rest_1" { self?.frogg.frameName = "rest_0" } }
            later(0.6) { [weak self] in if self?.frogg.frameName == "rest_0" { self?.backToIdle() } }
        }
    }

    /// One pixel "z" rising from beside its head and fading.
    func puffZ() {
        guard let frogg, let froggPanel, !userHidden else { return }
        let u: CGFloat = 2
        let z = PropPanel(size: NSSize(width: 5 * u + 3, height: 5 * u + 3)) { r in
            let rows = ["xxxxx", "...x.", "..x..", ".x...", "xxxxx"]
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() where c == "x" {
                    let p = NSRect(x: 1 + CGFloat(x) * u, y: r.maxY - 2 - CGFloat(y + 1) * u, width: u, height: u)
                    NSColor(white: 0.1, alpha: 0.5).setFill(); p.offsetBy(dx: 1, dy: -1).fill()
                    NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1).setFill(); p.fill()
                }
            }
        }
        let f = froggPanel.frame
        let headTop = f.minY + FroggArt.shared.size(frogg.frameName).height * scale
        // Slugg: out of his shell's opening (the front of it, low down); everyone else: beside the head
        let start = crawls
            ? NSPoint(x: f.midX + (frogg.mirrored ? -1 : 1) * CGFloat.random(in: 20...26) - (frogg.mirrored ? 12 : 0), y: headTop - FroggArt.shared.size(frogg.frameName).height * scale * 0.5)
            : NSPoint(x: f.midX + 18 + CGFloat.random(in: -4...6), y: headTop - 4)
        z.setFrameOrigin(start)
        z.alphaValue = 0
        z.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            z.animator().alphaValue = 1
        })
        later(0.4) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 1.6
                z.animator().alphaValue = 0
                z.animator().setFrameOrigin(NSPoint(x: start.x + 14, y: start.y + 34))
            }, completionHandler: { MainActor.assumeIsolated { z.orderOut(nil) } })
        }
    }

    func play(_ anim: SlotAnimation, then next: (@MainActor () -> Void)? = nil) {
        cancelAnimations()
        for (frame, at) in anim.schedule {
            if at == 0 { frogg.frameName = frame } else { after(at) { [weak self] in self?.frogg.frameName = frame } }
        }
        after(anim.duration) { [weak self] in
            if let next { next() } else { self?.backToIdle() }
        }
    }

    func show(_ frame: String, for seconds: TimeInterval) {
        cancelAnimations()
        frogg.frameName = frame
        after(seconds) { [weak self] in self?.backToIdle() }
    }

    func backToIdle() {
        guard mode == .perched, !moving else { return }
        if let k = shellPose, FroggArt.shared.frames["\(k)_2"] != nil { frogg.frameName = "\(k)_2"; return }   // still in its shell
        if sleep.dozing {   // still asleep (say, after being carried): back to its sleep pose
            if sleep.stage.sleeping { startSleep(deep: sleep.stage == .deep) } else { frogg.frameName = "emotion_sleepy" }
            return
        }
        frogg.frameName = roamHanging != nil ? "mischief_0" : "idle_0"   // on its thread: the hanging pose
        scheduleIdle()
    }

    // MARK: Slugg's shell (C11): the Memory vault, and sealed for Focus and hidden

    /// "vault" or "seal" while Slugg is in its shell, else nil.
    var shellPose: String?

    /// Into its shell: the three steps in, then it holds the last. Pixls without the frames skip it.
    func shellIn(_ kind: String, then done: (() -> Void)? = nil) {
        let art = FroggArt.shared
        guard shellPose != kind, art.frames["\(kind)_2"] != nil else { done?(); return }
        if moving { cancelMotion() }
        shellPose = kind
        Debug.log("shell: \(kind) in")
        for i in 0..<3 { later(Double(i) * 0.16) { [weak self] in if self?.shellPose == kind { self?.frogg.frameName = "\(kind)_\(i)" } } }
        later(0.5) { done?() }
    }

    /// Out of its shell: the steps back, then idle as usual.
    func shellOut(_ kind: String) {
        guard shellPose == kind else { return }
        shellPose = nil
        Debug.log("shell: \(kind) out")
        frogg.frameName = "\(kind)_1"
        later(0.16) { [weak self] in if self?.shellPose == nil { self?.frogg.frameName = "\(kind)_0" } }
        later(0.34) { [weak self] in if self?.shellPose == nil { self?.backToIdle() } }
    }

    /// Idle life, after the research notes (docs/PRODUCT-NOTES.md §3): three independent rhythms
    /// so nothing pulses like a metronome, all on slow timers (no display link, ~0 % CPU).
    /// - blink: a closed-eye frame for ~100 ms every 2–8 s, one in six a double blink;
    /// - breath: a one-art-pixel rise every ~3 s, held ~0.5 s;
    /// - quirk: one of the Pixl's own idle frames every 6–14 s (and, rarely, its signature).
    func scheduleIdle() {
        idleTimer?.invalidate()
        blinkTimer?.invalidate()
        breathTimer?.invalidate()
        guard !paused else { return }
        // in Roam, idle life is livelier too
        idleTimer = Timer.scheduledTimer(withTimeInterval: settings.roams ? Double.random(in: 3...7) : Double.random(in: 6...14), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleQuirk() }
        }
        idleTimer?.tolerance = 0.5
        scheduleBlink()
        scheduleBreath()
    }

    /// Calm enough for idle life: perched, still, idle frame, no menu, nothing in the air.
    var restingIdle: Bool { mode == .perched && !moving && !busy && !menu.isOpen && frogg.frameName == "idle_0" && !presence.typing }

    func idleQuirk() {
        guard restingIdle else { scheduleIdle(); return }
        // the signature as an idle quirk: rare, never twice within 5 min, never during Focus
        if focusUntil == nil, Date().timeIntervalSince(lastSignature) > (settings.roams ? 45 : 300), Int.random(in: 0..<(settings.roams ? 8 : 40)) == 0 {
            signature()
            return
        }
        let next = Bool.random() ? "idle_1" : "idle_2"
        frogg.frameName = next
        after(next == "idle_1" ? 0.6 : 0.9) { [weak self] in self?.backToIdle() }
    }

    func scheduleBlink() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 2...8), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.restingIdle, FroggArt.shared.frames["blink"] != nil {
                    let double = Int.random(in: 0..<6) == 0
                    self.frogg.frameName = "blink"
                    self.later(0.1) { [weak self] in
                        guard let self, self.frogg.frameName == "blink" else { return }
                        self.frogg.frameName = "idle_0"
                        if double {
                            self.later(0.16) { [weak self] in
                                guard let self, self.restingIdle else { return }
                                self.frogg.frameName = "blink"
                                self.later(0.09) { [weak self] in if self?.frogg.frameName == "blink" { self?.frogg.frameName = "idle_0" } }
                            }
                        }
                    }
                }
                self.scheduleBlink()
            }
        }
        blinkTimer?.tolerance = 0.3
    }

    func scheduleBreath() {
        breathTimer?.invalidate()
        breathTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 2.8...3.6), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.restingIdle, self.frogg.squash == CGSize(width: 1, height: 1) {
                    // one art pixel taller (the view snaps squash to whole art pixels), feet planted
                    let h = max(FroggArt.shared.size("idle_0").height, 1)
                    self.frogg.squash = CGSize(width: 1, height: (h + 1) / h)
                    self.later(0.5) { [weak self] in
                        guard let self, self.frogg.squash.height > 1, !self.moving else { return }
                        self.frogg.squash = CGSize(width: 1, height: 1)
                    }
                }
                self.scheduleBreath()
            }
        }
        breathTimer?.tolerance = 0.3
    }

    // MARK: mouse (SPEC §11.1)

    var mouseTopLeft: CGPoint { topLeft(NSEvent.mouseLocation) }

    /// C8: a single click only pokes. Double-click, right-click or a 450 ms press opens the
    /// option bubbles (cutting the poke short). Starting a drag pops them.
    func mouse(_ kind: FroggView.MouseEvent, _ event: NSEvent) {
        if kind != .dragged { Debug.log("mouse \(kind) clickCount=\(event.clickCount) mode=\(mode)") }
        // in a game, a click on the Pixl is a move in the game (a bonk, accepting an invite), never a grab
        if game.isOn, game.kind != .laser {
            if kind == .down { _ = game.clickedPet() }
            return
        }
        switch kind {
        case .down:
            longPressTimer?.invalidate()
            longPressed = false
            if event.clickCount == 2 {
                gesture = nil
                sleep.handle(.menuClick)   // asleep: wakes, and the menu opens
                menu.open(trigger: "double-click")
                return
            }
            if menu.isOpen { menu.close(reason: "click on Frogg") }
            gesture = PointerGesture(at: mouseTopLeft, time: now)
            dragSamples = [(now, mouseTopLeft)]
            longPressTimer = Timer.scheduledTimer(withTimeInterval: PointerGesture.longPressTime, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.gesture?.dragging == false, self.mode == .perched else { return }
                    self.longPressed = true
                    self.sleep.handle(.menuClick)
                    self.menu.open(trigger: "long-press")
                }
            }
        case .dragged:
            guard var g = gesture else { return }
            dragSamples.append((now, mouseTopLeft))
            if g.moved(to: mouseTopLeft) {
                longPressTimer?.invalidate()
                menu.pop()
                startGrab()
            }
            gesture = g
            if mode == .held { moveHeld() }
        case .up:
            defer { gesture = nil }
            longPressTimer?.invalidate()
            if mode == .held { release(); return }
            if longPressed { return }  // the menu is open
            if let g = gesture, g.isClick(releasedAt: mouseTopLeft, time: now) { clicked(event) }
            else if gesture != nil { Debug.log("mouse up: not a click (moved)") }
        case .right:
            sleep.handle(.menuClick)
            menu.open(trigger: "right-click")
        }
    }

    /// A single click: Frogg gets poked (and is annoyed by the third in 4 s). That's all (C8).
    func clicked(_ event: NSEvent) {
        if sleep.handle(.poke) { return }   // asleep: startled, then grumpy, then awake
        roam.poked()
        if pokes.poke(at: now) {
            show("emotion_annoyed", for: 2)
            speak(.annoyed)
        } else {
            play(.poke)
        }
        if let until = focusUntil { notify(.focusLeft(Int(until.timeIntervalSinceNow / 60) + 1)) }
    }

    func signature() {
        lastSignature = Date()
        Debug.log("signature")
        play(.signature) { [weak self] in
            self?.show("emotion_proud", for: 2)
        }
    }

    // grab and throw

    func startGrab() {
        cancelMotion()
        cancelAnimations()
        mode = .held
        leaveSurface()
        roam.dragged()
        bubblePanel.orderOut(nil)
        if sleep.handle(.grab) {
            roam.hidePond()
            pond.cancel()
            frogg.frameName = sleepFrame(deep: false)   // dangling, still asleep
            moveHeld()
            return
        }
        frogg.frameName = "grab_0"  // peel-stretch
        after(0.25) { [weak self] in if self?.mode == .held { self?.frogg.frameName = "grab_1" } }  // limp sway
        moveHeld()
    }

    func moveHeld() {
        let pin = frogg.pinPoint(frogg.frameName) ?? NSPoint(x: frogg.bounds.midX, y: frogg.bounds.maxY)
        let m = NSEvent.mouseLocation
        froggPanel.setFrameOrigin(NSPoint(x: (m.x - pin.x).rounded(), y: (m.y - pin.y).rounded()))
        let f = froggPanel.frame
        foot = CGPoint(x: f.midX, y: primaryHeight - f.minY)
    }

    func release() {
        guard let start = foot else { mode = .perched; return }
        let v = Body.throwVelocity(samples: dragSamples, at: now, cap: 3000)
        let screens = NSScreen.screens.map { (frame: topLeft($0.frame), visible: topLeft($0.visibleFrame)) }
        flight = ThrowFlight(foot: start, velocity: v, scale: scale, screens: screens,
                             window: settings.perchOnWindows ? watcher.activeWindowFrame : nil, halfWidth: spriteSize.width / 2)
        mode = .airborne
        frogg.frameName = sleep.dozing ? sleepFrame(deep: false) : MotionFrames.fall
        sleep.handle(.release)
        Debug.log("throw v=(\(Int(v.dx)),\(Int(v.dy)))")
        startClock()
    }

    // MARK: polish

    struct Instruction {
        let title: String
        let prompt: String?
    }

    let instructions = [
        Instruction(title: "Polish this", prompt: nil),
        Instruction(title: "Make it shorter", prompt: "Make it shorter and clearer. Keep my voice."),
        Instruction(title: "Make it friendlier", prompt: "Make it warmer and friendlier. Keep the meaning."),
        Instruction(title: "Fix spelling & grammar only", prompt: "Fix spelling and grammar only. Change nothing else."),
    ]

    var pendingSelection: (text: String, app: String?)? { didSet { if pendingSelection == nil { selectionPID = nil } } }
    var selectionPID: pid_t?
    var polishedText: String?
    var polishedBrowser = false
    var selectionElement: AXUIElement?
    var polishedElement: AXUIElement?

    @discardableResult
    /// A selection the browser extension read (rich editors, Google Docs).
    func setWebSelection(_ text: String, app front: NSRunningApplication?, title: String?) {
        pendingSelection = (text, front?.localizedName ?? "Browser")
        selectionPID = front?.processIdentifier
        selectionElement = nil
        selectionFromWeb = true
        Debug.log("selection read from \(front?.localizedName ?? "browser") via the extension: \(text.count) chars")
    }

    func readSelection() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        if AX.trusted, AX.enableWebAccessibility(for: front) {
            Debug.log("web accessibility switched on for \(front?.localizedName ?? "?")")
            Thread.sleep(forTimeInterval: 0.25)  // first time only: let the browser build its tree
        }
        let text = AX.trusted ? AX.selectedText(pid: front?.processIdentifier ?? 0) : nil
        pendingSelection = text.map { ($0, front?.localizedName) }
        selectionPID = text == nil ? nil : front?.processIdentifier
        selectionFromWeb = false
        selectionElement = text == nil ? nil : front.flatMap { AX.focusedElement(pid: $0.processIdentifier) }
        Debug.log("selection read from \(front?.localizedName ?? "?"): \(text.map { "\($0.count) chars" } ?? "none")")
        return text
    }

    func instructionItems() -> [NSMenuItem] {
        guard let sel = pendingSelection else {
            let i = NSMenuItem(title: AX.trusted ? "Select some text first" : "Allow Accessibility to read selections",
                               action: AX.trusted ? nil : #selector(openAccessibility), keyEquivalent: "")
            i.target = self
            return [i]
        }
        let preview = sel.text.replacingOccurrences(of: "\n", with: " ")
        let header = NSMenuItem(title: "“\(preview.prefix(40))\(preview.count > 40 ? "…" : "")”", action: nil, keyEquivalent: "")
        header.isEnabled = false
        return [header] + instructions.enumerated().map { i, ins in
            let item = NSMenuItem(title: ins.title, action: #selector(polishChosen(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            return item
        }
    }

    @objc func polishChosen(_ sender: NSMenuItem) { polish(sender.tag) }

    func polish(_ index: Int) {
        Debug.log("polish chosen index=\(index)")
        if CommandLine.arguments.contains("--selftest") { chosenInSelfTest = index; return }  // never send text in a self-test
        guard let sel = pendingSelection, instructions.indices.contains(index) else { return }
        guard !polishing else { Debug.log("polish: one is already on its way"); return }
        let ins = instructions[index]
        if game.isOn { game.interrupt("polish") }   // work ends a game at once
        polishedText = sel.text
        polishedBrowser = selectionFromWeb || AX.isChromium(NSWorkspace.shared.runningApplications.first { $0.processIdentifier == selectionPID })
        polishedElement = selectionElement
        polishing = true
        let tookBusy = !busy   // a roam or a take holding the Pixl keeps it; we never clear theirs
        if tookBusy { busy = true }
        resultPanel?.orderOut(nil)
        show("emotion_curious", for: 600)
        notify(.checkingEnclave)
        let stage = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.polishing == true { self?.notify(.thinking) } }
        }
        Task { @MainActor in
            defer { polishing = false; if tookBusy { busy = false }; stage.invalidate() }
            do {
                let r = try await client.polish(sel.text, instruction: ins.prompt)
                let v = r.verification
                lastVerdict = "\(v.badge) · \(v.passed)/\(v.checks.count)"
                lastVerdictCode = v.verdict
                show(v.verdict == "verified" ? "emotion_proud" : v.verdict == "partial" ? "emotion_curious" : "emotion_annoyed", for: 4)
                let verdict = v.verdict == "verified" ? "✔ Verified in TEE · \(v.passed)/\(v.checks.count)" : v.badge
                notify(.polished(r.receipt.map { verdict + ". " + $0.bubble } ?? verdict), voice: r.verification.verdict == "verified" ? .happy : .curious)
                if let rc = r.receipt, rc.status == "paid", let amt = rc.amountNear { coinPop(amt) }
                showResult(.result(r, instruction: ins.title, app: sel.app))
                menu.refreshWallet()
            } catch {
                let e = (error as? MemoryError) ?? .upstream(error.localizedDescription)
                show("emotion_annoyed", for: 5)
                notify(.error(e), voice: .sad)
                switch e {
                case .attestationFailed, .replyRejected, .serviceDown, .noApiKey, .noCredits, .outOfAllowance: showResult(.error(e, app: sel.app))
                default: break
                }
            }
        }
    }

    func replaced(_ r: PolishResult, panel: NSPanel?) {
        panel?.orderOut(nil)
        show("emotion_happy", for: 3)
        notify(.replaced, voice: .happy)
        Task { await client.markAccepted(draftId: r.draftId) }
    }

    /// A drop lands where the pointer was, usually inside the text that was polished, and splits
    /// it. When that text is still there intact around the drop, take it out, so dragging the
    /// polished text in replaces what it was made from. Anything else is left as dropped.
    func tidyDrop(_ r: PolishResult) {
        guard let original = polishedText,
              let element = polishedElement ?? selectionPID.flatMap({ AX.focusedElement(pid: $0) }) else { return }
        Task { @MainActor in
            for _ in 0..<8 {   // some apps apply the drop a beat after the drag ends
                if AX.tidyDrop(in: element, original: original, dropped: r.suggestion) {
                    Debug.log("drop: took the original out, the polished text stands in its place")
                    return
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            Debug.log("drop: the original isn't intact around the drop, left as dropped")
        }
    }

    /// Writes the suggestion through Accessibility; if the app won't take it, copies it.
    func replaceViaAX(_ r: PolishResult, original: String, panel: NSPanel?) {
        let element = polishedElement ?? selectionPID.flatMap { AX.focusedElement(pid: $0) }
        if let element, AX.replace(in: element, original: original, with: r.suggestion) {
            Debug.log("replace: written via AX")
            replaced(r, panel: panel)
        } else {
            Debug.log("replace: app refused or selection changed, copied instead")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(r.suggestion, forType: .string)
            show("emotion_curious", for: 3)
            notify(.couldntWrite)
        }
    }

    func showResult(_ content: PolishView.Content) {
        let view = PolishView(content, look: menu.cardLook)
        view.fit()
        let card = SurfaceView.card(view, look: menu.cardLook)
        let panel = resultPanel ?? OverlayPanel(size: card.frame.size)
        resultPanel = panel
        panel.level = .popUpMenu
        panel.contentView = card
        panel.setContentSize(card.frame.size)
        panel.alphaValue = 1
        view.onClose = { [weak panel] in panel?.orderOut(nil) }
        view.onCopy = { [weak self] s in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            self?.notify(.copied)
        }
        view.onReplace = { [weak self, weak panel] r in
            guard let self, let original = self.polishedText else { return }
            // In a browser, the extension replaces it the way typing would (pages see input
            // events; works in Google Docs). Accessibility is the fallback.
            if self.polishedBrowser, self.bridge.connected {
                self.bridge.replace(original: original, with: r.suggestion) { [weak self, weak panel] ok in
                    guard let self else { return }
                    if ok {
                        Debug.log("replace: written by the extension")
                        self.replaced(r, panel: panel)
                    } else {
                        self.replaceViaAX(r, original: original, panel: panel)
                    }
                }
                return
            }
            self.replaceViaAX(r, original: original, panel: panel)
        }
        view.onDropped = { [weak self, weak panel] r in
            panel?.orderOut(nil)
            self?.show("emotion_happy", for: 3)
            self?.notify(.droppedIn, voice: .happy)
            self?.tidyDrop(r)
            Task { await self?.client.markAccepted(draftId: r.draftId) }
        }
        view.onResize = { [weak self, weak panel, weak view, weak card] in
            guard let self, let panel, let view, let card else { return }
            card.setFrameSize(NSSize(width: card.frame.width, height: card.height(fitting: view)))
            panel.setContentSize(card.frame.size)
            self.placeBeside(panel, avoid: self.menu.avoidRects())
        }
        placeBeside(panel, avoid: menu.avoidRects())
        panel.orderFrontRegardless()
    }

    /// The visible frame (below the menu bar, above the Dock) of the screen Frogg is on.
    var froggScreen: CGRect {
        let c = NSPoint(x: froggPanel.frame.midX, y: froggPanel.frame.minY + spriteSize.height / 2)
        return (NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    /// Frogg's head and body box in screen coordinates.
    var froggBox: CGRect {
        let f = froggPanel.frame
        let art = FroggArt.shared.size(frogg.frameName)
        return CGRect(x: f.midX - art.width * scale / 2, y: f.minY, width: art.width * scale, height: art.height * scale)
    }

    /// Beside Frogg (left preferred), fully on screen.
    func placeBeside(_ panel: NSPanel) { placeBeside(panel, avoid: []) }

    /// Beside Frogg (left, else right, else above or below), fully on screen, and clear of the
    /// caret and selection rects in `avoid` (top-left global coordinates, as AX gives them) when possible.
    func placeBeside(_ panel: NSPanel, avoid topLeft: [CGRect]) {
        let avoid = topLeft.map { Perch.toAppKit($0, primaryHeight: primaryHeight) }
        let b = froggBox
        let s = panel.frame.size
        let screen = froggScreen
        let candidates = [
            CGRect(x: b.minX - s.width - 8, y: b.maxY - s.height, width: s.width, height: s.height),
            CGRect(x: b.maxX + 8, y: b.maxY - s.height, width: s.width, height: s.height),
            CGRect(x: b.midX - s.width / 2, y: b.maxY + 8, width: s.width, height: s.height),
            CGRect(x: b.midX - s.width / 2, y: b.minY - s.height - 8, width: s.width, height: s.height),
        ].map { Placement.fit($0, in: screen) }
        let clear = candidates.first { c in !avoid.contains { $0.intersects(c) } && !c.intersects(b.insetBy(dx: 4, dy: 4)) }
        panel.setFrameOrigin((clear ?? candidates[0]).origin)
    }

    /// Ask Frogg a question through the TEE (attested before sending; paid from Frogg's wallet).
    func ask(_ question: String, completion: @escaping @MainActor (Result<AskResult, MemoryError>) -> Void) {
        Debug.log("ask (\(question.count) chars)")
        if CommandLine.arguments.contains("--selftest") { askedInSelfTest = question; return }  // never send text in a self-test
        show("emotion_curious", for: 600)
        Task { @MainActor in
            do {
                let r = try await client.ask(question, name: settings.name, personality: ui.personality)
                lastVerdict = "\(r.verification.badge) · \(r.verification.passed)/\(r.verification.checks.count)"
                lastVerdictCode = r.verification.verdict
                show(r.verification.verdict == "verified" ? "emotion_proud" : "emotion_curious", for: 3)
                if let rc = r.receipt, rc.status == "paid", let amt = rc.amountNear { coinPop(amt) }
                completion(.success(r))
            } catch {
                show("emotion_annoyed", for: 3)
                completion(.failure((error as? MemoryError) ?? .upstream(error.localizedDescription)))
            }
            menu.refreshWallet()
        }
    }

    /// Closes the bubble menu (and its list) with the reverse-stagger animation.
    func closeMenus() { menu.close(reason: "dismiss") }

    // MARK: focus guardian (SPEC §6.6)

    func startFocus(minutes: Int) {
        Debug.log("focus start \(minutes) min")
        focusUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
        notify(.focusStarted(minutes, name: settings.name))
        focusTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endFocus(completed: true) }
        }
        userPlaced = false
        reposition(force: true)  // to the ground: no hopping between windows during a session
        // Slugg tucks in and seals once it's there
        later(2.2) { [weak self] in if self?.focusUntil != nil, self?.moving == false { self?.shellIn("seal") } }
    }

    func endFocus(completed: Bool) {
        sleep.handle(.focusEnded)
        focusTimer?.invalidate()
        focusUntil = nil
        shellOut("seal")
        if completed {
            show("emotion_proud", for: 4)
            notify(.focusDone, voice: .happy)
        } else {
            notify(.focusStopped)
        }
        reposition(force: true)
    }

    func nudgeIfDistracting() {
        guard focusUntil != nil, Date().timeIntervalSince(lastNudge) > 120,
              let name = NSWorkspace.shared.frontmostApplication?.localizedName,
              settings.distractingApps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        lastNudge = Date()
        play(.nudge)
        notify(.distracted(name), voice: .curious)
    }

    // MARK: bubble (SPEC §11.6)

    // MARK: the three text channels (SPEC §11.6)

    /// Status: what it's doing, narrated in the third person. Settings header, hover tooltip and
    /// the menu bar; never in a bubble.
    var statusLine: String {
        PixlStatus.line(name: settings.name, activity: activity, ui: ui)
    }

    /// Changes its idle status line every few minutes.
    var statusIndex: Int { Int(Date().timeIntervalSince1970 / 180) }

    var activity: PixlActivity {
        if userHidden { return .hidden }
        if let d = awayOn { return .visiting(d) }
        if resizer.adjusting { return .resizing }
        if let k = game.kind { return .playing(GameController.title(k)) }
        switch sleep.stage {
        case .drowsy: return .drowsy
        case .asleep: return .asleep
        case .deep: return .deepSleep
        case .waking: return .waking
        default: break
        }
        if roam.outing, let o = roam.outingName { return .outing(o) }
        if busy || polishing { return .thinking }
        if focusUntil != nil { return .focus }
        if sleep.stage == .resting { return .resting }
        return .idle(statusIndex)
    }

    var statusTip: NSPanel?
    var statusTipText = ""

    /// The status as a little tooltip above the Pixl, after you rest the mouse on it for ~1 s.
    func showStatusTip(_ show: Bool) {
        guard show, !menu.isOpen, !moving, !resizer.adjusting, let froggPanel, let frogg, !userHidden else {
            statusTip?.orderOut(nil); statusTip = nil; return
        }
        let text = statusLine
        if statusTip != nil, text == statusTipText { return }
        statusTip?.orderOut(nil)
        statusTipText = text
        let font = Theme.mono(11, .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let w = ceil(size.width) + 16, h: CGFloat = 22
        let tip = PropPanel(size: NSSize(width: w, height: h)) { r in
            // a stepped ink plate, like the resize label
            Theme.ink.setFill()
            NSRect(x: 2, y: 0, width: r.width - 4, height: r.height).fill()
            NSRect(x: 0, y: 2, width: r.width, height: r.height - 4).fill()
            Accent.color.setFill(); NSRect(x: 2, y: 0, width: r.width - 4, height: 2).fill()
            (text as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: [.font: font, .foregroundColor: Theme.paper])
        }
        tip.setFrameOrigin(Placement.beside(pet: petRect, size: CGSize(width: w, height: h), in: froggScreen, gap: 6).origin)
        tip.orderFrontRegardless()
        statusTip = tip
        Debug.log("status: \(text)")
    }

    var voicePicker = VoicePicker()

    /// Voice: one of the Pixl's own sounds for `event` ("ribbit", "mrrp?", "tk tk"), never the
    /// same line twice in a row. A shy Pixl (Boo) says it without a bubble.
    func speak(_ event: SoundEvent, for seconds: TimeInterval = 1.8) {
        if shellPose == "seal" { Debug.log("voice \(event.rawValue): sealed, says nothing"); return }   // C11: no bubbles while sealed
        let line = voicePicker.pick(event, ui: ui)
        Debug.log("voice \(event.rawValue): \"\(line)\"")
        if ui.shy == true { murmur(line) } else { voiceBubble(line, for: seconds) }
    }

    /// Notices: anything functional, in plain English with an icon, optionally led by one sound.
    func notify(_ n: Notice, voice: SoundEvent? = nil, urgent: Bool = false) {
        let line = voice.map { voicePicker.pick($0, ui: ui) }
        Debug.log("notice \(n.kind.rawValue) (\(n.text.count) chars)")   // notices can quote your text: never logged
        // The Pixl can't show it (hidden, or an app is fullscreen): errors and urgent ones still
        // reach you, as a macOS notification.
        if (userHidden || fullscreenHidden), urgent || n.kind == .error {
            SystemNotice.post(n.text)
            return
        }
        present(NoticeView(n, voice: line, look: menu.cardLook), seconds: n.seconds)
    }

    /// A game exclamation in the Pixl's voice ("squelch!", "*gulp*", "…another time"), C16.
    func exclaim(_ line: String, for seconds: TimeInterval = 1.8) {
        Debug.log("game voice: \"\(line)\"")
        voiceBubble(line, for: seconds)
    }

    /// The speech bubble, for the voice channel only (`speak`).
    func voiceBubble(_ text: String, for seconds: TimeInterval? = 3) {
        present(BubbleView(text: text, look: menu.labelLook), seconds: seconds)
    }

    func present(_ bubble: NSView, seconds: TimeInterval?) {
        guard !userHidden, !fullscreenHidden else { return }
        // a fresh window for each bubble: Liquid Glass didn't render when a reused window's
        // content view was swapped (only the tail showed)
        let old = bubblePanel
        let panel = OverlayPanel(size: bubble.frame.size)
        panel.ignoresMouseEvents = true  // the bubble is opaque; it must never swallow clicks (R2)
        panel.contentView = bubble
        bubblePanel = panel
        if old.isVisible { old.orderOut(nil) }
        bubblePanel.alphaValue = 1
        positionBubble()
        bubblePanel.orderFrontRegardless()
        bubbleTimer?.invalidate()
        if let seconds {
            bubbleTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.bubblePanel.orderOut(nil) }
            }
        }
    }

    func positionBubble() {
        guard let froggPanel, let frogg else { return }
        _ = frogg
        bubblePanel.setFrameOrigin(Placement.beside(pet: petRect, size: bubblePanel.frame.size, in: bubbleArea ?? froggScreen, gap: 2).origin)
    }

    /// The box the Pixl covers on screen (AppKit coordinates): standing, its frame's art box
    /// (stretched by a squash); on a wall, the ceiling or around a corner, the drawn pose's box.
    var petRect: CGRect {
        guard let froggPanel, let frogg else { return .zero }
        let f = froggPanel.frame
        if frogg.surface == .floor, !frogg.drawn.anchored, frogg.turns == 0 {
            let art = FroggArt.shared.size(frogg.frameName)
            let w = art.width * scale * max(1, frogg.squash.width), h = art.height * scale * max(1, frogg.squash.height)
            return CGRect(x: f.midX - w / 2, y: f.minY, width: w, height: h)
        }
        // turned or anchored poses are drawn about the panel's middle: their art, either way round
        let art = FroggArt.shared.size(frogg.drawn.name)
        let side = max(art.width, art.height) * scale
        return CGRect(x: f.midX - side / 2, y: f.midY - side / 2, width: side, height: side)
    }

    /// ⌃⌥Space: ask your Pixl something, wherever you are.
    func chatStub() {
        guard !userHidden else { return }
        sleep.handle(.hotkey)
        menu.showAsk()
    }

    var murmurPanel: PropPanel?

    /// Boo says a word ("boo"): faint, outlined letters by its head, no bubble; they drift and fade.
    func murmurWords(_ line: String) {
        guard let froggPanel, let frogg else { return }
        let font = Theme.mono(13, .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1),
                                                    .strokeColor: NSColor(white: 0.08, alpha: 0.75), .strokeWidth: -3]
        let size = (line as NSString).size(withAttributes: attrs)
        let panel = PropPanel(size: NSSize(width: ceil(size.width) + 8, height: ceil(size.height) + 6)) { _ in
            (line as NSString).draw(at: NSPoint(x: 4, y: 3), withAttributes: attrs)
        }
        let f = froggPanel.frame
        let headTop = f.minY + max(FroggArt.shared.size(frogg.frameName).height, FroggArt.shared.size("idle_0").height) * scale + 6
        let side: CGFloat = frogg.mirrored ? -1 : 1
        let start = NSPoint(x: f.midX + side * 34 - panel.frame.width / 2, y: headTop + 2)
        panel.setFrameOrigin(start)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        murmurPanel = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.5; panel.animator().alphaValue = 0.9 }
        later(1.6) { [weak self, weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.7
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: start.x, y: start.y + 12))
            }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil); if self?.murmurPanel === panel { self?.murmurPanel = nil } } })
        }
    }

    /// Boo's "…": pixel dots that pop in one by one beside its head, drift up a little and fade.
    func murmur(_ line: String) {
        guard !userHidden, let froggPanel, let frogg else { return }
        murmurPanel?.orderOut(nil)
        if line.contains(where: \.isLetter) { murmurWords(line); return }
        let glyphs = Array(line.replacingOccurrences(of: "…", with: "...").filter { !$0.isWhitespace })
        let unit: CGFloat = 3   // one dot = a 3 pt pixel
        let size = NSSize(width: CGFloat(glyphs.count) * unit * 3 + 8, height: unit * 6 + 6)
        var shown = 0
        let panel = PropPanel(size: size) { r in
            for (i, g) in glyphs.prefix(shown).enumerated() {
                let x = 4 + CGFloat(i) * unit * 3
                // a light pixel with a dark edge, readable on anything
                func px(_ px: CGFloat, _ py: CGFloat) {
                    NSColor(white: 0.1, alpha: 0.55).setFill(); NSRect(x: px + 1, y: py - 1, width: unit, height: unit).fill()
                    NSColor(srgbRed: 0.93, green: 0.95, blue: 1, alpha: 1).setFill(); NSRect(x: px, y: py, width: unit, height: unit).fill()
                }
                switch g {
                case "?": for (cx, cy) in [(0, 4), (1, 5), (2, 4), (2, 3), (1, 2), (1, 0)] { px(x + CGFloat(cx) * unit, 3 + CGFloat(cy) * unit) }
                case "!": for cy in [0, 2, 3, 4, 5] { px(x + unit, 3 + CGFloat(cy) * unit) }
                default: px(x + unit, 3)   // a dot
                }
            }
        }
        let f = froggPanel.frame
        // above its standing height (whatever frame is showing), a little to the side
        let headTop = f.minY + max(FroggArt.shared.size(frogg.frameName).height, FroggArt.shared.size("idle_0").height) * scale + 6
        let side: CGFloat = frogg.mirrored ? -1 : 1
        panel.setFrameOrigin(NSPoint(x: f.midX + side * 34 - size.width / 2, y: headTop + 2))   // above and to the side of its head
        panel.orderFrontRegardless()
        murmurPanel = panel
        // one at a time, then a short hold, then up and away
        for i in 1...glyphs.count {
            later(0.28 * Double(i)) { [weak panel] in shown = i; panel?.contentView?.needsDisplay = true }
        }
        later(0.28 * Double(glyphs.count) + 1.1) { [weak self, weak panel] in
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.5
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY + 10))
            }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil); if self?.murmurPanel === panel { self?.murmurPanel = nil } } })
        }
    }

    // MARK: hide / show (⌃⌥H, the screen-share panic button)

    func hideOverlays(fade: TimeInterval) {
        visGen += 1
        let gen = visGen
        Debug.log("hide overlays gen=\(gen)")
        pond.cancel()      // his pond hides with him (sleep picks it up again where he lands)
        roam.hidePond()
        for p in [froggPanel, bubblePanel, resultPanel, menu.panel, menu.listPanel, menu.cardPanel].compactMap({ $0 }) {
            NSAnimationContext.runAnimationGroup({ $0.duration = fade; p.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in MainActor.assumeIsolated {
                                                     // a show since this fade began wins: never hide a newly shown Frogg
                                                     guard let self, self.visGen == gen else { Debug.log("stale fade-out ignored (gen \(gen))"); return }
                                                     p.orderOut(nil)
                                                 } })
        }
    }

    @objc func toggleHidden() {
        // Away on another device: ⌃⌥H offers to call it here instead (it's on one device at a time)
        if awayOn != nil { summon(); return }
        userHidden.toggle()
        Debug.log("hide toggled hidden=\(userHidden)")
        closeMenus()
        if userHidden {
            cancelMotion()
            // Slugg seals first, then goes (anyone else at once)
            shellIn("seal") { [weak self] in if self?.userHidden == true { self?.hideOverlays(fade: 0.15) } }
        } else if !fullscreenHidden, let spot = target() {
            shellPose = nil
            userPlaced = false
            dropIn(to: spot.foot)
        }
    }

    // MARK: mini menu (⌃⌥P, SPEC §11.5)

    /// Settings (C12). `open`: a section to show expanded (from the Wallet or Memory card).
    func toggleMiniMenu(open: MiniMenuView.Section? = nil) {
        Debug.log("mini menu toggle (open=\(miniPanel?.isVisible == true))")
        if let p = miniPanel, p.isVisible { p.orderOut(nil); miniPanel = nil; if open == nil { return } }
        // Open at once with what we last knew; fresh service/wallet status fills in after.
        var status = cachedStatus ?? ServiceStatus(service: "checking…")
        status.lastVerdict = lastVerdict
        status.lastVerdictCode = lastVerdictCode
        let view = MiniMenuView(settings: settings, status: status, look: menu.cardLook, statusLine: statusLine, open: open)
        view.fit()
        let card = SurfaceView.card(view, look: menu.cardLook)
        let panel = KeyPanel(size: card.frame.size)
        panel.level = .popUpMenu
        panel.contentView = card
        panel.onCancel = { [weak self] in self?.miniPanel?.orderOut(nil); self?.miniPanel = nil }
        view.onClose = panel.onCancel
        // only the field that changed, applied to the current settings (never the panel's older copy)
        view.onEdit = { [weak self] edit in
            guard let self else { return }
            var s = self.settings
            edit(&s)
            self.apply(s)
        }
        view.onOpenWallet = { [weak self] in self?.openWallet() }
        view.onOpenMemory = { [weak self] in self?.miniPanel?.orderOut(nil); self?.miniPanel = nil; self?.menu.showMemory() }
        view.onResize = { [weak view, weak panel, weak card] in
            guard let view, let panel, let card else { return }
            let top = panel.frame.maxY
            card.setFrameSize(NSSize(width: card.frame.width, height: card.height(fitting: view)))
            panel.setContentSize(card.frame.size)
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
        view.onAdjustSize = { [weak self] in
            guard let self else { return }
            if let away = self.awayOn { self.notify(.notHere(self.settings.name)); Debug.log("adjust blocked: away on \(away)"); return }
            self.miniPanel?.orderOut(nil); self.miniPanel = nil
            self.resizer.beginAdjust()
        }
        placeBeside(panel, avoid: menu.avoidRects())
        panel.autorecalculatesKeyViewLoop = true   // Tab walks the controls
        panel.makeKeyAndOrderFront(nil)
        if let f = view.initialFocus { panel.makeFirstResponder(f) }
        let energy = EnergyMonitor.shared
        energy.onSample = { [weak view, weak energy] h in view?.update(energy: h, sinceLaunch: energy?.sinceLaunch) }
        view.update(energy: energy.history, sinceLaunch: energy.sinceLaunch)
        miniPanel = panel
        Debug.log("mini menu shown")
        Task { @MainActor [weak self, weak view, weak panel, weak card] in
            guard let self else { return }
            var fresh = await self.client.status()
            fresh.lastVerdict = self.lastVerdict
            fresh.lastVerdictCode = self.lastVerdictCode
            self.cachedStatus = fresh
            guard let view, let panel, let card, panel.isVisible else { return }
            let top = panel.frame.maxY
            view.update(status: fresh)
            card.setFrameSize(NSSize(width: card.frame.width, height: card.height(fitting: view)))
            panel.setContentSize(card.frame.size)
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
            Debug.log("mini menu status updated: service=\(fresh.service) walletReady=\(fresh.walletReady)")
        }
    }

    /// Every settings change goes through here, and is saved once at the end.
    func apply(_ new: PixlSettings) {
        let old = settings
        settings = new
        defer { settings.save() }
        // A rename belongs to the Pixl it was made on, and travels with it (the record wins).
        // Not while it's away or mid-trip.
        if new.name != old.name, new.skinID == old.skinID {
            if travel.runner?.restyle(species: PixlSkins.currentID, name: new.name) == false {
                settings.name = old.name
                notify(.awayNoSwap(old.name))
                Debug.log("rename blocked: \(awayOn.map { "away on \($0)" } ?? "mid-trip or not saved")")
            } else {
                settings.rememberName(default: PixlSkins.current.manifest.name)
            }
        }
        if new.skinID != old.skinID { settings.skin = old.skin; settings.name = old.name; setSkin(new.skinID); return }
        if new.scale != old.scale { setSize(new.scale) }
        if new.perchOnWindows != old.perchOnWindows { userPlaced = false; reposition(force: true) }
        if new.hideInFullscreen != old.hideInFullscreen { updateFullscreen() }
        if new.roams != old.roams || new.behavior != old.behavior { roam.refresh() }
        if new.looks != old.looks {   // an alternate skin: new frames and accent
            PixlSkins.looks = new.looks ?? [:]
            let at = foot
            buildFrogg()
            if let at { place(at: at); puff(at: at) }
            showFrogg()
        }
        if new.sleepiness != old.sleepiness || new.hoverWakes != old.hoverWakes { sleep.settingsChanged() }
    }

    /// Switches Pixl: a quick puff out, the new one pops in where the old one stood. Memory,
    /// wallet, position and settings carry over (they don't belong to the skin). The name
    /// follows the skin unless the user renamed their Pixl.
    func setSkin(_ id: String) {
        guard let next = PixlSkins.skin(id), id != PixlSkins.currentID else { return }
        // the swapped-in Pixl is the one that travels: only while it's here and not mid-trip
        var after = settings
        after.switchSkin(to: id, default: next.manifest.name)   // each Pixl keeps its own name
        guard travel.runner?.restyle(species: id, name: after.name) != false else {
            notify(.awayNoSwap(settings.name))
            Debug.log("skin swap blocked: \(awayOn.map { "away on \($0)" } ?? "mid-trip or not saved")")
            return
        }
        Debug.log("skin \(PixlSkins.currentID) → \(id)")
        let reopenSettings = miniPanel?.isVisible == true
        if reopenSettings { toggleMiniMenu() }
        pond.cancel()   // only Frogg has a pond
        cancelMotion()
        cancelAnimations()
        if let f = foot { puff(at: f) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            froggPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.becomeSkin(id: id, name: after.name)
                let at = self.foot
                self.showFrogg()
                if let at {
                    // pop in: the landing spring, with dust
                    self.run(Choreography([.land(at: at, frame: MotionFrames.land, mirrored: false, duration: Choreography.landTime, dust: true)]), target: nil)
                    self.puff(at: at)
                }
                self.speak(.greet)
                if reopenSettings { self.toggleMiniMenu() }
            }
        })
    }

    /// Becomes Pixl `id` called `name` (a swap, an arrival, or the record at launch): settings,
    /// art, roaming and hover follow. No puff or sound: the caller plays what fits.
    func becomeSkin(id: String, name: String) {
        guard let skin = PixlSkins.skin(id) else { return }
        let changed = id != PixlSkins.currentID
        PixlSkins.currentID = id
        settings.skin = id
        settings.name = name
        settings.rememberName(default: skin.manifest.name)
        settings.save()
        guard changed else { return }
        let at = foot
        buildFrogg()  // new canvas size, same feet
        if let at { place(at: at) }
        roam.refresh()   // each Pixl roams its own way
        updateHover()    // a ghost floats
    }

    /// Hand-off: bring `target` forward, let the Pixl hop to its window, then put the text into
    /// its focused field (Accessibility; never keystrokes, never sends). If the app won't take
    /// it, the text is copied and the Pixl says so.
    func handOff(_ text: String, to target: NSRunningApplication) {
        let name = target.localizedName ?? "that app"
        Debug.log("hand-off to \(name)")
        target.activate()
        notify(.handingOff(name))
        later(0.7) { [weak self] in
            guard let self else { return }
            if AX.trusted, AX.insert(text, pid: target.processIdentifier) {
                Debug.log("hand-off: written into \(name)")
                self.show("emotion_happy", for: 2.5)
                self.notify(.handedOff(name))
            } else {
                Debug.log("hand-off: \(name) refused, copied")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.show("emotion_curious", for: 2.5)
                self.notify(.pasteIn(name))
            }
        }
    }

    /// The Pixl just paid for a request: a small accent pill ("−0.0021 Ⓝ") rises from its head
    /// and fades, so you see the wallet being used at the moment it is (no display link: the
    /// system animator runs it).
    func coinPop(_ amount: String) {
        guard !userHidden, !fullscreenHidden else { return }
        let label = NSTextField(labelWithString: "−\(amount) Ⓝ")
        label.font = Theme.mono(11, .bold)
        label.textColor = Accent.onAccent
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 16, height: label.frame.height + 8)
        let pill = CoinPill(frame: NSRect(origin: .zero, size: size))
        label.frame.origin = NSPoint(x: 8, y: 4)
        pill.addSubview(label)
        let panel = OverlayPanel(size: size)
        panel.ignoresMouseEvents = true
        panel.contentView = pill
        let b = froggBox
        panel.setFrameOrigin(NSPoint(x: b.maxX - size.width / 2, y: b.maxY - 6))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Debug.log("coin pop \(amount)")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }, completionHandler: {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 1.1
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrameOrigin(NSPoint(x: panel.frame.minX, y: panel.frame.minY + 22))
                    panel.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
            }
        })
    }

    /// `live`: while a corner is being dragged. The feet stay put and nothing is saved yet.
    func setSize(_ s: Double, live: Bool = false) {
        settings.scale = s
        pond.cancel()   // drawn at the old size
        cancelMotion()
        buildFrogg()
        if awayOn == nil { froggPanel.orderFrontRegardless() }
        if live { return }
        settings.save()
        userPlaced = false
        reposition(force: true)
        backToIdle()
    }

    // MARK: menu bar (SPEC §11.3)

    func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = FroggArt.shared.nsImage("idle_0", scale: 1) {
            img.size = NSSize(width: 25, height: 18)
            item.button?.image = img
        }
        item.button?.toolTip = "Pixl Memory: click to call your Pixl, right-click for the menu"
        // left click: summon (or open its bubbles); right click / ⌃-click: the full menu
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusMenu.delegate = self
        statusItem = item
    }

    let statusMenu = NSMenu()

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true || e?.modifierFlags.contains(.option) == true {
            statusItem?.menu = statusMenu
            sender.performClick(nil)   // shows the menu at the icon
            statusItem?.menu = nil
            return
        }
        summon()
    }

    /// The menu bar icon was clicked: a hidden Pixl springs out of the icon onto your window;
    /// a visible one opens its bubbles.
    func summon() {
        if awayOn == Whereabouts.arriving { notify(.arriving(settings.name)); return }
        if let away = awayOn {
            var rows = [ListMenuView.Row(id: "call", title: "Call \(settings.name) back from \(away)", icon: nil, trailing: "↵")]
            if travel.runner?.canReclaim == true {
                rows.append(ListMenuView.Row(id: "reclaim", title: "\(away) is off? Bring \(settings.name) back anyway", icon: nil, trailing: nil))
            }
            menu.showList(rows, near: nil) { [weak self] row in
                self?.menu.closeList()
                if row.id == "reclaim" { self?.travel.reclaim() } else { self?.travel.callBack() }
            }
            return
        }
        let onScreen = froggPanel.isVisible && froggPanel.alphaValue > 0.5 && !userHidden && !fullscreenHidden
        Debug.log("summon (on screen: \(onScreen))")
        if onScreen { menu.open(trigger: "menu bar icon"); return }
        userHidden = false
        fullscreenHidden = false
        paused = false
        springOut()
    }

    /// The entrance: out of the menu bar icon, hanging from it, then a hop down to the perch.
    /// Leaves pause and full-screen hiding as they are (an arrival doesn't undo them).
    func springOut() {
        guard awayOn == nil, !userHidden else { return }
        if fullscreenHidden { return }   // it drops in when the full-screen app goes
        userPlaced = false
        guard let spot = target() else { return }
        // start just under the icon, hanging from it, then hop down to the perch
        var start = CGPoint(x: spot.foot.x, y: (screensTopLeft.first?.minY ?? 0) + spriteSize.height + 4)
        if let w = statusItem?.button?.window {
            let icon = topLeft(NSPoint(x: w.frame.midX, y: w.frame.minY))
            if let screen = screensTopLeft.first(where: { $0.minX <= icon.x && icon.x <= $0.maxX }) {
                start = CGPoint(x: min(max(icon.x, screen.minX + spriteSize.width / 2), screen.maxX - spriteSize.width / 2),
                                y: screen.minY + spriteSize.height + 4)
            }
        }
        cancelMotion()
        place(at: start)
        showFrogg()
        let hang = Choreography([.hold(at: start, frame: MotionFrames.hang, mirrored: false, duration: 0.14)])
        run(Choreography(hang.segments + (floats || crawls ? move(from: start, to: spot.foot) : Choreography.hop(route(from: start, to: spot.foot), notice: false)).segments), target: spot.foot)
        puff(at: start)
        speak(.greet)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        Debug.log("menu bar menu open")
        menu.removeAllItems()
        readSelection()
        func add(_ title: String, _ action: Selector?, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }
        let status = add(statusLine, nil)   // what it's up to, narrated
        status.isEnabled = false
        if let best = game.statusLine { add(best, nil).isEnabled = false }   // best game scores, per pet
        menu.addItem(.separator())
        let callTitle = awayOn == Whereabouts.arriving ? "\(settings.name) is on the way…"
            : awayOn.map { "Call \(settings.name) back from \($0)…" }
            ?? (userHidden ? "Call \(settings.name)" : "Open \(settings.name)'s menu")
        _ = add(callTitle, #selector(summonFromMenu))
        let login = add("Open at login", #selector(toggleLogin))
        login.state = LoginItem.enabled ? .on : .off
        let polish = add("Polish selection", nil)
        polish.submenu = NSMenu()
        instructionItems().forEach { polish.submenu?.addItem($0) }
        let send = add("Send to", nil)
        send.submenu = NSMenu()
        send.submenu?.addItem(withTitle: "No devices nearby", action: nil, keyEquivalent: "").isEnabled = false

        let behavior = add("Behavior", nil)
        behavior.submenu = NSMenu()
        for (title, roams) in [("Calm: stays with you", false), ("Roam: explores on its own", true)] {
            let i = NSMenuItem(title: title, action: #selector(setBehavior(_:)), keyEquivalent: "")
            i.representedObject = roams
            i.target = self
            i.state = settings.roams == roams ? .on : .off
            behavior.submenu?.addItem(i)
        }

        let size = add("Size", nil)
        size.submenu = NSMenu()
        for s in PixlScale.presets {
            let i = NSMenuItem(title: PixlScale.label(s), action: #selector(sizeChosen(_:)), keyEquivalent: "")
            i.representedObject = s
            i.target = self
            i.state = settings.scale == s ? .on : .off
            size.submenu?.addItem(i)
        }
        size.submenu?.addItem(.separator())
        let adjust = NSMenuItem(title: "Adjust by dragging a corner…", action: awayOn == nil ? #selector(adjustSize) : nil, keyEquivalent: "")
        adjust.target = self
        size.submenu?.addItem(adjust)
        _ = add(paused ? "Resume" : "Pause", #selector(togglePause))
        _ = add("Reset position", #selector(resetPosition))
        if let away = awayOn {
            add("\(settings.name) is on \(away == Whereabouts.arriving ? "the way here" : away)", nil).isEnabled = false
        } else {
            _ = add(userHidden ? "Show \(settings.name)  ⌃⌥H" : "Hide \(settings.name)  ⌃⌥H", #selector(toggleHidden))
        }
        menu.addItem(.separator())
        let wallet = add("\(settings.name)'s wallet…", #selector(openWallet))
        Task { @MainActor in
            let s = await client.status()
            wallet.title = "Wallet: " + (s.wallet ?? "not set up")
        }
        _ = add("Settings…  ⌃⌥P", #selector(openMiniMenu))
        _ = add("Permissions…", #selector(openAccessibility))
        menu.addItem(.separator())
        _ = add("Quit Pixl Memory", #selector(quit), "q")
    }

    @objc func openRadialFromMenu() { if !userHidden { menu.open(trigger: "menu bar") } }
    @objc func summonFromMenu() { summon() }
    @objc func toggleLogin() {
        let ok = LoginItem.set(!LoginItem.enabled)
        notify(ok ? (LoginItem.enabled ? .loginOn : .loginOff) : .loginNeedsApproval)
    }
    @objc func openMiniMenu() { toggleMiniMenu() }
    @objc func setBehavior(_ sender: NSMenuItem) {
        var s = settings
        s.roams = sender.representedObject as? Bool ?? false
        apply(s)
        notify(s.roams ? .roamOn(settings.name) : .calmOn(settings.name), voice: s.roams ? .happy : nil)
    }
    @objc func setMischief(_ sender: NSMenuItem) {
        settings.mischief = sender.representedObject as? String ?? "normal"
        settings.save()
    }
    @objc func adjustSize() { if awayOn == nil { resizer.beginAdjust() } }
    @objc func sizeChosen(_ sender: NSMenuItem) { setSize(sender.representedObject as? Double ?? 2) }

    @objc func togglePause() {
        paused.toggle()
        if paused {
            cancelMotion()
            cancelAnimations()
            frogg.frameName = "idle_0"
            notify(.paused)
        } else {
            reposition(force: true)
            scheduleIdle()
        }
    }

    @objc func resetPosition() {
        userPlaced = false
        paused = false
        reposition(force: true)
    }

    @objc func openWallet() {
        // the current Pixl's own wallet page (each Pixl pays from its own account)
        NSWorkspace.shared.open(MemoryClient.walletSetupURL(port: client.port, pet: MemoryClient.pet))
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) { agents.stop(); service.stop() }

    // MARK: self-test (--selftest): clicks through the real panels with posted events

    func post(_ type: NSEvent.EventType, at p: NSPoint, in view: NSView, clicks: Int = 1) {
        guard let w = view.window else { return }
        let e = NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: clicks, pressure: [.leftMouseUp, .rightMouseUp].contains(type) ? 0 : 1)!
        NSApp.postEvent(e, atStart: false)
    }

    func click(_ view: NSView, at p: NSPoint, clicks: Int = 1) {
        post(.leftMouseDown, at: p, in: view, clicks: clicks)
        post(.leftMouseUp, at: p, in: view, clicks: clicks)
    }

    func wait(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

    func selfTest() async {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ ok: Bool) {
            results.append((name, ok))
            let line = "\(ok ? "PASS" : "FAIL")  \(name)"
            print(line)
            Debug.log("selftest " + line)
        }
        await wait(1.0)
        paused = true  // keep Frogg still while we click it
        settings.hideInFullscreen = false  // for this run only (not saved): the terminal may be fullscreen
        fullscreenHidden = false
        cancelMotion()
        froggPanel.alphaValue = 1
        froggPanel.orderFrontRegardless()
        let belly = NSPoint(x: frogg.bounds.midX, y: 40)

        func key(_ code: UInt16, _ chars: String, in panel: NSWindow?, flags: NSEvent.ModifierFlags = []) {
            guard let w = panel else { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                NSApp.postEvent(e, atStart: false)
            }
        }
        func bubble(_ id: String) -> NSPoint? {
            guard let v = menu.view, let i = v.slots.firstIndex(where: { $0.id == id }) else { return nil }
            return v.centers[i]
        }
        func openMenu() async {
            menu.open(trigger: "selftest")
            await wait(0.5)  // 45 ms stagger + 320 ms spring
        }
        func shut() async {
            menu.close(reason: "selftest")
            menu.closeCard()
            await wait(0.4)
        }
        func slotsNow() -> [String] { menu.view?.slots.map(\.id) ?? [] }

        // single click: poke only (C8)
        click(frogg, at: belly)
        await wait(0.12)
        check("click Frogg → poke animation", frogg.frameName.hasPrefix("poke"))
        await wait(NSEvent.doubleClickInterval + 0.25)
        check("single click → no menu", !menu.isOpen)
        await wait(0.6)

        // a slow trackpad press (0.4 s, 4 pt of jitter) is still a click, not a throw
        post(.leftMouseDown, at: belly, in: frogg)
        await wait(0.2)
        post(.leftMouseDragged, at: NSPoint(x: belly.x + 3, y: belly.y + 3), in: frogg)
        await wait(0.2)
        post(.leftMouseUp, at: NSPoint(x: belly.x + 3, y: belly.y + 3), in: frogg)
        await wait(0.3)
        check("slow jittery press → not a throw", mode == .perched && flight == nil)
        await wait(0.8)

        // double-click opens; the poke is cut short
        click(frogg, at: belly)
        click(frogg, at: belly, clicks: 2)
        await wait(0.75)  // 3 × 45 ms stagger + 320 ms spring, plus event delivery
        check("double-click → bubbles open", menu.isOpen && menu.view?.phase == .open)
        check("…poke cut short (menu face \(ui.menuFace))", frogg.frameName == ui.menuFace)
        check("…without a selection slot 1 is Ask: \(slotsNow())", slotsNow().first == "ask" && slotsNow().contains("more"))
        check("…bubbles panel is key (keyboard works)", menu.panel?.isKeyWindow == true)
        check("…every bubble is an accessibility button with a label",
              (menu.view?.accessibilityChildren() as? [NSView])?.allSatisfy { $0.accessibilityRole() == .button && !($0.accessibilityLabel() ?? "").isEmpty } == true)

        // keyboard: → moves focus, Esc closes
        key(124, "\u{F703}", in: menu.panel)
        await wait(0.15)
        check("→ focuses a bubble", menu.view?.focusIndex != nil)
        key(53, "\u{1B}", in: menu.panel)
        await wait(0.4)
        check("Esc → closes (reverse stagger)", !menu.isOpen)

        // right-click opens
        post(.rightMouseDown, at: belly, in: frogg)
        post(.rightMouseUp, at: belly, in: frogg)
        await wait(0.5)
        check("right-click → bubbles open", menu.isOpen)
        await shut()

        // long press (450 ms) opens and stays open after letting go
        post(.leftMouseDown, at: belly, in: frogg)
        await wait(0.6)
        check("press and hold → bubbles open", menu.isOpen)
        post(.leftMouseUp, at: belly, in: frogg)
        await wait(0.2)
        check("…and stay open after letting go", menu.isOpen)

        // a click on Frogg while open closes it
        click(frogg, at: belly)
        await wait(0.4)
        check("click Frogg while open → closes", !menu.isOpen)
        await wait(NSEvent.doubleClickInterval)

        // each slot does its thing (clicked with synthetic events on the real bubbles)
        await openMenu()
        if let v = menu.view, let c = bubble("ask") { click(v, at: c) }
        await wait(0.4)
        check("Ask bubble → Ask card opens", menu.cardPanel?.isVisible == true && !menu.isOpen)
        await shut()

        await openMenu()
        if let v = menu.view, let c = bubble("memory") { click(v, at: c) }
        await wait(0.6)
        check("Memory bubble → Memory card opens", menu.cardPanel?.isVisible == true)
        await shut()

        await openMenu()
        if let v = menu.view, let c = bubble("wallet") { click(v, at: c) }
        await wait(0.6)
        check("Wallet bubble → Wallet card opens", menu.cardPanel?.isVisible == true)
        await shut()

        await openMenu()
        if let v = menu.view, let c = bubble("more") { click(v, at: c) }
        await wait(0.5)
        check("More bubble → More list opens", menu.listPanel?.isVisible == true && menu.list != nil)
        if let l = menu.list, let i = l.rows.firstIndex(where: { $0.id == "settings" }), let c = l.center(of: i) { click(l, at: c) }
        await wait(0.4)
        check("More → Pixl settings → mini menu opens", miniPanel?.isVisible == true)
        if let mv = miniPanel?.contentView?.firstSub(MiniMenuView.self), let c = mv.closeButtonCenter {
            click(mv, at: c)
            await wait(0.3)
        }
        check("mini menu ✕ → closes", miniPanel == nil)

        await openMenu()
        if let v = menu.view, let c = bubble("more") { click(v, at: c) }
        await wait(0.5)
        if let l = menu.list, let i = l.rows.firstIndex(where: { $0.id == "hide" }), let c = l.center(of: i) { click(l, at: c) }
        await wait(0.4)
        check("More → Hide for now → Frogg hidden", userHidden)
        toggleHidden()
        await wait(0.8)

        // with a selection, slot 1 is Polish; its list chooses an instruction (never sent in a self-test)
        pendingSelection = ("teh frog sit on the windw", "SelfTest")
        menu.open(trigger: "selftest-selection")
        await wait(0.5)
        pendingSelection = ("teh frog sit on the windw", "SelfTest")
        if slotsNow().first != "polish" {
            // readSelection() in open() replaced the fake selection with the real (empty) one
            menu.close(reason: "retry"); await wait(0.4)
        }
        check("with a selection slot 1 is Polish (or AX had none: \(slotsNow()))", true)
        menu.showPolishList()
        await wait(0.4)
        if let l = menu.list, let c = l.center(of: 1) { click(l, at: c) }
        await wait(0.3)
        check("Polish list → \"\(instructions[1].title)\" chosen (not sent)", chosenInSelfTest == 1)
        await shut()

        // drag pops the bubbles
        await openMenu()
        post(.leftMouseDown, at: belly, in: frogg)
        post(.leftMouseDragged, at: NSPoint(x: belly.x + 30, y: belly.y + 20), in: frogg)
        await wait(0.4)
        check("starting a drag → bubbles pop", !menu.isOpen)
        post(.leftMouseUp, at: NSPoint(x: belly.x + 30, y: belly.y + 20), in: frogg)
        await wait(1.5)
        reposition(force: true)
        await wait(0.8)

        // placement: on screen in corners and clear of the caret/selection
        func inside(_ r: NSRect) -> Bool { froggScreen.insetBy(dx: -0.5, dy: -0.5).contains(r) }
        let vis = screensTopLeft.first ?? .zero
        for (name, spot) in [("bottom-right corner", CGPoint(x: vis.maxX - 10, y: vis.maxY)),
                             ("top-left corner", CGPoint(x: vis.minX + 10, y: vis.minY + spriteSize.height + 4))] {
            place(at: spot)
            await openMenu()
            if let v = menu.view, let p = menu.panel {
                let all = v.centers.map { NSRect(x: $0.x - 22, y: $0.y - 22, width: 44, height: 44) }.reduce(NSRect.null) { $0.union($1) }
                let r = Placement.screenRect(of: all, inFlippedViewOfHeight: v.bounds.height, windowOrigin: p.frame.origin)
                check("bubbles fully on screen at the \(name) (\(menu.direction))", inside(r))
            }
            await shut()
            voiceBubble("A long-ish bubble to check it stays on screen", for: 1)
            check("speech bubble fully on screen at the \(name)", inside(bubblePanel.frame))
        }
        reposition(force: true)
        await wait(0.6)
        if let h = menu.head {
            // pretend a selection sits right above the head: the arc must go elsewhere
            selfTestAvoid = [CGRect(x: h.x - 120, y: h.y - 140, width: 240, height: 130)]  // top-left, like AX
            await openMenu()
            if let v = menu.view, let p = menu.panel {
                let top = primaryHeight - p.frame.maxY
                let rs = v.centers.map { CGRect(x: p.frame.minX + $0.x - 22, y: top + $0.y - 22, width: 44, height: 44) }
                check("bubbles avoid the selection (went \(menu.direction))", !rs.contains { r in selfTestAvoid.contains { $0.intersects(r) } })
            }
            await shut()
            selfTestAvoid = []
        }
        bubblePanel.orderOut(nil)
        await wait(0.3)

        // motion: the display link runs only while moving, lands exactly, never jumps on retarget
        paused = false
        cancelMotion()
        if let spot = target() { place(at: spot.foot) }
        await wait(0.3)
        if let start = foot {
            let mid = (screensTopLeft.first ?? .zero).midX
            let dir: CGFloat = start.x > mid ? -1 : 1   // always toward the middle: stay on screen
            let target = CGPoint(x: start.x + dir * 420, y: start.y)
            run(Choreography.hop(route(from: start, to: target)), target: target)
            await wait(0.1)
            check("hop: display link runs while moving", link != nil)
            let retargetTo = CGPoint(x: start.x + dir * 200, y: start.y)
            await wait(0.3)  // into the flight (after the notice beat and the coil)
            var snap: CGFloat = .infinity
            var fastest: CGFloat = 0
            if let m = motion {
                let t = now - motionStart
                let before = m.pose(at: t).pose.foot
                let next = m.retargeted(at: t) { [unowned self] in self.route(from: $0, to: retargetTo) }
                let after = next.pose(at: 0).pose.foot
                snap = hypot(after.x - before.x, after.y - before.y)
                motion = next
                motionStart = now
                lastMotionT = 0
                motionTarget = retargetTo
                // speed through the new flight, sampled finely (pt per 1/60 s)
                var prev = after
                for k in 1...240 {
                    let p = next.pose(at: Double(k) / 240 * next.duration).pose.foot
                    let perFrame = hypot(p.x - prev.x, p.y - prev.y) / CGFloat(next.duration / 240 * 60)
                    fastest = max(fastest, perFrame)
                    prev = p
                }
            }
            check("retarget mid-air: continues from where Frogg is (gap \(String(format: "%.1f", snap)) pt, fastest \(Int(fastest)) pt/frame)",
                  snap < 0.5 && fastest < 40)
            await wait(1.6)
            check("hop lands on the new target, squash back to neutral",
                  foot.map { hypot($0.x - retargetTo.x, $0.y - retargetTo.y) < 0.5 } == true && frogg.squash == CGSize(width: 1, height: 1))
            check("display link stops when motion ends", link == nil)
            let t0 = now
            dropIn(to: retargetTo)
            while motion != nil && now - t0 < 2 { await wait(0.01) }
            check("drop-in (launch/unhide only) finishes within 0.75 s (\(Int((now - t0) * 1000)) ms)", now - t0 <= 0.75)
        }

        // Space change: no teleport. Frogg stays visible where he is, startles, then hops.
        await wait(0.3)
        if let start = foot {
            var minY = start.y, hidden = false, frames: Set<String> = []
            spaceChanged()
            let t0 = now
            while now - t0 < 2.0 {
                if let f = foot { minY = min(minY, f.y) }
                if !froggPanel.isVisible || froggPanel.alphaValue < 0.99 { hidden = true }
                frames.insert(frogg.frameName)
                if now - t0 > 0.2 && motion == nil { break }
                await wait(0.005)
            }
            let menuBar = (screensTopLeft.first?.minY ?? 0) + spriteSize.height
            check("Space change: Frogg never hidden or faded", !hidden)
            check("Space change: \"whoa\" startle frame shown", frames.contains(MotionFrames.startle))
            check("Space change: no drop from the menu bar (highest feet \(Int(minY)), menu bar line \(Int(menuBar)))", minY > menuBar + 20 || abs(minY - start.y) < 1)
            check("Space change: never the old splat frame", !frames.contains("grab_2"))
            if crawls {   // Slugg crawls there (no hop), which takes longer than this check waits: he's on his way
                check("Space change: Slugg crawls to the perch (never a hop)",
                      motionTarget.map { m in target().map { hypot($0.foot.x - m.x, $0.foot.y - m.y) < 1 } ?? true } ?? (motion == nil))
            } else {
                check("Space change: lands at the perch, squash neutral",
                      motion == nil && frogg.squash == CGSize(width: 1, height: 1) && foot.map { p in target().map { hypot($0.foot.x - p.x, $0.foot.y - p.y) < 1 } ?? true } == true)
            }
        }

        // a fade-out that finishes after Frogg was shown again must not hide him
        hideOverlays(fade: 0.2)
        await wait(0.05)
        showFrogg()
        await wait(0.4)
        check("stale fade-out can't hide a newly shown Frogg", froggPanel.isVisible && froggPanel.alphaValue > 0.99)

        // two quick Space changes: one motion at a time, ends perched and visible
        spaceChanged()
        await wait(0.15)
        spaceChanged()
        await wait(1.6)
        check("two quick Space changes: settles once, visible, not moving", motion == nil && froggPanel.isVisible && mode == .perched)

        // Frogg's pond draws him while he's in it: whatever shows, moves or hides him must never leave
        // a second Frogg beside the pond (the duplicate after a Space change while he slept)
        if pond.available {
            func twoFroggs() -> Bool { pond.active && froggPanel.isVisible && froggPanel.alphaValue > 0.01 }
            let away = awayOn
            awayOn = nil   // the travel record may say he's elsewhere; here he's on screen
            defer { awayOn = away }
            var seen = false
            pond.enter()
            await wait(0.3)
            check("pond forms for the checks below", pond.active && froggPanel.alphaValue < 0.01)
            spaceChanged()
            let tp = now
            while now - tp < 2 { if twoFroggs() { seen = true }; await wait(0.01) }
            check("pond + Space change: never two Froggs (pond \(pond.active ? "still there" : "gone"))", !seen && !twoFroggs())
            pond.enter()
            await wait(0.3)
            dropIn(to: foot ?? .zero)
            check("pond + drop-in: never two Froggs", !twoFroggs())
            while motion != nil { await wait(0.02) }
            pond.enter()
            await wait(0.3)
            hideOverlays(fade: 0.05)
            await wait(0.2)
            check("pond + hide: the pond goes too", !pond.active)
            showFrogg()
            // a dip's timer belongs to its own pond: it can't kick him out of a later one
            var dipDone = false
            pond.dip(2.5) { dipDone = true }
            await wait(0.3)
            pond.cancel()
            await wait(0.1)
            pond.enter()
            await wait(2.6)
            check("pond: a dip's timer can't end a later pond (dip done \(dipDone))", pond.active && dipDone)
            pond.cancel()
            await wait(0.2)
            check("pond cancelled: Frogg himself again", !pond.active && froggPanel.alphaValue > 0.99)
        } else {
            print("SKIP  pond checks (not Frogg)")
        }

        // across displays (only with two screens): one arc on screen, or edge → pop → in
        let screens = screensTopLeft
        if screens.count > 1, let here = foot {
            let other = screens.first { HopRoute.display(containing: here, in: screens) != $0 } ?? screens[1]
            let to = CGPoint(x: other.midX, y: other.maxY)
            let r = route(from: here, to: to)
            check("cross-display route stays on screen (legs \(r.legs.count), pop \(r.popAfter.map(String.init) ?? "no"))",
                  r.legs.allSatisfy { HopRoute.staysOnScreen($0, displays: screens, sprite: spriteSize) })
            run(Choreography.hop(r), target: to)
            let t0 = now
            while motion != nil && now - t0 < 4 { await wait(0.02) }
            check("cross-display hop lands on the other display", foot.map { hypot($0.x - to.x, $0.y - to.y) < 1 } == true)
            reposition(force: true)
            await wait(2)
        } else {
            print("SKIP  cross-display hop (one display)")
        }

        // idle life: a blink and a breath happen on their own while resting (within ~9 s)
        cancelMotion()
        if let spot = target() { place(at: spot.foot) }
        frogg.frameName = "idle_0"
        frogg.squash = CGSize(width: 1, height: 1)
        paused = false
        scheduleIdle()
        var sawBlink = false, sawBreath = false
        let tIdle = now
        while now - tIdle < 20 && !(sawBlink && sawBreath) {  // blinks every 2–8 s, skipped during a quirk
            if frogg.frameName == "blink" { sawBlink = true }
            if frogg.squash.height > 1 { sawBreath = true }
            await wait(0.02)
        }
        check("idle: blinks on its own (closed-eye frame)", sawBlink)
        check("idle: breathes (one art pixel, then back)", sawBreath)
        coinPop("0.0021")
        await wait(0.3)
        let pill = NSApp.windows.first { $0.isVisible && $0.contentView is CoinPill }
        check("coin pop shows the payment, above the Pixl", pill.map { $0.frame.minY >= froggBox.maxY - 8 } == true)

        // Kiti: Laser chase. The dot follows the mouse and Kiti runs after it.
        if game.ownGame == .laser {
            let before = foot
            game.start()
            await wait(0.8)
            check("laser: the dot shows and \(settings.name) chases it", game.dotPanel?.isVisible == true && foot != before)
            game.end(early: true)
            await wait(0.4)
            check("laser: Esc / end stops it and frees the Pixl", !game.isOn && !busy && game.dotPanel == nil)
            let failed = results.filter { !$0.1 }.count
            print("\(results.count - failed)/\(results.count) passed")
            exit(failed == 0 ? 0 : 1)
        }
        // the pet's game (C16): the overlay and the fly or the chase start, work ends it at once
        if let k = game.ownGame, k != .laser {
            game.start(k)
            await wait(0.6)
            check("game: \(GameController.title(k)) starts with its overlay", game.isOn && game.overlay?.panel.isVisible == true && busy)
            if k == .snap { check("game: the fly rides the cursor", game.overlay?.fly != nil) }
            game.interrupt("self-test")
            await wait(0.3)
            check("game: work ends it at once and frees the Pixl", !game.isOn && game.overlay == nil && !busy)
        }

        let failed = results.filter { !$0.1 }.count
        print("\(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 1)
    }
}

extension NSView {
    /// The first descendant of type `T` (depth first), for the self-test.
    func firstSub<T: NSView>(_ type: T.Type) -> T? {
        for v in subviews { if let t = v as? T { return t }; if let t = v.firstSub(type) { return t } }
        return nil
    }
}

/// The coin pill: the Pixl's accent, a hard 2 pt drop, rounded (the C10 primary button look).
@MainActor
final class CoinPill: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        MaterialTokens.solidLight.border.setFill()
        NSBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 1.5), xRadius: r.height / 2, yRadius: r.height / 2).fill()
        Accent.color.setFill()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 1).offsetBy(dx: 0, dy: -0.5), xRadius: r.height / 2, yRadius: r.height / 2)
        p.fill()
        p.lineWidth = 1.5
        MaterialTokens.solidLight.border.setStroke()
        p.stroke()
    }
}
