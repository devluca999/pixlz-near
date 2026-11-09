import Foundation

/// Per-device settings (SPEC §10.1: not part of PetState). Stored in UserDefaults.
public struct PixlSettings: Codable, Equatable, Sendable {
    /// The current Pixl's name (what's shown). Each Pixl keeps its own: see `names`.
    public var name = "Frogg"
    /// Names you gave each Pixl, by skin id (only the ones you changed). Optional so older
    /// settings still load.
    public var names: [String: String]?
    public var scale: Double = 2      // 1× to 6× in half steps (PixlScale); drag a corner or pick a preset
    public var perchOnWindows = true  // off: Frogg stays on the ground
    public var hideInFullscreen = true
    public var mischief = "normal"    // chill | normal | chaos (stored; mischief acts aren't built yet)
    public var distractingApps: [String] = []  // focus guardian nudges when one of these is activated
    /// Which Pixl (assets/<id>). Optional so settings saved before skins existed still load.
    public var skin: String?
    public var skinID: String { skin ?? "frogg" }
    /// Behavior: "calm" (stays with you; the default) or "roam" (explores on its own).
    public var behavior: String?
    public var roams: Bool {
        get { behavior == "roam" }
        set { behavior = newValue ? "roam" : "calm" }
    }

    public init() {}

    /// Remember `name` as the current Pixl's own (or forget it when it's back to the default).
    public mutating func rememberName(default d: String) {
        var n = names ?? [:]
        n[skinID] = name == d ? nil : name
        names = n.isEmpty ? nil : n
    }

    /// Switch to Pixl `id`: its own name if you gave it one, else its default.
    public mutating func switchSkin(to id: String, default d: String) {
        skin = id
        name = names?[id] ?? d
    }

    public static let key = "PixlMemory.settings"

    @MainActor public static func load(_ defaults: UserDefaults = .standard) -> PixlSettings {
        guard let data = defaults.data(forKey: key), var s = try? JSONDecoder().decode(PixlSettings.self, from: data)
        else { return PixlSettings() }
        s.scale = PixlScale.snap(s.scale)
        let fallback = (PixlSkins.skin(s.skinID) ?? PixlSkins.current).manifest.name
        if let own = s.names?[s.skinID] { s.name = own }   // each Pixl's own name wins
        s.name = s.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : String(s.name.prefix(24))
        // settings from before per-Pixl names: a custom name belongs to the Pixl it was saved with
        if s.names == nil, !PixlSkins.all.contains(where: { $0.manifest.name == s.name }) { s.rememberName(default: fallback) }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// What the mini menu shows about the service and the wallet.
public struct ServiceStatus: Sendable, Equatable {
    public var service: String
    public var model: String?
    public var wallet: String?
    public var walletReady: Bool
    public var lastVerdict: String?

    public init(service: String, model: String? = nil, wallet: String? = nil, walletReady: Bool = false, lastVerdict: String? = nil) {
        self.service = service; self.model = model; self.wallet = wallet; self.walletReady = walletReady; self.lastVerdict = lastVerdict
    }
}
