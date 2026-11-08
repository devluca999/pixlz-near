import AppKit
import Testing
@testable import PixlMemoryKit

@MainActor
struct PlacementTests {
    let screen = CGRect(x: 0, y: 70, width: 1512, height: 870)  // AppKit: Dock below y 70, menu bar above y 940

    @Test func fitMovesTheLeastToStayOnScreen() {
        #expect(Placement.fit(CGRect(x: 100, y: 300, width: 200, height: 100), in: screen) == CGRect(x: 100, y: 300, width: 200, height: 100))
        #expect(Placement.fit(CGRect(x: 1400, y: 300, width: 200, height: 100), in: screen).maxX == screen.maxX - 8)
        #expect(Placement.fit(CGRect(x: 100, y: 20, width: 200, height: 100), in: screen).minY == screen.minY + 8)   // above the Dock
        #expect(Placement.fit(CGRect(x: 100, y: 900, width: 200, height: 100), in: screen).maxY == screen.maxY - 8)  // below the menu bar
        let huge = Placement.fit(CGRect(x: 0, y: 0, width: 400, height: 2000), in: screen)
        #expect(huge.maxY == screen.maxY - 8)  // too tall: keep the top (title, close button) visible
    }

}
