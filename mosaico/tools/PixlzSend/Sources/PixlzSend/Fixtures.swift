import Foundation
import PixlzCore

/// Writes the bytes PixlzCore produces for one trip, so the C module's host tests can check
/// it reads and writes exactly the same thing (`mosaico/pixl_trip/test/fixtures`).
enum Fixtures {
    static let mac = DeviceRef(deviceId: "MAC-0001", deviceName: "Luca’s \"Mac\"")
    static let mosaico = DeviceRef(deviceId: "MOSAICO-0001", deviceName: "Mosaico")
    static let petId = UUID(uuidString: "6F0E2C1A-0000-4000-8000-000000000001")!
    /// 2025-11-10T16:00:00.123Z and a minute later.
    static let t0 = Date(timeIntervalSince1970: 1_762_790_400.123)
    static let t1 = Date(timeIntervalSince1970: 1_762_790_460.456)

    static func write(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func put(_ name: String, _ data: Data) throws { try data.write(to: dir.appendingPathComponent(name)) }
        func body(_ env: Envelope) throws -> Data { try PetState.encoder.encode(env) }

        var pet = PetState(petId: petId, species: "frogg", name: "Frogg", owner: mac, at: t0)
        pet.epoch = 7
        pet.stats.pokes = 41
        pet.stats.trips = 2
        var node = TravelNode(me: mac, record: .owned(pet))

        // Mac → Mosaico: offer, (accept), transfer, (ack), commit.
        guard case .send(let offer, _)? = node.handle(.send(to: mosaico), at: t0).first else { throw Failure("no offer") }
        try put("offer.json", body(offer))

        let accept = Envelope(petId: petId, from: mosaico.deviceId, to: mac.deviceId, type: .accept, epoch: offer.epoch, sentAt: t0)
        guard case .send(let transfer, _)? = node.handle(.received(accept, from: mosaico), at: t0).first,
              let sent = transfer.payload.state else { throw Failure("no transfer") }
        try put("transfer.json", body(transfer))
        try put("transfer.sum", Data(try sent.checksum().utf8))

        let ack = Envelope(petId: petId, from: mosaico.deviceId, to: mac.deviceId, type: .ack, epoch: transfer.epoch,
                           payload: Payload(checksum: try sent.checksum()), sentAt: t0)
        let commit = node.handle(.received(ack, from: mosaico), at: t0).compactMap { o -> Envelope? in
            if case .send(let e, _) = o, e.type == .commit { e } else { nil }
        }.first
        guard let commit else { throw Failure("no commit") }
        try put("commit.json", body(commit))

        // Mosaico → Mac: what the Mac expects the state to be when the Mosaico sends it home at t1.
        var back = sent
        back.epoch += 1
        back.owner = mac
        back.stats.trips += 1
        back.savedAt = t1
        try put("return_state.json", try back.canonicalData())
        try put("return_state.sum", Data(try back.checksum().utf8))
    }

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ s: String) { description = s }
    }
}
