import AppKit
import Testing
@testable import PixlMemoryKit

/// UI-level click tests: real NSEvents dispatched through an NSWindow, so AppKit's own
/// routing (hit testing, which view gets mouseUp) is what's under test, not a direct call
/// to our handlers.
@MainActor
enum Click {
    /// A borderless offscreen window hosting `view` at its origin.
    static func host(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        // On screen but invisible (alpha 0): AppKit drops mouse events for windows that aren't ordered in.
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: view.frame.size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        w.orderFrontRegardless()
        return w
    }

    static func event(_ type: NSEvent.EventType, at p: NSPoint, in w: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                           pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Clicks at a point in `view`'s own coordinates (flipped views included).
    static func click(_ view: NSView, at p: NSPoint, clicks: Int = 1) {
        guard let w = view.window else { return }
        let inWindow = view.convert(p, to: nil)
        w.sendEvent(event(.leftMouseDown, at: inWindow, in: w, clicks: clicks))
        w.sendEvent(event(.leftMouseUp, at: inWindow, in: w, clicks: clicks))
    }
}

@MainActor
struct ClickTests {
    func radial(_ enabled: Bool = true) -> RadialMenuView {
        RadialMenuView(items: [
            .init(id: "polish", title: "Polish", glyph: "✎", enabled: enabled), .init(id: "focus", title: "Focus", glyph: "◷"),
            .init(id: "chat", title: "Chat", glyph: "💬", enabled: false), .init(id: "mic", title: "Mic", glyph: "🎙", enabled: false),
            .init(id: "hide", title: "Hide", glyph: "◌"), .init(id: "settings", title: "Settings", glyph: "⚙")])
    }

    @Test func radialButtonsFireOnClick() {
        let view = radial()
        let w = Click.host(view)
        defer { w.close() }
        var picked: [String] = []
        view.onSelect = { picked.append($0.id) }
        let centers = RadialMenuView.centers(count: 6, in: view.bounds.size)
        Click.click(view, at: centers[1])
        Click.click(view, at: centers[5])
        #expect(picked == ["focus", "settings"])
    }

    @Test func radialReportsDisabledItemsToo() {
        // Disabled items still fire, so Frogg can say "coming soon" instead of ignoring the click.
        let view = radial()
        let w = Click.host(view)
        defer { w.close() }
        var picked: [RadialMenuView.Item] = []
        view.onSelect = { picked.append($0) }
        Click.click(view, at: RadialMenuView.centers(count: 6, in: view.bounds.size)[2])
        #expect(picked.map(\.id) == ["chat"] && picked.first?.enabled == false)
    }

    @Test func radialIgnoresClicksBetweenButtonsAndPressThenSlideOff() {
        let view = radial()
        let w = Click.host(view)
        defer { w.close() }
        var picked = 0
        view.onSelect = { _ in picked += 1 }
        Click.click(view, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))  // Frogg's spot: click-through
        let c = RadialMenuView.centers(count: 6, in: view.bounds.size)
        w.sendEvent(Click.event(.leftMouseDown, at: view.convert(c[0], to: nil), in: w))
        w.sendEvent(Click.event(.leftMouseUp, at: view.convert(c[3], to: nil), in: w))  // released on another button
        #expect(picked == 0)
    }

    @Test func choiceButtonsFire() throws {
        var picked: [Int] = []
        let view = ChoiceMenuView(title: "Focus", options: ["25 min", "50 min"], style: .round) { picked.append($0) }
        let w = Click.host(view)
        defer { w.close() }
        for i in [1, 0] { Click.click(view, at: try #require(view.center(of: i))) }
        #expect(picked == [1, 0])

        var chosen: [Int] = []
        let list = ChoiceMenuView(title: "“hey team…”", options: ["Polish this", "Make it shorter"], style: .list) { chosen.append($0) }
        let w2 = Click.host(list)
        defer { w2.close() }
        Click.click(list, at: try #require(list.center(of: 1)))
        #expect(chosen == [1])
    }

    @Test func pixelButtonsInThePanelsFire() throws {
        let r = try MemoryClient.decodePolish(data: ClientTests().fixture(), status: 200)
        let panel = PolishView(.result(r, instruction: "Polish this", app: "Mail"))
        panel.fit()
        let w = Click.host(panel)
        defer { w.close() }
        var closed = 0, copied: [String] = []
        panel.onClose = { closed += 1 }
        panel.onCopy = { copied.append($0) }
        let buttons = panel.descendants(of: PixelButton.self)
        let done = try #require(buttons.first { $0.title == "Done" })
        let copy = try #require(buttons.first { $0.title == "Copy" })
        Click.click(done, at: NSPoint(x: done.bounds.midX, y: done.bounds.midY))
        Click.click(copy, at: NSPoint(x: copy.bounds.midX, y: copy.bounds.midY))
        #expect(closed == 1 && copied == [r.suggestion])

        let mini = MiniMenuView(settings: PixlSettings(), status: ServiceStatus(service: "running"))
        mini.fit()
        let w2 = Click.host(mini)
        defer { w2.close() }
        var wallet = 0
        mini.onOpenWallet = { wallet += 1 }
        let setup = try #require(mini.descendants(of: PixelButton.self).first { $0.title.contains("wallet") })
        Click.click(setup, at: NSPoint(x: setup.bounds.midX, y: setup.bounds.midY))
        #expect(wallet == 1)
    }

    @Test func froggGetsDownUpAndDoubleClicksOnlyOnItsPixels() {
        let frogg = FroggView(scale: 2, frameName: "idle_0")
        let w = Click.host(frogg)
        defer { w.close() }
        var seen: [String] = []
        frogg.onMouse = { kind, e in seen.append("\(kind):\(e.clickCount)") }
        Click.click(frogg, at: NSPoint(x: frogg.bounds.midX, y: 40))          // belly
        Click.click(frogg, at: NSPoint(x: frogg.bounds.midX, y: 40), clicks: 2)
        Click.click(frogg, at: NSPoint(x: 1, y: frogg.bounds.maxY - 1))         // transparent corner
        #expect(seen == ["down:1", "up:1", "down:2", "up:2"])
    }
}

extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.descendants(of: type) }
    }
}
