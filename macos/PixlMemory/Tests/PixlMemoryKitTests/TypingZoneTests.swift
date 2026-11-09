import CoreGraphics
import Testing
@testable import PixlMemoryKit

@Suite struct TypingZoneTests {
    @Test func aSmallFieldIsKeptClearWholeABigEditorAroundTheCaret() {
        let search = CGRect(x: 400, y: 100, width: 600, height: 36)
        #expect(TypingZone.zone(field: search, caret: nil) == search.insetBy(dx: -16, dy: -12))
        let editor = CGRect(x: 0, y: 80, width: 1400, height: 900)
        let caret = CGRect(x: 300, y: 500, width: 2, height: 18)
        let z = TypingZone.zone(field: editor, caret: caret)!
        #expect(z.contains(CGPoint(x: 600, y: 510)))      // ahead on the line
        #expect(!z.contains(CGPoint(x: 300, y: 300)))     // far above: not in the way
        #expect(TypingZone.zone(field: nil, caret: nil) == nil)
    }

    @Test func movesToTheNearestClearSpotOnTheSamePerch() {
        let sprite = CGSize(width: 120, height: 90)
        let zone = CGRect(x: 400, y: 60, width: 300, height: 60)
        // standing at 550 on a window edge at y 100: clear by moving past either end of the field
        let x = TypingZone.nearestClearX(from: 550, span: 60...1500, footY: 100, sprite: sprite, zone: zone)!
        #expect(x <= 340 || x >= 760)
        #expect(abs(x - 550) <= 240)
        // no room on a short perch
        #expect(TypingZone.nearestClearX(from: 550, span: 500...600, footY: 100, sprite: sprite, zone: zone) == nil)
    }
}
