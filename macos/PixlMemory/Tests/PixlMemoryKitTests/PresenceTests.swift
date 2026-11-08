import CoreGraphics
import Foundation
import Testing
@testable import PixlMemoryKit

struct PresenceTests {
    @Test func typingKeepsItStillThenItNapsAndWakesWithAYawn() {
        var p = Presence()
        #expect(p.activity(sinceKey: 0.3, sinceAny: 0.3, at: 0) == .typing)
        #expect(p.activity(sinceKey: 5, sinceAny: 2, at: 5) == .awake)
        #expect(p.activity(sinceKey: 70, sinceAny: 61, at: 70) == .napping)
        #expect(p.activity(sinceKey: 80, sinceAny: 71, at: 80) == .napping)      // stays asleep while you're away
        #expect(p.activity(sinceKey: 90, sinceAny: 0.2, at: 90) == .waking)      // you're back: yawn
        #expect(p.activity(sinceKey: 90.5, sinceAny: 0.5, at: 90.5) == .waking)
        #expect(p.activity(sinceKey: 91, sinceAny: 0.1, at: 91) == .awake)
    }

    @Test func itLooksTowardANearbyCursorOnlyWhenTheSideChanges() {
        var p = Presence()
        let head = CGPoint(x: 500, y: 500)
        #expect(p.cursor(CGPoint(x: 900, y: 500), head: head, at: 0) == .none)        // far away
        #expect(p.cursor(CGPoint(x: 400, y: 520), head: head, at: 1) == .look(left: true))
        #expect(p.cursor(CGPoint(x: 410, y: 520), head: head, at: 2) == .none)        // same side: nothing new
        #expect(p.cursor(CGPoint(x: 600, y: 480), head: head, at: 3) == .look(left: false))
        #expect(p.cursor(CGPoint(x: 505, y: 480), head: head, at: 4) == .none)        // right above it: no flip-flopping
    }

    @Test func aFastCloseSwipeStartlesItButNotTwiceInARow() {
        var p = Presence()
        let head = CGPoint(x: 500, y: 500)
        _ = p.cursor(CGPoint(x: 300, y: 500), head: head, at: 0)
        #expect(p.cursor(CGPoint(x: 560, y: 500), head: head, at: 0.1) == .startle)   // 2600 pt/s, 60 pt away
        _ = p.cursor(CGPoint(x: 300, y: 500), head: head, at: 0.2)
        #expect(p.cursor(CGPoint(x: 560, y: 500), head: head, at: 0.3) != .startle)   // cooldown
        _ = p.cursor(CGPoint(x: 300, y: 500), head: head, at: 9.0)
        #expect(p.cursor(CGPoint(x: 560, y: 500), head: head, at: 9.1) == .startle)   // after 8 s, again
        var slow = Presence()
        _ = slow.cursor(CGPoint(x: 450, y: 500), head: head, at: 0)
        #expect(slow.cursor(CGPoint(x: 470, y: 500), head: head, at: 0.5) != .startle)  // a slow approach just gets a look
    }

    @Test func asleepItDoesntReactToTheCursor() {
        var p = Presence()
        _ = p.activity(sinceKey: 100, sinceAny: 100, at: 100)
        #expect(p.cursor(CGPoint(x: 450, y: 500), head: CGPoint(x: 500, y: 500), at: 100) == .none)
    }
}
