import CoreGraphics
import Testing
@testable import PixlMemoryKit

@Suite struct PixlScaleTests {
    @Test func snapsToCrispHalfStepsWithinRange() {
        #expect(PixlScale.snap(2.3) == 2.5 && PixlScale.snap(2.2) == 2)
        #expect(PixlScale.snap(0.2) == 1 && PixlScale.snap(9) == 6)
        #expect(PixlScale.snap(2.4, backing: 1) == 2)   // a 1× display: whole steps only
        #expect(PixlScale.label(2) == "2×" && PixlScale.label(2.5) == "2.5×")
    }

    @Test func draggingACornerScalesFromTheFeet() {
        let feet = CGPoint(x: 500, y: 800)
        let topRight = CGVector(dx: 50, dy: -80)                   // box 100 wide, 80 tall at 2×
        // drag the top-right corner out to twice as far: 4×
        #expect(PixlScale.fromDrag(start: 2, corner: topRight, mouse: CGPoint(x: 600, y: 640), feet: feet) == 4)
        // and in to half: 1×
        #expect(PixlScale.fromDrag(start: 2, corner: topRight, mouse: CGPoint(x: 525, y: 760), feet: feet) == 1)
        // a bottom corner works sideways only
        let bottomLeft = CGVector(dx: -50, dy: 0)
        #expect(PixlScale.fromDrag(start: 2, corner: bottomLeft, mouse: CGPoint(x: 425, y: 900), feet: feet) == 3)
        // past the feet never goes negative
        #expect(PixlScale.fromDrag(start: 2, corner: topRight, mouse: CGPoint(x: 400, y: 900), feet: feet) == 0)
    }
}
