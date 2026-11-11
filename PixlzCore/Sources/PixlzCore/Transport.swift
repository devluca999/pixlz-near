import CryptoKit
import Foundation

// SPEC §10.3. The platform layer implements `PetTransport` (LocalBonjourTransport on Apple, D9);
// everything here is transport-independent.

public enum EnvelopeType: String, Codable, Sendable, CaseIterable {
    case call, offer, accept, decline, transfer, ack, commit, commitAck, abort, status, statusReply
}

public enum DeclineReason: String, Codable, Sendable {
    case busy, hasOtherPet, unsupportedSpecies, userDeclined
    /// The receiver already holds this very Pixl: two copies; status settles which is newer.
    case alreadyHere
}

/// What a device holds for a pet, as reported in `statusReply`.
public enum HeldKind: String, Codable, Sendable {
    case owned, pending, away, none
}

/// The union of every envelope type's payload; each type uses a few fields.
public struct Payload: Codable, Equatable, Sendable {
    /// offer
    public var species: String?
    public var name: String?
    /// decline, abort
    public var reason: String?
    /// Any message: the sender's device name, for a receiver that can't browse for it
    /// (its Local Network permission isn't granted yet). Optional, so older peers still parse.
    public var fromName: String?
    /// transfer
    public var state: PetState?
    /// ack
    public var checksum: String?
    /// statusReply
    public var held: HeldKind?
    public var inTrip: Bool?

    public init(species: String? = nil, name: String? = nil, reason: String? = nil, state: PetState? = nil,
                checksum: String? = nil, held: HeldKind? = nil, inTrip: Bool? = nil) {
        self.species = species
        self.name = name
        self.reason = reason
        self.state = state
        self.checksum = checksum
        self.held = held
        self.inTrip = inTrip
    }
}

public struct Envelope: Codable, Equatable, Sendable {
    public static let version = 1

    public var v: Int = Envelope.version
    public var msgId: UUID
    public var petId: UUID
    public var from: String
    public var to: String
    public var type: EnvelopeType
    public var epoch: Int
    public var payload: Payload
    public var sentAt: Date

    public init(msgId: UUID = UUID(), petId: UUID, from: String, to: String, type: EnvelopeType, epoch: Int,
                payload: Payload = Payload(), sentAt: Date) {
        self.msgId = msgId
        self.petId = petId
        self.from = from
        self.to = to
        self.type = type
        self.epoch = epoch
        self.payload = payload
        self.sentAt = sentAt
    }
}

/// A transport between paired devices (SPEC §10.3).
public protocol PetTransport: Sendable {
    /// Paired devices currently reachable.
    var peers: AsyncStream<[DeviceRef]> { get }
    func send(_ envelope: Envelope, to peer: DeviceRef) async throws
    var incoming: AsyncStream<(Envelope, DeviceRef)> { get }
}

/// Length-prefixed JSON frames: a 4-byte big-endian length, then the envelope's JSON.
public enum Framing {
    public static let maxFrame = 1 << 20

    public enum FramingError: Error, Equatable { case frameTooLarge(Int) }

    public static func encode(_ envelope: Envelope) throws -> Data {
        let body = try PetState.encoder.encode(envelope)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Accumulates bytes from a stream connection and yields whole envelopes.
    public struct Decoder: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func feed(_ bytes: Data) throws -> [Envelope] {
            try frames(bytes).map { try PetState.decoder.decode(Envelope.self, from: $0) }
        }

        /// Whole frame bodies, undecoded (a link may carry other messages beside envelopes).
        public mutating func frames(_ bytes: Data) throws -> [Data] {
            buffer.append(bytes)
            var out: [Data] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
                guard length <= maxFrame else { throw FramingError.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                out.append(Data(buffer.dropFirst(4).prefix(length)))
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return out
        }
    }
}

/// Pairing (SPEC §10.3): the Mac shows a 6-digit code, the user types it on the iPhone, and both
/// derive the same TLS pre-shared key. The platform layer stores it in the Keychain.
public enum Pairing {
    public static func makeCode<R: RandomNumberGenerator>(using rng: inout R) -> String {
        String(format: "%06d", Int.random(in: 0...999_999, using: &rng))
    }

    public static func makeCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return makeCode(using: &rng)
    }

    /// HKDF-SHA256 over the code, salted with both device IDs (sorted, so both sides agree).
    public static func deriveKey(code: String, deviceA: String, deviceB: String) -> SymmetricKey {
        let salt = [deviceA, deviceB].sorted().joined(separator: "|")
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
            salt: Data(salt.utf8), info: Data("pixlz-pairing-v1".utf8), outputByteCount: 32)
    }
}
