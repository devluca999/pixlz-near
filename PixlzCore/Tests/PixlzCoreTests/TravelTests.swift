import CryptoKit
import Foundation
import Testing
@testable import PixlzCore

/// Two devices and an in-memory, in-order wire. Every envelope goes through the real framing and JSON.
struct TravelSim {
    var nodes: [String: TravelNode]
    var devices: [String: DeviceRef]
    var wire: [(to: String, from: DeviceRef, frame: Data)] = []
    var now = tripStart
    var events: [String] = []
    /// Called after every delivery; records any invariant violation.
    var violations: [String] = []

    init(owner: DeviceRef = mac, other: DeviceRef = phone, state: PetState = sampleFrogg(), otherRecord: StoredPet? = nil) {
        nodes = [owner.deviceId: TravelNode(me: owner, record: .owned(state)),
                 other.deviceId: TravelNode(me: other, record: otherRecord)]
        devices = [owner.deviceId: owner, other.deviceId: other]
    }

    subscript(_ d: DeviceRef) -> TravelNode {
        get { nodes[d.deviceId]! }
        set { nodes[d.deviceId] = newValue }
    }

    /// Feeds an input; performs outputs in order. `crashAfterSave` kills the node right after its first
    /// `.saved` output, before anything after it is sent.
    mutating func input(_ d: DeviceRef, _ i: TravelNode.Input, crashAfterSave: Bool = false) {
        let outs = nodes[d.deviceId]!.handle(i, at: now)
        for o in outs {
            switch o {
            case .send(let env, let to):
                wire.append((to.deviceId, d, try! Framing.encode(env)))
            case .saved:
                if crashAfterSave { crash(d); return }
            case .playExit(let to): events.append("\(d.deviceName): exit → \(to.deviceName)")
            case .playEntrance: events.append("\(d.deviceName): entrance")
            case .shrug(let r): events.append("\(d.deviceName): shrug \(r)")
            }
        }
        check()
    }

    /// Delivers the oldest message. False when the wire is empty.
    @discardableResult
    mutating func step(crashReceiverAfterSave: Bool = false) -> Bool {
        guard !wire.isEmpty else { return false }
        let m = wire.removeFirst()
        var dec = Framing.Decoder()
        let env = try! dec.feed(m.frame)[0]
        input(devices[m.to]!, .received(env, from: m.from), crashAfterSave: crashReceiverAfterSave)
        return true
    }

    mutating func drain(limit: Int = 100) { for _ in 0..<limit where step() {} }

    /// Kills the process: memory gone, disk kept. Messages on their way to it are lost; messages it
    /// already sent may still arrive (the worse case for the protocol).
    mutating func crash(_ d: DeviceRef) {
        nodes[d.deviceId]!.crash()
        wire.removeAll { $0.to == d.deviceId }
        events.append("\(d.deviceName): crash")
    }

    mutating func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for d in devices.values.sorted(by: { $0.deviceId < $1.deviceId }) { input(d, .tick) }
    }

    mutating func reconnect() {
        for d in devices.values.sorted(by: { $0.deviceId < $1.deviceId }) {
            let other = devices.values.first { $0 != d }!
            input(d, .connected(other))
        }
    }

    /// SPEC §14: at least one complete copy, at most one `.owned`, after every step.
    mutating func check() {
        let records = nodes.values.compactMap(\.record)
        if records.allSatisfy({ $0.completeCopy == nil }) { violations.append("no complete copy at \(events.last ?? "start")") }
        if records.filter(\.isOwned).count > 1 { violations.append("two owners at \(events.last ?? "start")") }
    }

    var owners: [DeviceRef] { devices.values.filter { nodes[$0.deviceId]!.record?.isOwned == true } }

    func owned(_ d: DeviceRef) -> PetState? {
        if case .owned(let s)? = nodes[d.deviceId]!.record { return s }
        return nil
    }

    /// Lets the dust settle: deliver, time out, reconnect, deliver.
    mutating func settle() {
        drain()
        advance(TravelNode.receiverTimeout + 1)
        drain()
        reconnect()
        drain()
        advance(TravelNode.receiverTimeout + 1)
        drain()
    }
}

@Suite struct TravelTests {
    @Test func happyPathMacToPhoneAndBack() throws {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.drain()
        #expect(sim.violations == [])
        #expect(sim.owners == [phone])
        let arrived = try #require(sim.owned(phone))
        #expect(arrived.epoch == 2)
        #expect(arrived.owner == phone)
        #expect(arrived.stats.pokes == 41 && arrived.stats.trips == 1)
        #expect(arrived.emotion?.kind == .happy)
        guard case .away(_, 2, "Luca's iPhone", _, let t?)? = sim[mac].record else { Issue.record("mac not away"); return }
        #expect(t.epoch == 2)
        #expect(sim.events == ["Luca's Mac: exit → Luca's iPhone", "Luca's iPhone: entrance"])
        #expect(!sim[mac].inTrip && !sim[phone].inTrip)

        sim.input(phone, .send(to: mac))
        sim.drain()
        #expect(sim.owners == [mac])
        #expect(sim.owned(mac)?.epoch == 3)
        #expect(sim.violations == [])
    }

    @Test func callFromThePhone() {
        var sim = TravelSim(otherRecord: .away(petId: sampleFrogg().petId, epoch: 1, ownerName: "Luca's Mac", ownerId: nil, tombstone: nil))
        sim.input(phone, .call(owner: mac))
        sim.drain()
        #expect(sim.owners == [phone])
    }

    @Test func declineLeavesThePixlHome() {
        var sim = TravelSim()
        sim[phone].canHost = false
        sim.input(mac, .send(to: phone))
        sim.drain()
        #expect(sim.owners == [mac])
        #expect(sim.events == ["Luca's Mac: shrug busy"])
        #expect(sim.owned(mac)?.epoch == 1)
    }

    @Test func unknownSpeciesAndOtherPetDecline() {
        var sim = TravelSim()
        sim[phone].knownSpecies = []
        sim.input(mac, .send(to: phone)); sim.drain()
        #expect(sim.events.last == "Luca's Mac: shrug unsupportedSpecies")

        var other = sampleFrogg(); other.petId = UUID(); other.owner = phone
        var sim2 = TravelSim(otherRecord: .owned(other))
        sim2.input(mac, .send(to: phone)); sim2.drain()
        #expect(sim2.events.last == "Luca's Mac: shrug hasOtherPet")
    }

    @Test func noAnswerTimesOut() {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.wire.removeAll()   // the phone never hears it
        sim.advance(TravelNode.senderTimeout)
        #expect(sim.events == ["Luca's Mac: shrug timeout"])
        #expect(sim.owners == [mac])
        #expect(!sim[mac].inTrip)
    }

    @Test func checksumMismatchAborts() throws {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.step()   // offer → phone
        sim.step()   // accept → mac
        sim.step()   // transfer → phone, saves pending, sends ack
        // Corrupt the ack in flight.
        var dec = Framing.Decoder()
        var ack = try dec.feed(sim.wire[0].frame)[0]
        ack.payload.checksum = String(repeating: "0", count: 64)
        sim.wire[0].frame = try Framing.encode(ack)
        sim.drain()
        #expect(sim.events == ["Luca's Mac: shrug checksumMismatch"])
        #expect(sim.owners == [mac])
        guard case .away(_, 1, _, _, nil)? = sim[phone].record else { Issue.record("phone kept pending: \(String(describing: sim[phone].record))"); return }
        #expect(sim.violations == [])
    }

    @Test func secondSendWhileBusyShrugs() {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.input(mac, .send(to: phone))
        #expect(sim.events == ["Luca's Mac: shrug busy"])
    }

    @Test func conflictHigherEpochWins() {
        var a = sampleFrogg(); a.epoch = 4
        var b = sampleFrogg(); b.epoch = 5; b.owner = phone
        var sim = TravelSim(state: a, otherRecord: .owned(b))
        sim.violations = []
        sim.reconnect(); sim.drain()
        #expect(sim.owners == [phone])
        // the losing copy is kept as a tombstone of its own (reclaim only by hand, P3)
        guard case .away(_, 5, _, _, let t?)? = sim[mac].record else { Issue.record("no tombstone"); return }
        #expect(t.owner.deviceId == mac.deviceId)
    }

    @Test func conflictTieGoesToSmallerDeviceId() {
        var b = sampleFrogg(); b.owner = phone
        var sim = TravelSim(otherRecord: .owned(b))
        sim.reconnect(); sim.drain()
        #expect(sim.owners == [phone])   // "A9F0-PHONE" < "B1C2-MAC"
    }

    @Test func senderRestoresFromTombstoneWhenReceiverLostIt() {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.step(); sim.step(); sim.step(); sim.step()   // offer, accept, transfer, ack: mac is .away
        guard case .away? = sim[mac].record else { Issue.record("mac should be away"); return }
        // The phone's disk is wiped before commit (e.g. the app was deleted).
        sim.crash(phone)
        sim[phone] = TravelNode(me: phone, record: nil)
        sim.violations = []
        sim.reconnect(); sim.drain()
        #expect(sim.owners == [mac])
        #expect(sim.owned(mac)?.epoch == 3)   // tombstone epoch 2, +1
    }

    @Test func reclaimWhileTheHolderIsAwayThenItGivesWay() throws {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.drain()
        #expect(sim.owners == [phone])
        #expect(sim[mac].canReclaim)
        // The phone goes dark (battery, left at the office). The Mac brings Frogg back anyway.
        sim.crash(phone)
        sim.violations = []
        sim.input(mac, .reclaim)
        #expect(sim.owned(mac)?.epoch == 4)            // phone holds epoch 2
        #expect(sim.events.last == "Luca's Mac: entrance")
        #expect(!sim[mac].canReclaim)
        // Both think they have him until they meet; then the phone gives way.
        sim.violations = []
        sim.reconnect(); sim.drain()
        #expect(sim.owners == [mac])
        #expect(sim.owned(mac)?.epoch == 4)
        guard case .away? = sim[phone].record else { Issue.record("phone should have let go"); return }
        // Nothing to reclaim when the Pixl is here or there's no safety copy.
        var fresh = TravelSim(otherRecord: .away(petId: sampleFrogg().petId, epoch: 1, ownerName: "Luca's Mac", ownerId: nil, tombstone: nil))
        fresh.input(phone, .reclaim)
        #expect(fresh.owners == [mac] && !fresh[phone].canReclaim && !fresh[mac].canReclaim)
    }

    /// Two copies after two reclaims (Mac at 11, Mosaico at 13). The Mosaico only asks (it never
    /// asks back when asked): the Mac must ask back, learn it's older, and leave the screen.
    @Test func anOlderCopyAsksBackAndGivesWay() throws {
        var frogg = sampleFrogg()
        frogg.epoch = 11
        var node = TravelNode(me: mac, record: .owned(frogg))
        let status = Envelope(petId: frogg.petId, from: phone.deviceId, to: mac.deviceId, type: .status, epoch: 13, sentAt: tripStart)
        let out = node.handle(.received(status, from: phone), at: tripStart)
        let sent = out.compactMap { o -> EnvelopeType? in if case .send(let e, _) = o { return e.type } else { return nil } }
        #expect(sent == [.statusReply, .status])
        let reply = Envelope(petId: frogg.petId, from: phone.deviceId, to: mac.deviceId, type: .statusReply, epoch: 13,
                             payload: Payload(held: .owned, inTrip: false), sentAt: tripStart)
        let settled = node.handle(.received(reply, from: phone), at: tripStart)
        #expect(settled.contains(.playExit(to: phone)))
        guard case .away(_, 13, _, _, _)? = node.record else { Issue.record("the Mac should have let go"); return }
        // The newer side, asked by an older one, just answers: no ping-pong.
        var newer = sampleFrogg()
        newer.epoch = 13
        var other = TravelNode(me: phone, record: .owned(newer))
        let ask = Envelope(petId: newer.petId, from: mac.deviceId, to: phone.deviceId, type: .status, epoch: 11, sentAt: tripStart)
        #expect(other.handle(.received(ask, from: mac), at: tripStart).count == 1)
    }

    /// Sending a Pixl that's already on the other device: it says so, and the copies settle.
    @Test func sendingToWhereItAlreadyIsSettlesTheCopies() throws {
        var older = sampleFrogg(); older.epoch = 11
        var newer = sampleFrogg(); newer.epoch = 13
        var m = TravelNode(me: mac, record: .owned(older))
        var p = TravelNode(me: phone, record: .owned(newer))
        // Mac → offer → phone declines "alreadyHere"
        var toPhone = m.handle(.send(to: phone), at: tripStart).compactMap { o -> Envelope? in if case .send(let e, _) = o { e } else { nil } }
        #expect(toPhone.first?.type == .offer)
        let decline = p.handle(.received(toPhone[0], from: mac), at: tripStart).compactMap { o -> Envelope? in if case .send(let e, _) = o { e } else { nil } }
        #expect(decline.first?.type == .decline && decline.first?.payload.reason == "alreadyHere")
        // The Mac shrugs and asks; the phone answers; the Mac (older) leaves.
        let afterDecline = m.handle(.received(decline[0], from: phone), at: tripStart)
        #expect(afterDecline.contains(.shrug(reason: "alreadyHere")))
        toPhone = afterDecline.compactMap { o -> Envelope? in if case .send(let e, _) = o { e } else { nil } }
        #expect(toPhone.last?.type == .status)
        let reply = p.handle(.received(toPhone.last!, from: mac), at: tripStart).compactMap { o -> Envelope? in if case .send(let e, _) = o { e } else { nil } }
        #expect(reply.map(\.type) == [.statusReply])   // the phone is newer: it just answers
        let settled = m.handle(.received(reply[0], from: phone), at: tripStart)
        #expect(settled.contains(.playExit(to: phone)))
        guard case .away? = m.record, case .owned? = p.record else { Issue.record("the Mac should have let go"); return }
    }

    /// SPEC §14: kill either process (or both) between any two messages, and right after any save,
    /// then reconnect. The invariant holds throughout and exactly one device ends up with the Pixl.
    @Test func crashAtEveryStep() {
        var clean = TravelSim()
        clean.input(mac, .send(to: phone))
        var deliveries = 0
        while clean.step() { deliveries += 1 }
        #expect(deliveries == 6)   // offer accept transfer ack commit commitAck

        enum Victim: CaseIterable { case sender, receiver, both }
        var cases = 0
        for k in 0...deliveries {
            for victim in Victim.allCases {
                for afterSave in [false, true] {
                    var sim = TravelSim()
                    sim.input(mac, .send(to: phone))
                    for _ in 0..<k { sim.step() }
                    if afterSave {
                        // Deliver one more message and kill its receiver right after it persists.
                        sim.step(crashReceiverAfterSave: true)
                    }
                    switch victim {
                    case .sender: sim.crash(mac)
                    case .receiver: sim.crash(phone)
                    case .both: sim.crash(mac); sim.crash(phone)
                    }
                    sim.settle()
                    let label = "k=\(k) \(victim) afterSave=\(afterSave)"
                    #expect(sim.violations == [], "\(label)")
                    #expect(sim.owners.count == 1, "\(label): owners \(sim.owners.map(\.deviceName)) \(sim.events)")
                    if let owner = sim.owners.first, let s = sim.owned(owner) {
                        #expect(s.petId == sampleFrogg().petId && s.name == "Frogg" && s.stats.pokes == 41, "\(label)")
                        #expect(s.owner == owner, "\(label)")
                    }
                    #expect(!sim[mac].inTrip && !sim[phone].inTrip, "\(label)")
                    cases += 1
                }
            }
        }
        #expect(cases == 42)
    }
}

@Suite struct TransportTests {
    @Test func framingSplitsAndJoins() throws {
        let tripStart = Date(timeIntervalSince1970: 1_800_000_000.5)   // whole milliseconds survive the wire exactly
        let a = Envelope(petId: UUID(), from: "m", to: "p", type: .offer, epoch: 3, payload: Payload(species: "frogg", name: "Frogg"), sentAt: tripStart)
        let b = Envelope(petId: UUID(), from: "p", to: "m", type: .ack, epoch: 4, payload: Payload(checksum: "ab"), sentAt: tripStart)
        let bytes = try Framing.encode(a) + Framing.encode(b)
        var dec = Framing.Decoder()
        var got: [Envelope] = []
        for chunk in stride(from: 0, to: bytes.count, by: 7) {
            got += try dec.feed(bytes.subdata(in: chunk..<min(chunk + 7, bytes.count)))
        }
        #expect(got == [a, b])
    }

    @Test func framingRejectsHugeFrames() {
        var dec = Framing.Decoder()
        #expect(throws: Framing.FramingError.frameTooLarge(0x7FFF_FFFF)) {
            try dec.feed(Data([0x7F, 0xFF, 0xFF, 0xFF]))
        }
    }
}
