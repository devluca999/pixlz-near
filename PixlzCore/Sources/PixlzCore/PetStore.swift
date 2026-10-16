import Foundation
import Synchronization

/// What this device knows about its Pixl (SPEC §10.2).
public enum StoredPet: Equatable, Sendable {
    /// This device has the Pixl. Only then is it drawn.
    case owned(PetState)
    /// Received in a trip, waiting for `commit` (SPEC §10.4). Not drawn.
    case pendingArrival(PetState)
    /// The Pixl is on another device. `tombstone` is the last full state, kept 7 days as the safety copy.
    case away(petId: UUID, epoch: Int, ownerName: String, tombstone: PetState?)

    public static let tombstoneLifetime: TimeInterval = 7 * 24 * 3600

    public var petId: UUID {
        switch self {
        case .owned(let s), .pendingArrival(let s): s.petId
        case .away(let id, _, _, _): id
        }
    }

    public var epoch: Int {
        switch self {
        case .owned(let s), .pendingArrival(let s): s.epoch
        case .away(_, let e, _, _): e
        }
    }

    /// A full copy of the Pixl held here, in any form.
    public var completeCopy: PetState? {
        switch self {
        case .owned(let s), .pendingArrival(let s): s
        case .away(_, _, _, let t): t
        }
    }

    public var isOwned: Bool { if case .owned = self { true } else { false } }

    /// Drops a tombstone older than 7 days.
    public func pruned(at now: Date) -> StoredPet {
        if case .away(let id, let e, let name, let t?) = self, now.timeIntervalSince(t.savedAt) > Self.tombstoneLifetime {
            return .away(petId: id, epoch: e, ownerName: name, tombstone: nil)
        }
        return self
    }
}

extension StoredPet: Codable {
    private enum CodingKeys: String, CodingKey { case kind, state, petId, epoch, ownerName, tombstone }
    private enum Kind: String, Codable { case owned, pendingArrival, away }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .owned: self = .owned(try c.decode(PetState.self, forKey: .state))
        case .pendingArrival: self = .pendingArrival(try c.decode(PetState.self, forKey: .state))
        case .away:
            self = .away(
                petId: try c.decode(UUID.self, forKey: .petId), epoch: try c.decode(Int.self, forKey: .epoch),
                ownerName: try c.decode(String.self, forKey: .ownerName),
                tombstone: try c.decodeIfPresent(PetState.self, forKey: .tombstone))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .owned(let s):
            try c.encode(Kind.owned, forKey: .kind)
            try c.encode(s, forKey: .state)
        case .pendingArrival(let s):
            try c.encode(Kind.pendingArrival, forKey: .kind)
            try c.encode(s, forKey: .state)
        case .away(let id, let e, let name, let t):
            try c.encode(Kind.away, forKey: .kind)
            try c.encode(id, forKey: .petId)
            try c.encode(e, forKey: .epoch)
            try c.encode(name, forKey: .ownerName)
            try c.encodeIfPresent(t, forKey: .tombstone)
        }
    }
}

/// Persists this device's `StoredPet` (SPEC §10.2).
public protocol PetStore: Sendable {
    /// nil = never had a pet on this device.
    func load() throws -> StoredPet?
    /// Atomic.
    func save(_ pet: StoredPet) throws
    /// Every saved value, for the widget and UI.
    var changes: AsyncStream<StoredPet> { get }
}

/// Fans one value out to every `changes` subscriber.
final class ChangeBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<StoredPet>.Continuation]>([:])

    var stream: AsyncStream<StoredPet> {
        AsyncStream { cont in
            let id = UUID()
            continuations.withLock { $0[id] = cont }
            cont.onTermination = { [weak self] _ in self?.continuations.withLock { _ = $0.removeValue(forKey: id) } }
        }
    }

    func send(_ pet: StoredPet) {
        for c in continuations.withLock({ Array($0.values) }) { c.yield(pet) }
    }
}

/// `pet.json` in a directory (the App Group container on Apple platforms). Writes go to a temp file
/// and are renamed into place, so a crash mid-write leaves the old file intact.
public final class FilePetStore: PetStore {
    public let url: URL
    private let broadcaster = ChangeBroadcaster()
    private let lock = Mutex(())

    public init(directory: URL) {
        url = directory.appendingPathComponent("pet.json")
    }

    public func load() throws -> StoredPet? {
        try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try PetState.decoder.decode(StoredPet.self, from: Data(contentsOf: url))
        }
    }

    public func save(_ pet: StoredPet) throws {
        try lock.withLock { _ in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PetState.encoder.encode(pet).write(to: url, options: .atomic)
        }
        broadcaster.send(pet)
    }

    public var changes: AsyncStream<StoredPet> { broadcaster.stream }
}

/// For tests and previews.
public final class InMemoryPetStore: PetStore {
    private let value: Mutex<StoredPet?>
    private let broadcaster = ChangeBroadcaster()

    public init(_ initial: StoredPet? = nil) { value = Mutex(initial) }

    public func load() throws -> StoredPet? { value.withLock { $0 } }

    public func save(_ pet: StoredPet) throws {
        value.withLock { $0 = pet }
        broadcaster.send(pet)
    }

    public var changes: AsyncStream<StoredPet> { broadcaster.stream }
}
