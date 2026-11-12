import AppKit
import CoreGraphics

/// Showcase mode only: moves and clicks the pointer the way a person would (eased, human speed),
/// so a recorded take shows real clicks on real UI. Posted with CGEvent (needs Accessibility,
/// which the app already has). Never used outside Showcase mode.
@MainActor
enum ScriptedCursor {
    /// Where the pointer is, top-left global points (CGEvent's coordinate space).
    static var position: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }   // in-out cubic

    /// Glides to `p` over about `duration` seconds (longer moves take a little longer), with a
    /// slight arc, like a hand.
    static func move(to p: CGPoint, duration: TimeInterval? = nil, dragging: Bool = false) async {
        let a = position
        let d = hypot(p.x - a.x, p.y - a.y)
        let t = duration ?? min(1.1, max(0.35, Double(d) / 1400))
        let steps = max(2, Int(t * 120))
        let bow = min(40, d * 0.08)   // a small sideways arc
        let nx = d > 0 ? -(p.y - a.y) / d : 0, ny = d > 0 ? (p.x - a.x) / d : 0
        for i in 1...steps {
            let e = CGFloat(ease(Double(i) / Double(steps)))
            let arc = CGFloat(sin(Double(e) * .pi)) * bow
            let q = CGPoint(x: a.x + (p.x - a.x) * e + nx * arc, y: a.y + (p.y - a.y) * e + ny * arc)
            post(dragging ? .leftMouseDragged : .mouseMoved, at: q)
            try? await Task.sleep(for: .seconds(t / Double(steps)))
        }
    }

    static func click(at p: CGPoint, count: Int = 1) async {
        await move(to: p)
        try? await Task.sleep(for: .milliseconds(90))
        for n in 1...count {
            post(.leftMouseDown, at: p, clicks: n)
            try? await Task.sleep(for: .milliseconds(70))
            post(.leftMouseUp, at: p, clicks: n)
            try? await Task.sleep(for: .milliseconds(90))
        }
    }

    /// Press, drag to `b` at hand speed, release (selecting text, dragging a card).
    static func drag(from a: CGPoint, to b: CGPoint, duration: TimeInterval = 0.8) async {
        await move(to: a)
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseDown, at: a)
        try? await Task.sleep(for: .milliseconds(120))
        await move(to: b, duration: duration, dragging: true)
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseUp, at: b)
    }

    private static func post(_ type: CGEventType, at p: CGPoint, clicks: Int = 1) {
        let button: CGMouseButton = .left
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if type == .leftMouseDown || type == .leftMouseUp { e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        e.post(tap: .cghidEventTap)
    }
}
