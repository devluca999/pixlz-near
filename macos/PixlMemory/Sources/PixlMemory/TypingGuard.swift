import AppKit
import PixlMemoryKit
import PixlzCore

/// Keeps the Pixl off where you're about to type. When you click into a text field, or the caret
/// moves while you type, and the Pixl sits on that field (or on the line you're writing), it moves
/// along its perch to the nearest clear spot. Reads only the focused element's role, its frame and
/// the caret's position through Accessibility: never your text.
@MainActor
final class TypingGuard {
    unowned let app: AppController
    var clickMonitor: Any?
    var timer: Timer?
    var lastMove: TimeInterval = 0

    init(app: AppController) { self.app = app }

    func start() {
        // clicking into a field: that's where the typing will be
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.app.later(0.2) { self?.check(reason: "click") } }
        }
        // while you type, the caret moves on: checked twice a second, only when typing
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.app.presence.typing else { return }
                self.check(reason: "typing")
            }
        }
        timer?.tolerance = 0.2
    }

    /// Text roles: where typing goes.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// The area to keep clear (top-left global), or nil when nothing editable has focus.
    func typingZone() -> CGRect? {
        guard AX.trusted, let front = NSWorkspace.shared.frontmostApplication, front != .current else { return nil }
        let pid = front.processIdentifier
        guard let focused: AXUIElement = AX.attr(AX.app(pid), kAXFocusedUIElementAttribute) else { return nil }
        let role: String = AX.attr(focused, kAXRoleAttribute) ?? ""
        let editable = Self.textRoles.contains(role) || (AX.attr(focused, kAXSelectedTextRangeAttribute) as AXValue?) != nil
        guard editable else { return nil }
        let caret = AX.selectionBounds(pid: pid).last
        let field = AX.frame(focused)
        return TypingZone.zone(field: field, caret: caret)
    }

    func check(reason: String) {
        guard !app.userHidden, !app.fullscreenHidden, !app.game.isOn, !app.menu.isOpen, app.menu.cardPanel == nil,
              app.mode == .perched, !app.moving, !app.busy, !app.resizer.adjusting, app.roamHanging == nil,
              app.now - lastMove > 1.5, let foot = app.foot, let zone = typingZone() else { return }
        let pet = app.topLeft(app.petRect)
        guard pet.intersects(zone) else { return }
        guard let dest = clearSpot(from: foot, zone: zone) else { Debug.log("typing guard: no clear spot"); return }
        Debug.log("typing guard: moving off the \(reason == "click" ? "field you clicked" : "line you're typing") (\(Int(abs(dest.x - foot.x))) pt)")
        lastMove = app.now
        app.userPlaced = true   // stays there until you switch windows
        app.run(app.move(from: foot, to: dest), target: dest)
    }

    /// Along the same perch (the window's top edge, or the screen's floor), the nearest spot whose
    /// box clears the zone; failing that, the floor of the screen.
    func clearSpot(from foot: CGPoint, zone: CGRect) -> CGPoint? {
        let s = app.spriteSize
        let screen = app.screensTopLeft.first { $0.insetBy(dx: -4, dy: -s.height).contains(foot) } ?? app.screensTopLeft.first ?? .zero
        var span = screen.minX + s.width / 2 ... screen.maxX - s.width / 2
        if let w = app.watcher.activeWindowFrame, abs(w.minY - foot.y) < 6 {   // on the window's top edge
            span = max(w.minX + s.width / 2, span.lowerBound) ... min(w.maxX - s.width / 2, span.upperBound)
        }
        if let x = TypingZone.nearestClearX(from: foot.x, span: span, footY: foot.y, sprite: s, zone: zone) {
            return CGPoint(x: x, y: foot.y)
        }
        let floorY = screen.maxY
        return TypingZone.nearestClearX(from: foot.x, span: screen.minX + s.width / 2 ... screen.maxX - s.width / 2, footY: floorY, sprite: s, zone: zone)
            .map { CGPoint(x: $0, y: floorY) }
    }
}
