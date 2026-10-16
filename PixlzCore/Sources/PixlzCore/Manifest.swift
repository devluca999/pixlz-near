import Foundation

/// The nine behavior slots (SPEC §4.1). Raw values are the sprite file names.
public enum Slot: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case idle, move, rest, poke, grab
    case fileRide = "file_ride"
    case perch, signature, mischief
}

/// The six emotions (SPEC §5). Raw values are the file names under `emotions/`.
public enum Emotion: String, Codable, CaseIterable, Sendable {
    case happy, annoyed, sleepy, startled, curious, proud
}

public enum Movement: String, Codable, Sendable {
    case hop, walk, float, climb
}

/// What repeats while a slot stays active (SPEC §3.2).
public enum SlotLoop: String, Codable, Sendable {
    case none, all, middle, last
}

public struct SlotSpec: Codable, Equatable, Sendable {
    /// Ticks each of the 3 frames stays up. 0 = held for as long as physics needs.
    public var holds: [Int]
    public var loop: SlotLoop

    public init(holds: [Int], loop: SlotLoop) {
        self.holds = holds
        self.loop = loop
    }
}

public struct PixelSize: Codable, Equatable, Sendable {
    public var w: Int, h: Int
    public init(w: Int, h: Int) { self.w = w; self.h = h }
}

public struct PixelPoint: Codable, Equatable, Sendable {
    public var x: Int, y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Int, y: Int, w: Int, h: Int
    public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct SpeciesPhysics: Codable, Equatable, Sendable {
    /// apx/s².
    public var gravity: Double
    /// Min/max apex height of a hop, apx.
    public var hopApex: [Double]
    /// Min/max horizontal distance of one hop, apx.
    public var hopDistance: [Double]
    /// apx/s for `walk` species; 0 otherwise.
    public var walkSpeed: Double
}

/// `assets/<pixl>/pixl.json` (SPEC §3.2).
public struct PixlManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var species: String
    public var canvas: PixelSize
    public var anchor: PixelPoint
    public var hitbox: PixelRect
    public var movement: Movement
    public var sticky: Bool
    public var aura: String
    public var physics: SpeciesPhysics
    public var slots: [Slot: SlotSpec]
    public var props: [String: [String]]?

    public static func decode(_ data: Data) throws -> PixlManifest {
        try JSONDecoder().decode(PixlManifest.self, from: data)
    }

    public static func load(from url: URL) throws -> PixlManifest {
        try decode(Data(contentsOf: url))
    }
}
