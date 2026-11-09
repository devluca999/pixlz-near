import AppKit
import PixlMemoryKit
import PixlzCore

/// Feeds PixlzCore's `SleepCycle` (when to sleep, how to wake) and plays what it decides.
/// Inputs: time since your last key or mouse event (never which keys), the cursor near or on
/// the Pixl, clicks, grabs, window switches, ⌃⌥Space and Focus ending. The energy need (PixlzCore
/// Needs) runs down while awake and recovers while asleep, which paces the activity naps.
@MainActor
final class SleepController {
    unowned let app: AppController
    var cycle: SleepCycle
    var needs = Needs.fresh(at: Date())
    var activity: NeedActivity = .idle
    var timer: Timer?
    var hovering = false
    var lastStir: TimeInterval = 0
    var lastCursor: CGPoint?
    var lastZ: TimeInterval = 0
    /// PIXL_DEBUG: pretend you've been away this much longer than you have.
    var debugAway: TimeInterval = 0
    var debugAwaySetAt: TimeInterval = 0
    /// Debug builds only (e2e "awake"): treat you as present until then, to watch outings while away.
    var debugAwakeUntil: TimeInterval = 0

    var stage: SleepCycle.Stage { cycle.stage }
    var dozing: Bool { cycle.stage.dozing }

    init(app: AppController) {
        self.app = app
        cycle = SleepCycle(at: app.now, sleepiness: SleepCycle.Sleepiness(rawValue: app.settings.sleepiness ?? "normal") ?? .normal,
                           hoverWakes: app.settings.hoverWakes ?? false, seed: UInt64(Date().timeIntervalSince1970))
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.05
    }

    func settingsChanged() {
        cycle.sleepiness = SleepCycle.Sleepiness(rawValue: app.settings.sleepiness ?? "normal") ?? .normal
        cycle.hoverWakes = app.settings.hoverWakes ?? false
    }

    // MARK: the clock

    func tick() {
        guard !app.userHidden, app.awayOn == nil, app.foot != nil else { return }
        let t = app.now
        let anyInput = CGEventType(rawValue: UInt32.max)!   // kCGAnyInputEventType
        let realAway = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        // you touched something after the debug key (not the key press itself): back to real time
        if debugAway > 0, realAway < max(0, t - debugAwaySetAt - 0.8) { debugAway = 0 }
        let sinceInput = t < debugAwakeUntil ? 0 : realAway + debugAway
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        // the energy need: resting while asleep, spent faster while moving
        let now = Date()
        let a: NeedActivity = cycle.stage.sleeping ? .resting : app.moving ? .moving : .idle
        if a != activity { activity = a; needs.apply(NeedConditions(activity: a), at: now) }
        let energy = needs.energy.value(at: now)
        // the debug key press itself isn't typing
        let typing = sinceKey < Presence.typingWindow && (debugAway == 0 || sinceKey < t - debugAwaySetAt - 0.8)
        apply(cycle.tick(at: t, sinceInput: sinceInput, typing: typing, energy: energy))
        if cycle.stage.sleeping { watchCursor(t) }
        watchHover(t)
        // z's (Frogg's pond makes its own bubble-z)
        if cycle.stage.sleeping, !app.pond.active, t - lastZ > (cycle.stage == .deep ? 3.6 : 2.2) { lastZ = t; app.puffZ() }
    }

    var hoverSince: TimeInterval?
    var lastStatus = ""

    /// Rest the mouse on the Pixl for ~1 s: its status, as a tooltip. Also keeps the menu bar's
    /// tooltip current.
    func watchHover(_ t: TimeInterval) {
        guard let foot = app.foot else { return }
        let s = app.spriteSize
        let body = CGRect(x: foot.x - s.width / 2, y: foot.y - s.height, width: s.width, height: s.height)
        if body.insetBy(dx: s.width * 0.12, dy: s.height * 0.12).contains(app.mouseTopLeft) {
            if hoverSince == nil { hoverSince = t }
            if t - (hoverSince ?? t) >= 1 { app.showStatusTip(true) }
        } else {
            hoverSince = nil
            app.showStatusTip(false)
        }
        let line = app.statusLine
        if line != lastStatus { lastStatus = line; app.statusItem?.button?.toolTip = line }
    }

    /// Asleep: a cursor passing close stirs it; resting on it for 2 s opens an eye.
    func watchCursor(_ t: TimeInterval) {
        guard let foot = app.foot else { return }
        let m = app.mouseTopLeft
        let s = app.spriteSize
        let body = CGRect(x: foot.x - s.width / 2, y: foot.y - s.height, width: s.width, height: s.height)
        let on = body.insetBy(dx: s.width * 0.15, dy: s.height * 0.15).contains(m)
        if on != hovering {
            hovering = on
            apply(cycle.handle(on ? .hoverStart : .hoverEnd, at: t))
        }
        if !on, let last = lastCursor, hypot(m.x - last.x, m.y - last.y) > 25, body.insetBy(dx: -120, dy: -120).contains(m),
           t - lastStir > 6 {
            lastStir = t
            apply(cycle.handle(.cursorNear, at: t))
        }
        lastCursor = m
    }

    // MARK: what you did

    /// Returns true when the Pixl was dozing, so the caller skips its usual reaction.
    @discardableResult
    func handle(_ input: SleepCycle.Input) -> Bool {
        let was = cycle.stage.dozing
        if [.poke, .menuClick, .hotkey, .focusEnded].contains(input) { debugAway = 0 }   // you're here
        apply(cycle.handle(input, at: app.now))
        return was
    }

    // MARK: playing it

    func apply(_ outs: [SleepCycle.Output]) {
        for o in outs {
            switch o {
            case .stage(let from, let to, let why):
                Debug.log("sleep: \(from.rawValue) → \(to.rawValue) (\(why))")
                enter(to, from: from)
            case .react(let r):
                Debug.log("sleep: \(r.rawValue)")
                react(r)
            }
        }
    }

    func enter(_ s: SleepCycle.Stage, from: SleepCycle.Stage) {
        switch s {
        case .drowsy:
            app.cancelMotion()
            app.cancelAnimations()
            app.frogg.frameName = "emotion_sleepy"     // heavy eyes
        case .asleep, .deep:
            app.startSleep(deep: s == .deep)
        case .awake:
            if from.dozing || from == .waking {
                app.stopSleep()
                app.backToIdle()
                // catch up with the window you're on
                app.later(0.3) { [weak self] in self?.app.userPlaced = false; self?.app.reposition(force: true) }
            }
        case .resting, .waking:
            break
        }
    }

    func react(_ r: SleepCycle.Reaction) {
        let f = app.frogg!
        switch r {
        case .stir:
            let keep = f.frameName
            f.frameName = app.sleepFrame(deep: false) == "mischief_2" ? keep : "rest_0"
            app.later(0.35) { [weak self] in if self?.dozing == true { f.frameName = keep } }
        case .eyeOpen:
            if app.sleepFrame(deep: false) != "mischief_2" { f.frameName = "rest_0" }
        case .eyeClose:
            if cycle.stage.sleeping { f.frameName = app.sleepFrame(deep: cycle.stage == .deep) }
        case .earTwitch:
            let s0 = f.squash
            f.squash = CGSize(width: 0.94, height: 1.03)
            app.later(0.12) { f.squash = s0 }
            app.later(0.26) { f.squash = CGSize(width: 0.96, height: 1.02) }
            app.later(0.36) { f.squash = s0 }
        case .startled:
            app.stopSleep()
            f.frameName = "emotion_startled"
        case .grumpy:
            f.frameName = "emotion_annoyed"
            app.speak(.annoyed)
        case .stretchYawn:
            app.stopSleep()
            app.later(0.9) { [weak self] in self?.app.speak(.sleepy) }
            f.frameName = "rest_0"                      // the yawn
            app.later(0.8) { if f.frameName == "rest_0" { f.frameName = "idle_2" } }   // the stretch
        case .wakeAndMenu, .wake:
            app.stopSleep()
            f.frameName = "idle_0"
        }
    }

    // MARK: debug (PIXL_DEBUG=1, ⌃⌥⇧ hotkeys)

    func debugSleepNow() {
        debugAway = cycle.sleepiness.awayThreshold + 1
        debugAwaySetAt = app.now
        Debug.log("sleep debug: pretending you've been away \(Int(debugAway)) s")
        tick()
        cycle.debugFastForward(by: SleepCycle.drowsyTime)
        tick()
    }

    func debugFastForward(_ seconds: TimeInterval) {
        Debug.log("sleep debug: fast-forward \(Int(seconds)) s")
        cycle.debugFastForward(by: seconds)
        tick()
    }

    func debugStayAwake(_ seconds: TimeInterval) {
        debugAwakeUntil = app.now + seconds
        debugAway = 0
        Debug.log("sleep debug: treating you as present for \(Int(seconds)) s")
        if dozing { handle(.hotkey) }
        tick()
    }

    func debugNap() {
        apply(cycle.debugNap(at: app.now))
    }
}
