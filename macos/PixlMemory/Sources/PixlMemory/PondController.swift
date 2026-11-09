import AppKit
import PixlMemoryKit

/// Frogg's pond (C14) on the desktop: forms beside him, he slides in and sinks to his eyes, sleeps
/// in a 4-step breathing loop, and on waking snaps his eyes open, launches, splashes down and steps
/// out onto the bank as it fades. Composited from the pond's layers with his live pose (Kit PondView).
/// The pond is placed so he starts and ends on the bank exactly where he was standing.
@MainActor
final class PondController {
    unowned let app: AppController
    var panel: NSPanel?
    var view: PondView?
    var timer: Timer?
    var origin = CGPoint.zero          // the pond's top-left, global top-left coordinates
    var looping = false
    var onLeft: (() -> Void)?
    var active: Bool { panel != nil }

    init(app: AppController) { self.app = app }

    var available: Bool { PixlSkins.currentID == "frogg" && PondArt.shared != nil }

    /// Into the pond and asleep: forms, slide in, sink, lids droop, then the breathing loop.
    func enter() {
        guard available, !active, let pond = PondArt.shared, let foot = app.foot, let start = pond.feet(0) else { return }
        let s = app.scale
        origin = CGPoint(x: (foot.x - start.x * s).rounded(), y: (foot.y - start.y * s).rounded())
        let v = PondView(pond: pond, scale: s)
        v.onClick = { [weak self] count, right in
            guard let app = self?.app else { return }
            if right || count >= 2 { app.sleep.handle(.menuClick); app.menu.open(trigger: right ? "right-click" : "double-click") }
            else if !app.sleep.handle(.poke) { self?.leave { app.backToIdle() } }   // awake (a Roam dip): out he hops
        }
        let p = NSPanel(contentRect: v.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = v
        p.setFrameOrigin(NSPoint(x: origin.x, y: app.primaryHeight - origin.y - v.frame.height))
        p.orderFrontRegardless()
        panel = p; view = v
        app.froggPanel.alphaValue = 0     // the pond draws him now
        Debug.log("pond: forms and Frogg slides in")
        looping = true
        play(0)
    }

    /// Wake: eyes snap, launch, splashdown, step out; then Frogg is himself again on the bank.
    func leave(then done: (() -> Void)? = nil) {
        guard active else { done?(); return }
        looping = false
        onLeft = done
        Debug.log("pond: wakes, launches and steps out")
        play(8)
    }

    /// Gone at once (he was grabbed): Frogg reappears where he was.
    func cancel() {
        guard active else { return }
        timer?.invalidate()
        finish(at: nil)
    }

    /// A short dip (Roam): in, a few breaths, out.
    func dip(_ seconds: TimeInterval, then done: @escaping () -> Void) {
        enter()
        guard active else { done(); return }
        app.later(max(2.5, seconds)) { [weak self] in self?.leave(then: done) }
    }

    func play(_ i: Int) {
        guard let pond = PondArt.shared, let view else { return }
        timer?.invalidate()
        if i >= pond.frames.count { finish(at: pond.feet(pond.frames.count - 1)); return }
        view.index = i
        let next: Int
        if looping, i == pond.loop.upperBound { next = pond.loop.lowerBound }   // the breathing loop
        else if looping, i == pond.loop.lowerBound - 1 { next = pond.loop.lowerBound }
        else if !looping, i < 8 { next = 8 }                                     // asked to leave mid-loop
        else { next = i + 1 }
        timer = Timer.scheduledTimer(withTimeInterval: Double(pond.frames[i].ms) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.play(next) }
        }
    }

    func finish(at feet: CGPoint?) {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
        panel = nil; view = nil
        if let feet { app.place(at: CGPoint(x: origin.x + feet.x * app.scale, y: origin.y + feet.y * app.scale)) }
        app.froggPanel.alphaValue = 1
        let done = onLeft
        onLeft = nil
        done?()
    }
}
