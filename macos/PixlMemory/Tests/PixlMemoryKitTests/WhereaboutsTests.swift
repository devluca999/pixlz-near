import Foundation
import Testing
import PixlzCore
@testable import PixlMemoryKit

/// M1: where the Pixl is comes from the record, nothing else.
@Suite struct WhereaboutsTests {
    let me = DeviceRef(deviceId: "MAC", deviceName: "Mac")

    @Test func theRecordSaysWhereThePixlIs() {
        let s = PetState(species: "frogg", name: "Frogg", owner: me, at: Date())
        #expect(Whereabouts.awayOn(.owned(s)) == nil)
        #expect(Whereabouts.awayOn(.away(petId: s.petId, epoch: 2, ownerName: "Mosaico", ownerId: "M-1", tombstone: nil)) == "Mosaico")
        #expect(Whereabouts.awayOn(.pendingArrival(s, from: nil)) == "arriving")   // not here yet: hidden, can't send
        #expect(Whereabouts.awayOn(nil) == "another device")
    }

    @Test func travelNoticesReadAsSentences() {
        for n in [Notice.alreadyHas("Mosaico", "Frogg"), .awayNoSwap("Frogg"), .arriving("Frogg"), .travelProblem("Disk full"),
                  .petUnreadable, .trustRemoved("Laptop")] {
            #expect(n.text.first!.isUppercase && ".…!?".contains(n.text.last!), "\(n.text)")
        }
        #expect(Notice.alreadyHas("Mosaico", "Frogg").text == "Mosaico already has Frogg.")
        #expect(Notice.awayNoSwap("Frogg").text == "Frogg is away — swap when it's back.")
    }
}
