import CryptoKit
import Foundation

/// The device that holds the Pixl.
public struct DeviceRef: Codable, Equatable, Hashable, Sendable {
    public var deviceId: String
    public var deviceName: String

    public init(deviceId: String, deviceName: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

public struct PetStats: Codable, Equatable, Sendable {
    public var pokes = 0, rides = 0, trips = 0, signatures = 0
    public init() {}
}

/// One Pixl's complete state, the same JSON on every platform (SPEC §10.1).
/// Device settings (size, hotkeys, mischief level…) are not in here.
public struct PetState: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int = PetState.currentSchema
    public var petId: UUID
    public var species: String
    public var name: String
    public var createdAt: Date
    public var owner: DeviceRef
    /// +1 on every ownership change, never otherwise (D9).
    public var epoch: Int
    public var needs: Needs
    public var emotion: EmotionState?
    public var stats: PetStats
    public var savedAt: Date

    public init(petId: UUID = UUID(), species: String, name: String, owner: DeviceRef, at now: Date) {
        self.petId = petId
        self.species = species
        self.name = name
        createdAt = now
        self.owner = owner
        epoch = 1
        needs = .fresh(at: now)
        emotion = nil
        stats = PetStats()
        savedAt = now
    }

    // MARK: Canonical encoding

    /// Keys sorted, UTF-8, no whitespace, ISO 8601 dates with milliseconds (SPEC §10.1).
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(PetState.formatDate(date))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = PetState.parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()

    public func canonicalData() throws -> Data { try Self.encoder.encode(self) }

    /// Hex SHA-256 of the canonical encoding. Travel acks carry it (SPEC §10.3).
    public func checksum() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ data: Data) throws -> PetState { try decoder.decode(PetState.self, from: data) }

    // Date formatting by hand: ISO8601DateFormatter isn't Sendable, and this keeps the format exact.
    static func formatDate(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let secs = Double(ms / 1000) + (ms % 1000 < 0 ? -1 : 0)
        let millis = ((ms % 1000) + 1000) % 1000
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date(timeIntervalSince1970: secs))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, Int(millis))
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
