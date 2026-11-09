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
    /// How the Pixl's menus and bubbles look and talk (C8). Optional: older manifests lack it.
    public var ui: PixlUI?

    public static func decode(_ data: Data) throws -> PixlManifest {
        try JSONDecoder().decode(PixlManifest.self, from: data)
    }

    public static func load(from url: URL) throws -> PixlManifest {
        try decode(Data(contentsOf: url))
    }
}

/// Per-Pixl character for the bubble menus and cards (design C8). Data, not code: a new Pixl
/// brings its own accent, menu face and voice in `pixl.json`.
public struct PixlUI: Codable, Equatable, Sendable {
    /// The Pixl's token accent (hex), used for focus rings and highlights.
    public var accent: String
    /// The emotion frame shown while the bubble menu is open.
    public var menuFace: String
    /// Liquid Glass body (the ghost). Frogg is pixels.
    public var glassBody: Bool
    /// Name of the signature move ("Do your thing").
    public var signature: String
    /// Placeholder in the Ask field.
    public var askPlaceholder: String
    /// One line of character for the Ask prompt.
    public var personality: String
    /// The design's note on the Pixl's menu detail (C10), e.g. "Lily-pad notch, top edge".
    public var detail: String?
    /// What it says it's busy with when poked too often: "being ghastly" → "Hey! Boo is busy being ghastly."
    public var busy: String?
    /// Little things it's up to, in its voice ("weaving", "loafing"): shown as "Weaving…" now and
    /// then, and in the poke grumble. Like a loading word, but a mood.
    public var status: [String]?
    /// Shy Pixls (Boo) only ever say ellipses in chatter. Functional messages still read normally.
    public var shy: Bool?
    /// Its voice: the only words that go in its speech bubbles, by event (greet, happy, curious,
    /// annoyed, startled, sleepy, sad, idle). E.g. Frogg: "ribbit", "rrbt?", "RIBBIT!".
    public var sounds: [String: [String]]?
    /// How its status refers to it by default: he, she, they, it or name (Settings can change it).
    public var pronoun: String?
    /// The one pixel detail its menus and bubbles carry (C10 per-pet theming).
    public var decal: PixlDecal?
    /// How the option bubbles hang from the Pixl: "silk" (threads, the spider), "wisp" (a
    /// dithered trail, the ghost), or nil (they just puff out).
    public var menuStyle: String?
    /// Mischief ▸ Catch: what pops up to be caught ("fly", "yarn", "ball", "sock") and its name.
    public var game: PixlGame?

    public init(accent: String, menuFace: String, glassBody: Bool, signature: String, askPlaceholder: String, personality: String,
                detail: String? = nil, decal: PixlDecal? = nil) {
        self.accent = accent; self.menuFace = menuFace; self.glassBody = glassBody
        self.signature = signature; self.askPlaceholder = askPlaceholder; self.personality = personality
        self.detail = detail; self.decal = decal
    }
}

/// A tiny pixel grid drawn on the edge of the Pixl's surfaces (C10). Letters: k = outline,
/// f = surface fill, a/b/s = colours from `colors`, "." = transparent. `pos` says which edges
/// it sits on and how far (design points; negative = sticking out past the edge).
public struct PixlDecal: Codable, Equatable, Sendable {
    public var grid: [String]
    public var colors: [String: String]
    public var pos: [String: Double]
    public init(grid: [String], colors: [String: String], pos: [String: Double]) { self.grid = grid; self.colors = colors; self.pos = pos }
}

public struct PixlGame: Codable, Equatable, Sendable {
    public var name: String
    public var target: String
    public init(name: String, target: String) { self.name = name; self.target = target }
}
