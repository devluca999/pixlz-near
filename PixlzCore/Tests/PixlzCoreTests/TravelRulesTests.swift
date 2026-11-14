import Foundation
import Testing
@testable import PixlzCore

// The shared protocol rules P1–P10 (the Mosaico firmware follows the same ones).

let mosaico = DeviceRef(deviceId: "C7D8-MOSAICO", deviceName: "Mosaico")

private func env(_ type: EnvelopeType, from: DeviceRef, to: DeviceRef, epoch: Int, payload: Payload = Payload(),
                 petId: UUID = sampleFrogg().petId) -> Envelope {
    Envelope(petId: petId, from: from.deviceId, to: to.deviceId, type: type, epoch: epoch, payload: payload, sentAt: tripStart)
}

private func sends(_ outs: [TravelNode.Output]) -> [Envelope] {
    outs.compactMap { if case .send(let e, _) = $0 { e } else { nil } }
}

private func frogg(epoch: Int, owner: DeviceRef = mac) -> PetState {
    var s = sampleFrogg()
    s.epoch = epoch
    s.owner = owner
    return s
}

@Suite struct TravelRulesTests {
    // P1: the away record keeps the holder's id; old files without it still load.
    @Test func awayRecordsKeepTheHolderIdAndOldFilesLoad() throws {
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.drain()
        guard case .away(_, _, "Luca's iPhone", phone.deviceId?, _)? = sim[mac].record else {
            Issue.record("no holder id: \(String(describing: sim[mac].record))"); return
        }
        let old = #"{"kind":"away","petId":"6F0E2C1A-0000-4000-8000-000000000001","epoch":3,"ownerName":"Luca's iPhone"}"#
        let rec = try PetState.decoder.decode(StoredPet.self, from: Data(old.utf8))
        #expect(rec == .away(petId: sampleFrogg().petId, epoch: 3, ownerName: "Luca's iPhone", ownerId: nil, tombstone: nil))
        let pendingOld = String(decoding: try PetState.encoder.encode(StoredPet.pendingArrival(sampleFrogg(), from: nil)), as: UTF8.self)
        #expect(!pendingOld.contains("\"from\""))
        let s = try PetState.decode(sampleFrogg().canonicalData())
        let back = try PetState.decoder.decode(StoredPet.self, from: try PetState.encoder.encode(StoredPet.pendingArrival(s, from: phone)))
        #expect(back == .pendingArrival(s, from: phone))
    }

    // P2: a statusReply for an away record names where it went.
    @Test func statusReplyNamesTheHolder() {
        var node = TravelNode(me: mac, record: .away(petId: sampleFrogg().petId, epoch: 2, ownerName: "Luca's iPhone",
                                                    ownerId: phone.deviceId, tombstone: nil))
        let out = sends(node.handle(.received(env(.status, from: mosaico, to: mac, epoch: 1), from: mosaico), at: tripStart))
        #expect(out.first?.type == .statusReply)
        #expect(out.first?.payload.held == .away)
        #expect(out.first?.payload.holderId == phone.deviceId && out.first?.payload.holderName == "Luca's iPhone")
        let json = String(decoding: try! PetState.encoder.encode(out[0].payload), as: UTF8.self)
        #expect(json.contains(#""holderId":"A9F0-PHONE""#) && json.contains(#""holderName":"Luca's iPhone""#))
    }

    // P3: an owned copy that loses gives way to the reported holder; it keeps its own state as a
    // tombstone (owned by this device) so a wrong give-way can be reclaimed, never restored by status.
    @Test func aLosingCopyGivesWayKeepingItsOwnTombstone() {
        let kept = { (e: Int) -> PetState in var s = frogg(epoch: e); s.savedAt = tripStart; return s }
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = node.handle(.connected(mosaico), at: tripStart)
        let reply = env(.statusReply, from: mosaico, to: mac, epoch: 6,
                        payload: { var p = Payload(held: .away, inTrip: false); p.holderId = phone.deviceId; p.holderName = phone.deviceName; return p }())
        let out = node.handle(.received(reply, from: mosaico), at: tripStart)
        #expect(out == [.saved(.away(petId: sampleFrogg().petId, epoch: 6, ownerName: "Luca's iPhone", ownerId: phone.deviceId, tombstone: kept(4))),
                        .playExit(to: phone)])
        #expect(node.canReclaim)
        // a later "none" from that peer doesn't bring it back by itself (the tombstone isn't its)
        _ = node.handle(.connected(mosaico), at: tripStart)
        #expect(node.handle(.received(env(.statusReply, from: mosaico, to: mac, epoch: 0, payload: Payload(held: .none, inTrip: false)), from: mosaico), at: tripStart) == [])
        #expect(node.record?.isOwned == false)
        let back = node.handle(.reclaim, at: tripStart)
        #expect(back.contains(.playEntrance) && node.record?.epoch == 8)

        // owned at a higher epoch: the replying peer holds it
        var b = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = b.handle(.connected(phone), at: tripStart)
        let out2 = b.handle(.received(env(.statusReply, from: phone, to: mac, epoch: 5, payload: Payload(held: .owned, inTrip: false)), from: phone), at: tripStart)
        #expect(out2 == [.saved(.away(petId: sampleFrogg().petId, epoch: 5, ownerName: phone.deviceName, ownerId: phone.deviceId, tombstone: kept(4))),
                         .playExit(to: phone)])

        // away at an equal epoch doesn't win; owned at an equal epoch uses the id tie-break
        var c = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = c.handle(.connected(phone), at: tripStart)
        #expect(c.handle(.received(env(.statusReply, from: phone, to: mac, epoch: 4, payload: Payload(held: .away, inTrip: false)), from: phone), at: tripStart) == [])
        #expect(c.record?.isOwned == true)
    }

    // P4: asked by an equal or newer copy, ask back; mid-trip, ask once the trip ends.
    @Test func askBackOnEqualEpochAndAfterATrip() {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        let out = sends(node.handle(.received(env(.status, from: mosaico, to: mac, epoch: 4), from: mosaico), at: tripStart))
        #expect(out.map(\.type) == [.statusReply, .status])
        // no ping-pong: having just asked, we don't ask again
        let again = sends(node.handle(.received(env(.status, from: mosaico, to: mac, epoch: 4), from: mosaico), at: tripStart))
        #expect(again.map(\.type) == [.statusReply])
        // an older asker just gets the answer
        var n2 = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        #expect(sends(n2.handle(.received(env(.status, from: mosaico, to: mac, epoch: 3), from: mosaico), at: tripStart)).map(\.type) == [.statusReply])

        // mid-trip: remember, and ask when the session ends
        var busy = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = busy.handle(.send(to: phone), at: tripStart)
        let during = sends(busy.handle(.received(env(.status, from: mosaico, to: mac, epoch: 5), from: mosaico), at: tripStart))
        #expect(during.map(\.type) == [.statusReply])
        let after = busy.handle(.received(env(.decline, from: phone, to: mac, epoch: 4, payload: Payload(reason: "busy")), from: phone), at: tripStart)
        #expect(sends(after).contains { $0.type == .status && $0.to == mosaico.deviceId })
    }

    // P5: a pending arrival is settled only by the device it came from.
    @Test func pendingIsSettledOnlyByItsSender() {
        let st = frogg(epoch: 3, owner: phone)
        var node = TravelNode(me: phone, record: .pendingArrival(st, from: mac))
        _ = node.handle(.connected(mosaico), at: tripStart)
        _ = node.handle(.connected(mac), at: tripStart)
        // someone else saying "none" doesn't make it ours
        #expect(node.handle(.received(env(.statusReply, from: mosaico, to: phone, epoch: 0, payload: Payload(held: .none, inTrip: false)), from: mosaico), at: tripStart) == [])
        #expect(node.record == .pendingArrival(st, from: mac))
        // the sender away at a higher epoch: not promoted (must be equal)
        #expect(node.handle(.received(env(.statusReply, from: mac, to: phone, epoch: 4, payload: Payload(held: .away, inTrip: false)), from: mac), at: tripStart) == [])
        // the sender away at the same epoch but not naming us (or naming another device): not promoted
        #expect(node.handle(.received(env(.statusReply, from: mac, to: phone, epoch: 3, payload: Payload(held: .away, inTrip: false)), from: mac), at: tripStart) == [])
        let elsewhere = { var p = Payload(held: .away, inTrip: false); p.holderId = mosaico.deviceId; return p }()
        #expect(node.handle(.received(env(.statusReply, from: mac, to: phone, epoch: 3, payload: elsewhere), from: mac), at: tripStart) == [])
        // the sender holding nothing settles nothing either
        #expect(node.handle(.received(env(.statusReply, from: mac, to: phone, epoch: 0, payload: Payload(held: .none, inTrip: false)), from: mac), at: tripStart) == [])
        #expect(node.record == .pendingArrival(st, from: mac))
        // the sender away at the same epoch, naming us: promoted
        let toUs = { var p = Payload(held: .away, inTrip: false); p.holderId = phone.deviceId; return p }()
        let out = node.handle(.received(env(.statusReply, from: mac, to: phone, epoch: 3, payload: toUs), from: mac), at: tripStart)
        #expect(out.contains(.playEntrance))
        #expect(node.record?.isOwned == true)
    }

    // Only a device in `mayGiveWayTo` can make the copy here give way (ids are self-declared).
    @Test func onlyTrustedPeersCanMakeItGiveWay() {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        node.mayGiveWayTo = [phone.deviceId]
        _ = node.handle(.connected(mosaico), at: tripStart)
        let bogus = env(.statusReply, from: mosaico, to: mac, epoch: 99, payload: Payload(held: .owned, inTrip: false))
        #expect(node.handle(.received(bogus, from: mosaico), at: tripStart) == [])
        #expect(node.record?.isOwned == true)
        _ = node.handle(.connected(phone), at: tripStart)
        let real = env(.statusReply, from: phone, to: mac, epoch: 5, payload: Payload(held: .owned, inTrip: false))
        #expect(node.handle(.received(real, from: phone), at: tripStart).contains(.playExit(to: phone)))
    }

    // Giving way mid-trip tells the trip's peer, as the Mosaico does.
    @Test func givingWayMidTripAbortsTheTrip() {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = node.handle(.send(to: mosaico), at: tripStart)
        _ = node.handle(.connected(phone), at: tripStart)
        let out = node.handle(.received(env(.statusReply, from: phone, to: mac, epoch: 6, payload: Payload(held: .owned, inTrip: false)), from: phone), at: tripStart)
        let abort = sends(out).first { $0.type == .abort }
        #expect(abort?.to == mosaico.deviceId && abort?.payload.reason == "gaveWay" && abort?.epoch == 4)
        #expect(!node.inTrip)
    }

    // A committed trip just ends on abandon: no abort (the receiver may own it already).
    @Test func abandonWhileCommittedSendsNoAbort() throws {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = node.handle(.send(to: phone), at: tripStart)
        let transfer = try #require(sends(node.handle(.received(env(.accept, from: phone, to: mac, epoch: 4), from: phone), at: tripStart)).first)
        let sum = try transfer.payload.state!.checksum()
        _ = node.handle(.received(env(.ack, from: phone, to: mac, epoch: 5, payload: Payload(checksum: sum)), from: phone), at: tripStart)
        #expect(node.inTrip && node.record?.isOwned == false)   // committed, waiting for commitAck
        #expect(node.abandon(reload: node.record, reason: "saveFailed", at: tripStart) == [])
        #expect(!node.inTrip)
    }

    // The owner declining our `call` (e.g. locked) is surfaced as a shrug.
    @Test func aDeclinedCallIsSurfaced() {
        var node = TravelNode(me: mac, record: .away(petId: sampleFrogg().petId, epoch: 4, ownerName: mosaico.deviceName, ownerId: mosaico.deviceId, tombstone: nil))
        // not asked: ignored
        #expect(node.handle(.received(env(.decline, from: mosaico, to: mac, epoch: 4, payload: Payload(reason: "locked")), from: mosaico), at: tripStart) == [])
        _ = node.handle(.call(owner: mosaico), at: tripStart)
        // someone else: ignored
        #expect(node.handle(.received(env(.decline, from: phone, to: mac, epoch: 4, payload: Payload(reason: "locked")), from: phone), at: tripStart) == [])
        #expect(node.handle(.received(env(.decline, from: mosaico, to: mac, epoch: 4, payload: Payload(reason: "locked")), from: mosaico), at: tripStart) == [.shrug(reason: "locked")])
        // once
        #expect(node.handle(.received(env(.decline, from: mosaico, to: mac, epoch: 4, payload: Payload(reason: "locked")), from: mosaico), at: tripStart) == [])
    }

    // Epochs an addition could overflow on are dropped.
    @Test func outOfRangeEpochsAreDropped() {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = node.handle(.connected(phone), at: tripStart)
        #expect(node.handle(.received(env(.statusReply, from: phone, to: mac, epoch: Int.max, payload: Payload(held: .owned, inTrip: false)), from: phone), at: tripStart) == [])
        #expect(node.handle(.received(env(.status, from: phone, to: mac, epoch: -1), from: phone), at: tripStart) == [])
        #expect(node.record?.isOwned == true)
    }

    // P7: replies only to our own asks; trip messages only from the session's peer.
    @Test func unaskedRepliesAndStrangersAreIgnored() {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        let reply = env(.statusReply, from: phone, to: mac, epoch: 9, payload: Payload(held: .owned, inTrip: false))
        #expect(node.handle(.received(reply, from: phone), at: tripStart) == [])   // never asked
        #expect(node.record?.isOwned == true)
        _ = node.handle(.connected(phone), at: tripStart)
        // more than a minute later the ask has expired
        #expect(node.handle(.received(reply, from: phone), at: tripStart.addingTimeInterval(61)) == [])
        #expect(node.record?.isOwned == true)
        _ = node.handle(.connected(phone), at: tripStart.addingTimeInterval(70))
        #expect(!node.handle(.received(reply, from: phone), at: tripStart.addingTimeInterval(71)).isEmpty)

        // a commit or abort from a device that isn't in the trip does nothing
        let st = frogg(epoch: 2, owner: phone)
        var recv = TravelNode(me: phone, record: nil)
        _ = recv.handle(.received(env(.offer, from: mac, to: phone, epoch: 1, payload: Payload(species: "frogg", name: "Frogg")), from: mac), at: tripStart)
        _ = recv.handle(.received(env(.transfer, from: mac, to: phone, epoch: 2, payload: Payload(state: st)), from: mac), at: tripStart)
        #expect(recv.handle(.received(env(.commit, from: mosaico, to: phone, epoch: 2), from: mosaico), at: tripStart) == [])
        #expect(recv.handle(.received(env(.abort, from: mosaico, to: phone, epoch: 2), from: mosaico), at: tripStart) == [])
        guard case .pendingArrival? = recv.record else { Issue.record("pending lost"); return }
    }

    // P10: the same device under another name is the same device.
    @Test func devicesCompareById() {
        let renamed = DeviceRef(deviceId: phone.deviceId, deviceName: "Phone (renamed)")
        var sim = TravelSim()
        sim.input(mac, .send(to: phone))
        sim.step()   // offer → phone
        // the accept arrives labelled with the phone's new name
        let accept = sim.wire.removeFirst()
        var dec = Framing.Decoder()
        let e = try! dec.feed(accept.frame)[0]
        sim.input(mac, .received(e, from: renamed))
        var d2 = Framing.Decoder()
        #expect((try? d2.feedOne(sim.wire.first!.frame))?.type == .transfer)
    }

    // M8: a transfer of a species this device can't show is refused.
    @Test func transferOfUnknownSpeciesIsRefused() {
        var recv = TravelNode(me: phone, record: nil)
        _ = recv.handle(.received(env(.offer, from: mac, to: phone, epoch: 1, payload: Payload(species: "frogg", name: "Frogg")), from: mac), at: tripStart)
        var st = frogg(epoch: 2, owner: phone)
        st.species = "dragon"
        let out = sends(recv.handle(.received(env(.transfer, from: mac, to: phone, epoch: 2, payload: Payload(state: st)), from: mac), at: tripStart))
        #expect(out.map(\.type) == [.abort] && out.first?.payload.reason == "unsupportedSpecies")
        #expect(recv.record == nil)
    }

    // P8 support: a node can be put back to what's on disk, aborting its trip.
    @Test func abandonAbortsTheTripAndReloads() {
        var node = TravelNode(me: mac, record: .owned(frogg(epoch: 4)))
        _ = node.handle(.send(to: phone), at: tripStart)
        let out = node.abandon(reload: .owned(frogg(epoch: 4)), reason: "saveFailed", at: tripStart)
        #expect(sends(out).map(\.type) == [.abort] && sends(out).first?.payload.reason == "saveFailed")
        #expect(!node.inTrip && node.record?.isOwned == true)
    }
}

extension Framing.Decoder {
    mutating func feedOne(_ d: Data) throws -> Envelope? { try feed(d).first }
}
