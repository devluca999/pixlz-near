import AppKit
import CoreGraphics
import PixlMemoryKit

/// Feeds `Presence` (PixlMemoryKit) from the system: seconds since the last key / any input
/// (timing only: never which keys) and the cursor position, ~4 times a second while the Pixl
/// is out. Acts on what it says: still while you type, a nap when you're away, a yawn when
/// you're back, a look toward a nearby cursor, a startle at a fast swipe.
@MainActor
final class PresenceController {
    unowned let app: AppController
    var presence = Presence()
    var timer: Timer?
    var typing: Bool { presence.mood == .typing }

    init(app: AppController) { self.app = app }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer?.tolerance = 0.1
    }

    func step() {
        guard app.froggPanel.isVisible, !app.userHidden, app.awayOn == nil else { return }
        let t = app.now
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let anyInput = CGEventType(rawValue: UInt32.max)!   // kCGAnyInputEventType
        let sinceAny = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        let before = presence.mood
        let mood = presence.activity(sinceKey: sinceKey, sinceAny: sinceAny, at: t)
        let calm = app.mode == .perched && !app.moving && !app.busy && !app.menu.isOpen && !app.game.isOn
        if mood != before {
            Debug.log("presence: \(before) → \(mood)")
            switch mood {
            case .napping, .waking:
                break   // sleeping and waking belong to SleepController (PixlzCore SleepCycle)
            default: break
            }
        }
        guard calm, !app.sleep.dozing, app.frogg.frameName == "idle_0", let foot = app.foot else { return }
        let head = CGPoint(x: foot.x, y: foot.y - app.spriteSize.height * 0.7)
        switch presence.cursor(app.topLeft(NSEvent.mouseLocation), head: head, at: t) {
        case .look(let left):
            app.frogg.mirrored = left
        case .startle:
            Debug.log("presence: startled by a fast cursor")
            app.show("emotion_startled", for: 0.45)
        case .none: break
        }
    }
}
