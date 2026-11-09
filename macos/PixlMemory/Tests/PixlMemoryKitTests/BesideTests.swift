import CoreGraphics
import Testing
@testable import PixlMemoryKit

@MainActor @Suite struct BesideTests {
    let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    let size = CGSize(width: 220, height: 22)

    @Test func aboveTheHeadWhenThereIsRoom() {
        let pet = CGRect(x: 700, y: 100, width: 136, height: 96)
        let r = Placement.beside(pet: pet, size: size, in: screen)
        #expect(r.minY >= pet.maxY)
        #expect(!r.intersects(pet))
    }

    @Test func belowWhenThePixlIsAtTheTop() {
        let pet = CGRect(x: 700, y: 900, width: 136, height: 96)   // head at the top of the screen
        let r = Placement.beside(pet: pet, size: size, in: screen)
        #expect(r.maxY <= pet.minY)
        #expect(!r.intersects(pet))
    }

    @Test func toTheSideWhenItFillsTheHeight() {
        let pet = CGRect(x: 700, y: 10, width: 136, height: 975)
        let r = Placement.beside(pet: pet, size: size, in: screen)
        #expect(!r.intersects(pet))
        #expect(r.maxX <= pet.minX || r.minX >= pet.maxX)
    }

    @Test func neverOnThePixlInACorner() {
        for pet in [CGRect(x: 0, y: 0, width: 136, height: 96), CGRect(x: 1464, y: 904, width: 136, height: 96),
                    CGRect(x: 1500, y: 0, width: 100, height: 120), CGRect(x: 0, y: 880, width: 150, height: 120)] {
            let r = Placement.beside(pet: pet, size: size, in: screen)
            #expect(!r.intersects(pet), "\(pet)")
            #expect(screen.contains(r), "\(pet)")
        }
    }
}
