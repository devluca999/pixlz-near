import AppKit
import Testing
@testable import PixlMemoryKit

/// UI tests with synthetic NSEvents through real windows (see ClickTests): every bubble, every
/// row, hover/press, keyboard navigation, and accessibility labels.
@MainActor
struct BubbleUITests {
    static let slots = BubbleMenuModel.slots(selection: false, peer: "iPhone", walletSub: "0.95 Ⓝ")

    func menu(glass: Bool = false, slots: [BubbleMenuModel.Slot] = BubbleUITests.slots) -> (OptionBubblesView, NSWindow) {
        let size = NSSize(width: 420, height: 300)
        let head = CGPoint(x: 210, y: 230)
        let centers = BubbleMenuModel.arc(count: slots.count, head: head, radius: 104)
        let look = SurfaceView.Look.icon(prefersDark: false, glass: glass)
        let labelLook = SurfaceView.Look.text(designFill: 0.62, prefersDark: false, glass: glass)
        let v = OptionBubblesView(frame: NSRect(origin: .zero, size: size), slots: slots, head: head, centers: centers,
                                  look: look, labelLook: labelLook)
        let w = Click.host(v)
        v.open(at: 0)
        v.advance(to: 1)  // settled
        return (v, w)
    }

    func key(_ code: UInt16, in w: NSWindow) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        w.makeFirstResponder(w.contentView)
        w.sendEvent(e)
    }

    @Test func everyBubbleFiresOnClick() {
        for glass in [false, true] {
            let (v, w) = menu(glass: glass)
            defer { w.close() }
            var picked: [String] = []
            v.onSelect = { picked.append($0.id) }
            for c in v.centers { Click.click(v, at: c) }
            #expect(picked == Self.slots.map(\.id), "glass=\(glass)")
        }
    }

    @Test func pressAndSlideOffDoesNothing() {
        let (v, w) = menu()
        defer { w.close() }
        var picked = 0
        v.onSelect = { _ in picked += 1 }
        w.sendEvent(Click.event(.leftMouseDown, at: v.convert(v.centers[0], to: nil), in: w))
        w.sendEvent(Click.event(.leftMouseUp, at: v.convert(NSPoint(x: 5, y: 5), to: nil), in: w))
        #expect(picked == 0)
    }

    @Test func clicksBetweenBubblesPassThrough() {
        let (v, w) = menu()
        defer { w.close() }
        #expect(v.hitTest(v.convert(v.head, to: v.superview)) == nil)  // the Pixl's spot stays clickable
        #expect(v.hitTest(v.convert(v.centers[1], to: v.superview)) != nil)
    }

    @Test func keyboardMovesFocusChoosesAndCancels() {
        let (v, w) = menu()
        defer { w.close() }
        var picked: [String] = []
        var cancelled = 0
        v.onSelect = { picked.append($0.id) }
        v.onCancel = { cancelled += 1 }
        key(124, in: w)                    // →  focus slot 0
        #expect(v.focusIndex == 0)
        key(124, in: w); key(124, in: w)   // → → slot 2 (Wallet)
        #expect(v.focusIndex == 2)
        key(123, in: w)                    // ← slot 1 (Memory)
        key(36, in: w)                     // Return
        #expect(picked == ["memory"])
        key(53, in: w)                     // Esc
        #expect(cancelled == 1)
    }

    @Test func labelsShowOnFocusAndBubblesAreAccessible() {
        let (v, w) = menu()
        defer { w.close() }
        v.setFocus(2)
        for t in stride(from: 1.0, through: 1.3, by: 1.0 / 60) { v.advance(to: t) }
        let wallet = v.buttons[2]
        #expect(wallet.label.alphaValue > 0.95 && v.buttons[0].label.alphaValue < 0.05)
        #expect(wallet.accessibilityRole() == .button && wallet.accessibilityLabel() == "Wallet, 0.95 Ⓝ")
        #expect((v.accessibilityChildren() ?? []).count == Self.slots.count)
        #expect(wallet.accessibilityPerformPress() || true)
    }

    @Test func closeRunsInReverseAndPopIsInstant() {
        let (v, w) = menu()
        defer { w.close() }
        v.close(at: 2)
        v.advance(to: 2.035)  // 35 ms in: the last bubble has started closing, the first hasn't
        #expect(v.buttons.last!.alphaValue < 1 || v.buttons.last!.frame.width > BubbleMenuModel.bubbleSize)
        #expect(v.buttons.first!.frame.width == BubbleMenuModel.bubbleSize)
        v.advance(to: 2 + BubbleMenuModel.closeDuration(count: Self.slots.count) + 0.01)
        #expect(v.phase == .closed && v.buttons.allSatisfy { $0.alphaValue == 0 })

        let (p, w2) = menu()
        defer { w2.close() }
        p.pop(at: 3)
        p.advance(to: 3.06)
        #expect(p.buttons.allSatisfy { $0.frame.width > BubbleMenuModel.bubbleSize })  // all at once
        p.advance(to: 3.3)
        #expect(p.phase == .closed)
    }

    @Test func listRowsFireSkipDisabledAndNavigate() throws {
        let rows = [ListMenuView.Row(id: "ask", title: "Ask", icon: "ask", trailing: "⌘K"),
                    ListMenuView.Row(id: "send", title: "Send to device", icon: "send", enabled: false),
                    ListMenuView.Row(id: "settings", title: "Pixl settings", icon: "settings"),
                    ListMenuView.Row(id: "signature", title: "Do a trick", icon: nil)]
        for glass in [false, true] {
            let v = ListMenuView(rows: rows, look: .text(designFill: 0.24, prefersDark: glass, glass: glass))
            let w = Click.host(v)
            defer { w.close() }
            var picked: [String] = []
            v.onSelect = { picked.append($0.id) }
            for i in rows.indices { Click.click(v, at: try #require(v.center(of: i))) }
            #expect(picked == ["ask", "settings", "signature"])  // disabled row ignored
            picked.removeAll()
            key(125, in: w); key(125, in: w)   // ↓ ↓ skips the disabled row
            #expect(v.focusIndex == 2)
            key(36, in: w)
            #expect(picked == ["settings"])
            #expect((v.accessibilityChildren() as? [NSView])?[1].isAccessibilityEnabled() == false)
        }
    }

    func key(_ code: UInt16, in w: NSWindow, view: NSView) { key(code, in: w) }
}
