import Foundation
import Synchronization

/// What this device knows about its Pixl (SPEC §10.2).
public enum StoredPet: Equatable, Sendable {
    /// This device has the Pixl. Only then is it drawn.
    case owned(PetState)
    /// Received in a trip, waiting for `commit` (SPEC §10.4). Not drawn. `from` is the sender;
    /// only its status replies settle the arrival (nil in files written before it was kept).
    case pendingArrival(PetState, from: DeviceRef?)
    /// The Pixl is on another device. `tombstone` is the last full state, kept 7 days as the safety copy.
    /// `ownerId` is the holder's device id (nil in files written before it was kept).
    case away(petId: UUID, epoch: Int, ownerName: String, ownerId: String?, tombstone: PetState?)

    public static let tombstoneLifetime: TimeInterval = 7 * 24 * 3600

    public var petId: UUID {
        switch self {
        case .owned(let s), .pendingArrival(let s, _): s.petId
        case .away(let id, _, _, _, _): id
        }
    }

    public var epoch: Int {
        switch self {
        case .owned(let s), .pendingArrival(let s, _): s.epoch
        case .away(_, let e, _, _, _): e
        }
    }

    /// A full copy of the Pixl held here, in any form.
    public var completeCopy: PetState? {
        switch self {
        case .owned(let s), .pendingArrival(let s, _): s
        case .away(_, _, _, _, let t): t
        }
    }

    public var isOwned: Bool { if case .owned = self { true } else { false } }

    /// Where the Pixl is when it's away: the holder (id may be empty for old files).
    public var holder: DeviceRef? {
        if case .away(_, _, let name, let id, _) = self { return DeviceRef(deviceId: id ?? "", deviceName: name) }
        return nil
    }

    /// Drops a tombstone older than 7 days.
    public func pruned(at now: Date) -> StoredPet {
        if case .away(let id, let e, let name, let oid, let t?) = self, now.timeIntervalSince(t.savedAt) > Self.tombstoneLifetime {
            return .away(petId: id, epoch: e, ownerName: name, ownerId: oid, tombstone: nil)
        }
        return self
    }
}

extension StoredPet: Codable {
    private enum CodingKeys: String, CodingKey { case kind, state, from, petId, epoch, ownerName, ownerId, tombstone }
    private enum Kind: String, Codable { case owned, pendingArrival, away }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .owned: self = .owned(try c.decode(PetState.self, forKey: .state))
        case .pendingArrival:
            self = .pendingArrival(try c.decode(PetState.self, forKey: .state), from: try c.decodeIfPresent(DeviceRef.self, forKey: .from))
        case .away:
            self = .away(
                petId: try c.decode(UUID.self, forKey: .petId), epoch: try c.decode(Int.self, forKey: .epoch),
                ownerName: try c.decode(String.self, forKey: .ownerName),
                ownerId: try c.decodeIfPresent(String.self, forKey: .ownerId),
                tombstone: try c.decodeIfPresent(PetState.self, forKey: .tombstone))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .owned(let s):
            try c.encode(Kind.owned, forKey: .kind)
            try c.encode(s, forKey: .state)
        case .pendingArrival(let s, let from):
            try c.encode(Kind.pendingArrival, forKey: .kind)
            try c.encode(s, forKey: .state)
            try c.encodeIfPresent(from, forKey: .from)
        case .away(let id, let e, let name, let oid, let t):
            try c.encode(Kind.away, forKey: .kind)
            try c.encode(id, forKey: .petId)
            try c.encode(e, forKey: .epoch)
            try c.encode(name, forKey: .ownerName)
            try c.encodeIfPresent(oid, forKey: .ownerId)
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

public enum PetStoreError: Error, Equatable {
    /// The saved Pixl couldn't be read; the file was moved to `keptAs` (nil if it couldn't be moved).
    case unreadable(keptAs: URL?, underlying: String)
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

    /// nil when there's no file. A file that can't be read is moved aside to
    /// `pet.json.corrupt-<unix time>` and `PetStoreError.unreadable` is thrown.
    public func load() throws -> StoredPet? {
        try lock.withLock { _ in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try PetState.decoder.decode(StoredPet.self, from: Data(contentsOf: url))
            } catch {
                let aside = url.deletingLastPathComponent()
                    .appendingPathComponent("pet.json.corrupt-\(Int(Date().timeIntervalSince1970))")
                let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
                throw PetStoreError.unreadable(keptAs: moved ? aside : nil, underlying: "\(error)")
            }
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
