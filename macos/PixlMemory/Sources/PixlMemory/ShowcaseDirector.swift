import AppKit
import Carbon.HIToolbox
import PixlMemoryKit
import PixlzCore

/// Where `PixlMemory showcase <cmd>` posts its commands.
enum ShowcaseCommand {
    static let name = Notification.Name("com.pixl.memory.showcase")
}

/// One step of a scene: something real the app does (a hop, a payment, a card), on cue.
struct ShowcaseBeat {
    let name: String
    /// How long to hold after it before the next beat, when a scene plays hands-free.
    var hold: TimeInterval = 0.6
    let run: @MainActor (ShowcaseDirector) async -> Void
}

struct ShowcaseScene {
    let id: String
    let title: String
    /// Puts everything where the scene starts (windows, pages, the Pixl's spot). Run on reset.
    var setup: @MainActor (ShowcaseDirector) async -> Void = { _ in }
    let beats: [ShowcaseBeat]
}

/// Showcase mode: a recording aid, never on in a normal run. Only with `--showcase` or
/// `PIXL_SHOWCASE=1`. Named scenes of ordered beats, each a real feature triggered on cue:
///   ⌃⌥K next beat · ⌃⌥⇧K previous · ⌃⌥R restart the scene · Esc reset
///   `PixlMemory showcase run <scene>` plays a scene hands-free (also next/prev/restart/reset/select).
/// Takes match: one fixed random seed. A beat waiting on something live (inference, attestation,
/// testnet) shows a spinner and only moves on when it lands.
@MainActor
final class ShowcaseDirector {
    static var enabled: Bool {
        CommandLine.arguments.contains("--showcase") || ProcessInfo.processInfo.environment["PIXL_SHOWCASE"] == "1"
    }
    /// `--rehearse`: scenes that wait on the model show a labelled stand-in instead (no inference,
    /// no payment), to check framing. Never for a take.
    static var rehearsing: Bool { CommandLine.arguments.contains("--rehearse") }
    /// The same seed every take.
    static let seed: UInt64 = 1114
    var rng = SeededRandom(seed: ShowcaseDirector.seed)

    unowned let app: AppController
    private(set) var scenes: [ShowcaseScene] = []
    private(set) var sceneIndex = 0
    private(set) var beatIndex = 0
    private var running: Task<Void, Never>?
    private var escRef: EventHotKeyRef?
    private(set) var stage: GameOverlay?
    private var ticker: DisplayTicker?

    init(app: AppController) { self.app = app }

    var scene: ShowcaseScene? { scenes.indices.contains(sceneIndex) ? scenes[sceneIndex] : nil }

    /// Your own size, put back on reset (takes use a bigger Pixl, live only).
    private var ownScale = 2.0
    /// Your Agents settings, put back on reset (C2 and C3 answer and reply from Pixlz).
    private var ownAnswerHere = false, ownReplyHere = true

    func start() {
        guard Self.enabled else { return }
        ownScale = app.settings.scale
        ownAnswerHere = app.agents.answerHere
        ownReplyHere = app.agents.replyHere
        scenes = ShowcaseScenes.all
        Sfx.shared.forced = true
        let hk = HotKeys.shared
        hk.register(.k) { [weak self] in self?.next() }
        hk.register(.k, shift: true) { [weak self] in self?.previous() }
        hk.register(.r) { [weak self] in self?.restart() }
        escRef = hk.register(.escape, modifiers: 0) { [weak self] in self?.reset() }
        DistributedNotificationCenter.default().addObserver(forName: ShowcaseCommand.name, object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.command(info["do"] ?? "", scene: info["scene"] ?? "") }
        }
        Debug.log("showcase: on (\(scenes.count) scenes: \(scenes.map(\.id).joined(separator: " ")))")
    }

    func command(_ cmd: String, scene id: String) {
        switch cmd {
        case "run": run(id)
        case "select": select(id)
        case "next": next()
        case "prev", "previous": previous()
        case "restart": restart()
        case "reset": reset()
        default: Debug.log("showcase: unknown command \(cmd)")
        }
    }

    // MARK: moving through beats

    /// Picks a scene and sets it up (nothing plays yet).
    func select(_ id: String) {
        guard let i = scenes.firstIndex(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            Debug.log("showcase: no scene \(id)"); return
        }
        cancel()
        sceneIndex = i
        beatIndex = 0
        running = Task { [weak self] in await self?.prepare() }
    }

    /// The next beat (after the last one, on to the next scene's setup).
    func next() {
        guard running == nil, let s = scene else { return }
        guard beatIndex < s.beats.count else {
            sceneIndex = (sceneIndex + 1) % max(scenes.count, 1)
            beatIndex = 0
            running = Task { [weak self] in await self?.prepare(); self?.running = nil }
            return
        }
        let beat = s.beats[beatIndex]
        beatIndex += 1
        Debug.log("showcase: \(s.id) · \(beat.name)")
        running = Task { [weak self] in
            guard let self else { return }
            await beat.run(self)
            self.running = nil
        }
    }

    /// Back one beat: the scene resets and that beat is armed again (⌃⌥K replays it).
    func previous() {
        let target = max(0, beatIndex - 1)
        restart()
        beatIndex = 0
        running = Task { [weak self] in
            guard let self else { return }
            await self.prepare()
            // replay the beats before it, quickly, so the scene is where that beat starts
            if let s = self.scene { for b in s.beats.prefix(target) { await b.run(self) } }
            self.beatIndex = target
            self.running = nil
        }
    }

    func restart() {
        cancel()
        beatIndex = 0
        running = Task { [weak self] in await self?.prepare(); self?.running = nil }
    }

    /// Esc: stop, clear the stage, the Pixl back to normal.
    func reset() {
        cancel()
        beatIndex = 0
        clearStage()
        clearDesk()
        ShowcaseScenes.cleanup()
        if app.settings.scale != ownScale { app.setSize(ownScale, live: true) }
        if app.agents.answerHere != ownAnswerHere { app.agents.answerHere = ownAnswerHere }
        if app.agents.replyHere != ownReplyHere { app.agents.replyHere = ownReplyHere }
        app.cancelMotion()
        app.sleep.held = false
        app.busy = false
        app.bubbleArea = nil
        app.frogg.squash = CGSize(width: 1, height: 1)
        app.userPlaced = false
        app.reposition(force: true)
        app.backToIdle()
        Debug.log("showcase: reset")
    }

    /// Plays a scene start to finish on its own timer.
    func run(_ id: String) {
        select(id)
        let task = running
        running = Task { [weak self] in
            await task?.value
            guard let self, let s = self.scene else { return }
            for (i, b) in s.beats.enumerated() {
                if Task.isCancelled { return }
                self.beatIndex = i + 1
                Debug.log("showcase: \(s.id) · \(b.name)")
                await b.run(self)
                try? await Task.sleep(for: .seconds(b.hold))
            }
            Debug.log("showcase: \(s.id) done")
            self.running = nil
        }
    }

    private func prepare() async {
        rng = SeededRandom(seed: Self.seed)
        ShowcaseScenes.cleanup()
        clearStage()
        guard let s = scene else { return }
        Debug.log("showcase: scene \(s.id) · \(s.title)")
        await s.setup(self)
    }

    private func cancel() {
        running?.cancel()
        running = nil
    }

    // MARK: the clean desk (nothing private is ever in a take)

    /// A plain dark desk over every other window, the Dock and the desktop icons, behind the
    /// Pixls: what a take shows is only what the scene puts there.
    private(set) var desk: NSPanel?

    /// Covers everything (the Pixl scenes).
    func cleanDesk() {
        let d = deskPanel()
        d.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        d.orderFrontRegardless()
        app.froggPanel.orderFrontRegardless()
    }

    /// Covers everything except one app's front window (its window sits on the desk): the
    /// browser, the doc, the Terminal of a scene. The Dock should be hidden for these takes.
    func cleanDesk(keeping bundleID: String) {
        let d = deskPanel()
        d.level = .normal
        let me = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
        let target = infos.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        if let n = target?[kCGWindowNumber as String] as? Int, pid != me {
            d.order(.below, relativeTo: n)
        } else {
            Debug.log("showcase: no \(bundleID) window to keep; covering everything")
            cleanDesk()
        }
    }

    func clearDesk() { desk?.orderOut(nil) }

    private func deskPanel() -> NSPanel {
        if let d = desk { return d }
        let frame = NSScreen.screens.first?.frame ?? .zero
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = true
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = DeskView(frame: NSRect(origin: .zero, size: frame.size))
        p.setFrame(frame, display: true)
        desk = p
        return p
    }

    // MARK: helpers for scenes

    /// The click-through stage over the Pixl's screen (fly, tongue, coins, titles, backdrop…).
    func stageOverlay() -> GameOverlay {
        if let s = stage { return s }
        let screen = app.screensTopLeft.first { $0.contains(app.foot ?? .zero) } ?? app.screensTopLeft.first ?? .zero
        let full = NSScreen.screens.first.map { app.topLeft($0.frame) } ?? screen
        let o = GameOverlay(screenTopLeft: full, app: app)
        o.panel.level = .statusBar
        o.panel.order(.below, relativeTo: app.froggPanel.windowNumber)
        stage = o
        ticker = DisplayTicker(view: o.view) { [weak self, weak o] in
            guard let self, let o else { return }
            o.petBox = self.app.topLeft(self.app.froggBox)
            o.redraw(now: self.app.now)
        }
        return o
    }

    func clearStage() {
        ticker?.stop(); ticker = nil
        stage?.close(); stage = nil
    }

    /// Waits for something live. After 0.3 s a spinner shows by the Pixl until it lands.
    func live<T>(_ label: String, _ work: @escaping @MainActor () async -> T) async -> T {
        let started = app.now
        let spin = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let box = self.app.topLeft(self.app.froggBox)
            self.stageOverlay().spinner = CGPoint(x: box.maxX + 14, y: box.minY - 6)
        }
        let result = await work()
        spin.cancel()
        stage?.spinner = nil
        Debug.log("showcase: \(label) landed in \(String(format: "%.1f", app.now - started)) s")
        return result
    }

    func wait(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// The Pixl's mouth, head top and middle (top-left global), for effects that start on it.
    var head: CGPoint { let b = app.topLeft(app.froggBox); return CGPoint(x: b.midX, y: b.minY) }
    var mouth: CGPoint {
        let b = app.topLeft(app.froggBox)
        return CGPoint(x: b.midX + (app.frogg.mirrored ? -1 : 1) * b.width * 0.04, y: b.maxY - b.height * (1 - 17 / 54))
    }
    var middle: CGPoint { let b = app.topLeft(app.froggBox); return CGPoint(x: b.midX, y: b.midY) }
}

/// The clean desk: a quiet dark gradient, like a plain dark wallpaper.
final class DeskView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: NSColor(srgbRed: 0.075, green: 0.082, blue: 0.105, alpha: 1),
                   ending: NSColor(srgbRed: 0.035, green: 0.039, blue: 0.051, alpha: 1))?.draw(in: bounds, angle: -90)
    }
}
