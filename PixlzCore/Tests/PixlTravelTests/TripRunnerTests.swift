import Foundation
import PixlzCore
import Testing
@testable import PixlTravel

/// A store whose saves fail on demand.
final class FlakyStore: PetStore, @unchecked Sendable {
    var value: StoredPet?
    var failSaves = false
    init(_ v: StoredPet?) { value = v }
    struct Broken: Error {}
    func load() throws -> StoredPet? { value }
    func save(_ pet: StoredPet) throws {
        if failSaves { throw Broken() }
        value = pet
    }
    var changes: AsyncStream<StoredPet> { AsyncStream { _ in } }
}

/// TripRunner without a network: sends are captured.
@MainActor
struct TripRunnerTests {
    let me = DeviceRef(deviceId: "B-MAC", deviceName: "Mac")
    let other = DeviceRef(deviceId: "A-OTHER", deviceName: "Other Mac")
    let petId = UUID()

    func pixl(owner: DeviceRef, epoch: Int = 1) -> PetState {
        var s = PetState(petId: petId, species: "frogg", name: "Frogg", owner: owner, at: Date())
        s.epoch = epoch
        return s
    }

    func runner(_ store: PetStore, sent: @escaping (Envelope) -> Void) -> TripRunner {
        let r = TripRunner(me: me, store: store, knownSpecies: ["frogg"], trusted: [other.deviceId])
        r.sender = { env, _ in sent(env) }
        return r
    }

    func env(_ type: EnvelopeType, epoch: Int, payload: Payload = Payload()) -> Envelope {
        Envelope(petId: petId, from: other.deviceId, to: me.deviceId, type: type, epoch: epoch, payload: payload, sentAt: Date())
    }

    // P8: a save that fails stops the trip: no ack, an abort, the disk record back, a problem shown.
    @Test func aFailedSaveAbortsAndReloads() {
        let store = FlakyStore(nil)
        var sent: [Envelope] = []
        var problems: [String] = []
        let r = runner(store) { sent.append($0) }
        r.onProblem = { problems.append($0) }
        r.feed(.received(env(.offer, epoch: 1, payload: Payload(species: "frogg", name: "Frogg")), from: other))
        #expect(sent.map(\.type) == [.accept])
        store.failSaves = true
        r.feed(.received(env(.transfer, epoch: 2, payload: Payload(state: pixl(owner: me, epoch: 2))), from: other))
        #expect(sent.map(\.type) == [.accept, .abort])
        #expect(sent.last?.payload.reason == "saveFailed")
        #expect(r.record == nil && !r.node.inTrip)
        #expect(problems.count == 1)
    }

    // P8: adopt and restyle saves report failure and change nothing.
    @Test func adoptAndRestyleReportFailedSaves() {
        let store = FlakyStore(nil)
        store.failSaves = true
        var problems = 0
        let r = runner(store) { _ in }
        r.onProblem = { _ in problems += 1 }
        r.adoptIfNeeded(species: "frogg", name: "Frogg")
        #expect(r.record == nil && problems == 1)
        store.failSaves = false
        r.adoptIfNeeded(species: "frogg", name: "Frogg")
        #expect(r.owned != nil)
        store.failSaves = true
        #expect(!r.restyle(species: "frogg", name: "Ribbit"))
        #expect(r.owned?.name == "Frogg" && problems == 2)
    }

    // M2: restyle applies only while the Pixl is here.
    @Test func restyleOnlyWhenOwned() {
        let r = runner(FlakyStore(.away(petId: petId, epoch: 2, ownerName: "Other Mac", ownerId: other.deviceId, tombstone: nil))) { _ in }
        #expect(!r.restyle(species: "frogg", name: "Ribbit"))
        let o = runner(FlakyStore(.owned(pixl(owner: me)))) { _ in }
        var seen: StoredPet?
        o.onRecord = { seen = $0 }
        #expect(o.restyle(species: "frogg", name: "Ribbit"))
        #expect(o.owned?.name == "Ribbit" && seen?.completeCopy?.name == "Ribbit")
    }

    // P9: an unreadable pet.json is kept aside; no new Pixl is adopted over it.
    @Test func unreadableStoreIsAProblemNotANewPixl() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pixl-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("pet.json"))
        let r = TripRunner(me: me, store: FilePetStore(directory: dir), knownSpecies: ["frogg"])
        #expect(r.loadProblem != nil && r.record == nil)
        r.adoptIfNeeded(species: "frogg", name: "Frogg")
        #expect(r.record == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("pet.json.corrupt-") })
    }

    // P7: `call` only from a trusted or paired device.
    @Test func callsFromStrangersAreRefused() {
        var sent: [Envelope] = []
        var logs: [String] = []
        let r = TripRunner(me: me, store: FlakyStore(.owned(pixl(owner: me))), knownSpecies: ["frogg"])
        r.sender = { e, _ in sent.append(e) }
        r.onLog = { logs.append($0) }
        r.incoming(env(.call, epoch: 1), from: other)
        #expect(sent.isEmpty && logs.count == 1)
        r.isPaired = { $0 == "A-OTHER" }
        r.incoming(env(.call, epoch: 1), from: other)
        #expect(sent.map(\.type) == [.offer])
    }

    // M5: "just this time" doesn't trust; "always" does.
    @Test func consentOnceDoesNotTrust() {
        let r = TripRunner(me: me, store: FlakyStore(nil), knownSpecies: ["frogg"])
        r.sender = { _, _ in }
        var asked = 0
        r.onAsk = { _, _ in asked += 1 }
        r.incoming(env(.offer, epoch: 1, payload: Payload(species: "frogg", name: "Frogg")), from: other)
        r.consent(true, always: false, for: other)
        #expect(asked == 1 && !r.trusted.contains(other.deviceId) && r.node.inTrip)
        let r2 = TripRunner(me: me, store: FlakyStore(nil), knownSpecies: ["frogg"])
        r2.sender = { _, _ in }
        r2.incoming(env(.offer, epoch: 1, payload: Payload(species: "frogg", name: "Frogg")), from: other)
        r2.consent(true, always: true, for: other)
        #expect(r2.trusted.contains(other.deviceId))
    }

    // M8: a copy that gives way says so (not "left for").
    @Test func givingWayIsNotATrip() {
        let r = runner(FlakyStore(.owned(pixl(owner: me, epoch: 3)))) { _ in }
        var exits: [String] = []
        r.onExit = { _ in exits.append("exit") }
        r.onGaveWay = { _ in exits.append("gave way") }
        r.feed(.connected(other))
        r.feed(.received(env(.statusReply, epoch: 5, payload: Payload(held: .owned, inTrip: false)), from: other))
        #expect(exits == ["gave way"] && r.owned == nil)
    }

    // P6: a pending arrival asks every reachable device again.
    @Test func pendingArrivalRechecks() {
        var sent: [(Envelope, DeviceRef)] = []
        let third = DeviceRef(deviceId: "C-THIRD", deviceName: "Third")
        let r = TripRunner(me: me, store: FlakyStore(.pendingArrival(pixl(owner: me, epoch: 2), from: other)), knownSpecies: ["frogg"])
        r.sender = { sent.append(($0, $1)) }
        r.peers = [other, third]
        r.feed(.tick)   // any input schedules the checks
        #expect(r.pendingCheckActive)
        r.recheck()
        #expect(sent.map(\.0.type) == [.status, .status] && Set(sent.map(\.1.deviceId)) == ["A-OTHER", "C-THIRD"])
        // the sender says it's away at that epoch: owned here, checks stop, one more soon
        var toMe = Payload(held: .away, inTrip: false)
        toMe.holderId = me.deviceId
        r.feed(.received(env(.statusReply, epoch: 2, payload: toMe), from: other))
        #expect(r.owned != nil && !r.pendingCheckActive && r.recheckSoonScheduled)
    }

    // An untrusted, unpaired device can't make the Pixl here give way; a paired one can.
    @Test func onlyTrustedOrPairedPeersCanTakeIt() {
        let stranger = DeviceRef(deviceId: "0-STRANGER", deviceName: "Stranger")
        let r = TripRunner(me: me, store: FlakyStore(.owned(pixl(owner: me, epoch: 4))), knownSpecies: ["frogg"])
        r.sender = { _, _ in }
        var gaveWay = 0
        r.onGaveWay = { _ in gaveWay += 1 }
        r.feed(.connected(stranger))
        r.feed(.received(Envelope(petId: petId, from: stranger.deviceId, to: me.deviceId, type: .statusReply, epoch: 50,
                                  payload: Payload(held: .owned, inTrip: false), sentAt: Date()), from: stranger))
        #expect(r.owned != nil && gaveWay == 0)
        r.isPaired = { $0 == stranger.deviceId }
        r.feed(.connected(stranger))
        r.feed(.received(Envelope(petId: petId, from: stranger.deviceId, to: me.deviceId, type: .statusReply, epoch: 50,
                                  payload: Payload(held: .owned, inTrip: false), sentAt: Date()), from: stranger))
        #expect(r.owned == nil && gaveWay == 1 && r.canReclaim)
    }
}
