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

    @Test func radialPicksAShapeThatFits() {
        #expect(Placement.radialLayout(center: CGPoint(x: 700, y: 500), visible: screen) == .ring)
        #expect(Placement.radialLayout(center: CGPoint(x: 1400, y: 120), visible: screen) == .above)  // Frogg on the Dock line
        #expect(Placement.radialLayout(center: CGPoint(x: 100, y: 900), visible: screen) == .below)   // under the menu bar
    }

    @Test func halfRingsStayOnTheirSide() {
        let size = RadialMenuView.size
        let mid = size.height / 2
        let up = RadialMenuView.centers(count: 6, in: size, layout: .above)
        let down = RadialMenuView.centers(count: 6, in: size, layout: .below)
        #expect(up.allSatisfy { $0.y <= mid + 22 } && up.contains { $0.y < mid - RadialMenuView.radius * 0.9 })  // flipped: smaller y is higher
        #expect(down.allSatisfy { $0.y >= mid - 22 })
        #expect(up.first!.x < up.last!.x && down.first!.x < down.last!.x)  // left to right
        let v = RadialMenuView(items: (0..<6).map { RadialMenuView.Item(id: "\($0)", title: "Item \($0)", glyph: "•") }, layout: .above)
        #expect(v.bounds.contains(v.contentRect))
        #expect(v.index(at: v.centers[3]) == 3)
    }
}
