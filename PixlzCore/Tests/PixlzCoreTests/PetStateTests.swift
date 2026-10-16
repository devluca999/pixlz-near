import Foundation
import Testing
@testable import PixlzCore

let mac = DeviceRef(deviceId: "B1C2-MAC", deviceName: "Luca's Mac")
let phone = DeviceRef(deviceId: "A9F0-PHONE", deviceName: "Luca's iPhone")
let tripStart = Date(timeIntervalSince1970: 1_800_000_000.123_456)

func sampleFrogg() -> PetState {
    var s = PetState(petId: UUID(uuidString: "6F0E2C1A-0000-4000-8000-000000000001")!, species: "frogg", name: "Frogg", owner: mac, at: tripStart)
    s.stats.pokes = 41
    s.emotion = EmotionState(kind: .happy, until: tripStart.addingTimeInterval(4))
    return s
}

@Suite struct PetStateTests {
    @Test func canonicalEncodingIsSortedCompactAndStable() throws {
        let s = sampleFrogg()
        let json = String(decoding: try s.canonicalData(), as: UTF8.self)
        #expect(!json.contains("\": ") && !json.contains(", \""))
        #expect(!json.contains("\n"))
        #expect(json.hasPrefix(#"{"createdAt":"2027-01-15T08:00:00.123Z","emotion""#))
        // Decoding and re-encoding gives the same bytes, so sender and receiver agree on the checksum.
        let back = try PetState.decode(s.canonicalData())
        #expect(try back.canonicalData() == s.canonicalData())
        #expect(try back.checksum() == s.checksum())
        #expect(try s.checksum().count == 64)
    }

    @Test func checksumChangesWithContent() throws {
        var s = sampleFrogg()
        let a = try s.checksum()
        s.stats.pokes += 1
        #expect(try s.checksum() != a)
    }

    @Test func fileStoreRoundTripsEveryCase() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixlz-store-\(UUID().uuidString)")
        let store = FilePetStore(directory: dir)
        #expect(try store.load() == nil)
        let s = try PetState.decode(sampleFrogg().canonicalData())
        for pet in [StoredPet.owned(s), .pendingArrival(s), .away(petId: s.petId, epoch: 8, ownerName: "Luca's iPhone", tombstone: s),
                    .away(petId: s.petId, epoch: 9, ownerName: "x", tombstone: nil)] {
            try store.save(pet)
            #expect(try store.load() == pet)
        }
    }

    @Test func storeBroadcastsChanges() async throws {
        let store = InMemoryPetStore()
        var it = store.changes.makeAsyncIterator()
        try store.save(.owned(sampleFrogg()))
        #expect(await it.next()?.isOwned == true)
    }

    @Test func tombstoneExpiresAfterSevenDays() {
        let s = sampleFrogg()
        let away = StoredPet.away(petId: s.petId, epoch: 2, ownerName: "x", tombstone: s)
        #expect(away.pruned(at: s.savedAt.addingTimeInterval(6 * 86400)).completeCopy != nil)
        #expect(away.pruned(at: s.savedAt.addingTimeInterval(8 * 86400)).completeCopy == nil)
    }
}
