import Foundation
import PixlzCore

// A Pixl's text goes through exactly one of three channels (SPEC §11.6):
//   Voice:   speech bubbles hold only the species' own sounds ("ribbit", "mrrp?", "tk tk").
//   Status:  third-person narration of what it's doing ("Frogg is practicing his croak"), in the
//            Settings header, a hover tooltip and the menu bar. Never in a bubble.
//   Notices: anything functional, in plain English, on a small notice card with an icon.

/// What prompted a sound: picks from the Pixl's sound set for that event.
public enum SoundEvent: String, CaseIterable, Sendable {
    case greet, happy, curious, annoyed, startled, sleepy, sad, idle
    case alert   // Agent mode: a session needs you (pixl.json ui.sounds.alert)
}

/// Picks voice lines from a Pixl's sounds (pixl.json `ui.sounds`), never the same twice in a row.
public struct VoicePicker: Sendable {
    public private(set) var last: String?
    public init() {}

    /// The Pixl's sounds for `event`, or its idle sounds, or every sound it has.
    public static func sounds(_ event: SoundEvent, ui: PixlUI?) -> [String] {
        let all = ui?.sounds ?? [:]
        if let s = all[event.rawValue], !s.isEmpty { return s }
        if let s = all[SoundEvent.idle.rawValue], !s.isEmpty { return s }
        return all.values.flatMap { $0 }.isEmpty ? ["…"] : all.values.flatMap { $0 }
    }

    /// Every line this Pixl may ever say.
    public static func allSounds(ui: PixlUI?) -> Set<String> {
        Set((ui?.sounds ?? [:]).values.flatMap { $0 })
    }

    public mutating func pick(_ event: SoundEvent, ui: PixlUI?) -> String {
        var options = Self.sounds(event, ui: ui).filter { $0 != last }
        if options.isEmpty {   // only one line for this event: borrow another of its sounds
            options = Self.allSounds(ui: ui).filter { $0 != last }.sorted()
        }
        let line = options.randomElement() ?? last ?? "…"
        last = line
        return line
    }
}

/// What the Pixl is up to, for its status line.
public enum PixlActivity: Equatable, Sendable {
    case idle(Int)              // one of its own status lines (an index, so it changes now and then)
    case resting                // you're typing; it keeps still
    case drowsy, asleep, deepSleep, waking
    case outing(String)         // a Roam outing, by name ("pond", "crawl", "glance"…)
    case playing(String)        // a game, by name
    case thinking               // Polish or Ask in progress
    case visiting(String)       // on another device
    case focus                  // a Focus session
    case resizing, hidden
}

public enum PixlStatus {
    /// "Frogg is practicing a croak." (No pronouns: lines are written so they never need one.)
    public static func line(name: String, activity: PixlActivity, ui: PixlUI?) -> String {
        let phrase: String
        switch activity {
        case .idle(let i):
            let lines = ui?.status ?? []
            phrase = lines.isEmpty ? "hanging out" : lines[((i % lines.count) + lines.count) % lines.count]
        case .resting: phrase = "keeping still while you type"
        case .drowsy: phrase = "getting sleepy"
        case .asleep: phrase = "asleep"
        case .deepSleep: phrase = "fast asleep"
        case .waking: phrase = "waking up"
        case .outing(let o): phrase = outingPhrase(o)
        case .playing(let g): phrase = "playing \(g)"
        case .thinking: phrase = "thinking privately"
        case .visiting(let d): phrase = "visiting \(d)"
        case .focus: phrase = "keeping you company while you focus"
        case .resizing: phrase = "getting resized"
        case .hidden: phrase = "hiding"
        }
        return "\(name) is \(phrase)."
    }

    static func outingPhrase(_ o: String) -> String {
        switch o {
        case let s where s.hasPrefix("hop (folder"): "visiting a folder"
        case let s where s.hasPrefix("hop"): "exploring"
        case "walk": "going for a stroll"
        case "stalk": "stalking something"
        case "drift": "drifting about"
        case "glance": "reading along"
        case "nap": "napping"
        case "pond": "taking a dip in the pond"
        case let s where s.hasPrefix("crawl"): "climbing the walls"
        case "climb and move": "spinning a new thread"
        default: "exploring"
        }
    }
}

/// A functional message: plain English on a small notice card, with an icon. Optionally led by
/// one voice line (the Pixl's own sound) when shown.
public struct Notice: Equatable, Sendable {
    public enum Kind: String, Sendable { case info, done, warn, error }
    public let kind: Kind
    public let text: String
    /// Seconds on screen; nil stays until replaced (a "working…" notice).
    public let seconds: TimeInterval?

    public init(_ kind: Kind, _ text: String, seconds: TimeInterval? = 3) {
        self.kind = kind; self.text = text; self.seconds = seconds
    }

    public var icon: String {
        switch kind {
        case .info: "info"
        case .done: "check"
        case .warn, .error: "warn"
        }
    }
}

/// Every functional message the app shows, in one place.
public extension Notice {
    // memory and notes
    static let answerSaved = Notice(.done, "Saved the answer to Answers.", seconds: 2)
    static let answerNotSaved = Notice(.error, "Couldn't save the answer. Is the memory service running?")
    static func noteSaved(_ folder: String) -> Notice { Notice(.done, "Saved to \(folder).", seconds: 2) }
    static let noteNotSaved = Notice(.error, "Couldn't save the note. Is the memory service running?")
    // devices and apps
    static let noDevices = Notice(.info, "No other device nearby. Open Pixl Memory on another device on the same Wi-Fi.")
    static let noOtherApp = Notice(.info, "No other app is open to hand this to.", seconds: 2)
    static let localNetworkOff = Notice(.warn, "To see your other devices, turn on Pixl Memory in System Settings → Privacy & Security → Local Network.", seconds: 5)
    static let tripDeclined = Notice(.info, "The other device said not now.")
    static func tripFailed(_ why: String) -> Notice { Notice(.error, "Couldn't travel there (\(why)). Staying here.") }
    static func notHere(_ name: String) -> Notice { Notice(.info, "\(name) isn't on this device right now.", seconds: 2) }
    static func travelling(_ name: String, to device: String) -> Notice { Notice(.info, "\(name) is heading to \(device)…", seconds: 8) }
    static func left(_ name: String, to device: String) -> Notice { Notice(.done, "\(name) is on \(device) now.", seconds: 2) }
    static func arrived(_ name: String) -> Notice { Notice(.done, "\(name) came over from another device.") }
    static func ownerAway(_ owner: String) -> Notice { Notice(.info, "\(owner) isn't nearby right now.") }
    static func callingFrom(_ owner: String) -> Notice { Notice(.info, "Calling from \(owner)…") }
    // permissions and the service
    static let accessibilityNeeded = Notice(.warn, "Pixl Memory needs Accessibility to see your window and selected text. Turn it on in System Settings → Privacy & Security → Accessibility.", seconds: 8)
    static func serviceProblem(_ why: String) -> Notice { Notice(.error, sentence("The memory service isn't working: \(why)"), seconds: 6) }
    static func error(_ text: String) -> Notice { Notice(.error, sentence(text), seconds: 6) }

    /// Ends `text` like a sentence.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".…!?".contains(last) else { return text }
        return text + "."
    }
    static func error(_ e: MemoryError) -> Notice { Notice(.error, sentence(e.bubble), seconds: 6) }
    // polish, ask, hand-off
    static let checkingEnclave = Notice(.info, "Checking the enclave before sending…", seconds: nil)
    static let thinking = Notice(.info, "Thinking privately in the enclave…", seconds: nil)
    static func polished(_ verdict: String) -> Notice { Notice(.done, verdict, seconds: 5) }
    static let replaced = Notice(.done, "Replaced your text. Saved as accepted.")
    static let couldntWrite = Notice(.warn, "Couldn't write there. It's copied: paste with ⌘V.", seconds: 4)
    static let copied = Notice(.done, "Copied.", seconds: 1.5)
    static let droppedIn = Notice(.done, "Dropped in. Saved as accepted.")
    static func handingOff(_ app: String) -> Notice { Notice(.info, "Taking it to \(app)…", seconds: 2) }
    static func handedOff(_ app: String) -> Notice { Notice(.done, "It's in \(app). Read it, then send it yourself.") }
    static func pasteIn(_ app: String) -> Notice { Notice(.warn, "Click where it should go in \(app), then press ⌘V. It's copied.", seconds: 4) }
    // wallet
    static func walletPaused(_ paused: Bool, perWeek: String) -> Notice {
        Notice(.done, paused ? "Wallet paused. Nothing will be spent." : "Wallet back on, up to \(perWeek) NEAR a week.")
    }
    static func walletLimit(_ text: String) -> Notice { Notice(.done, text) }
    static func walletError(_ text: String) -> Notice { Notice(.error, sentence(text)) }
    /// Agent mode (SPEC §16): connected, disconnected, or why not.
    static func agents(_ text: String) -> Notice { Notice(.done, text) }
    static func agentsError(_ text: String) -> Notice { Notice(.error, sentence(text)) }
    // focus
    static func focusStarted(_ minutes: Int, name: String) -> Notice { Notice(.info, "Focus for \(minutes) min. \(name) will sit still.") }
    static func focusLeft(_ minutes: Int) -> Notice { Notice(.info, "Focus: \(minutes) min left.", seconds: 2) }
    static let focusDone = Notice(.done, "Focus session done.", seconds: 4)
    static let focusStopped = Notice(.info, "Focus stopped.", seconds: 2)
    static func distracted(_ app: String) -> Notice { Notice(.info, "\(app)? Back to focus soon.") }
    // app and behavior
    static let loginOn = Notice(.done, "Pixl Memory will open when you log in.")
    static let loginOff = Notice(.done, "Pixl Memory won't open at login.")
    static let loginNeedsApproval = Notice(.warn, "Allow Pixl Memory in System Settings → General → Login Items.", seconds: 4)
    static let paused = Notice(.info, "Paused.", seconds: 1.5)
    static func roamOn(_ name: String) -> Notice { Notice(.info, "Roam is on: \(name) explores on its own. Poke it to make it sit still.") }
    static func calmOn(_ name: String) -> Notice { Notice(.info, "Calm: \(name) stays with you.", seconds: 2) }
    static func sittingStill(_ name: String) -> Notice { Notice(.info, "\(name) will sit still for 3 minutes.") }
    // games
    static func gameStart(_ game: String) -> Notice { Notice(.info, "\(game): click them before they're gone.", seconds: 2) }
    static func gameScore(_ score: Int, _ thing: String, best: Int, newBest: Bool) -> Notice {
        Notice(.done, newBest ? "\(score) \(thing). A new best." : "\(score) \(thing). Best: \(best).", seconds: 3.5)
    }
    static let gameEnded = Notice(.info, "Game over.", seconds: 1.5)
    /// The end of a C16 game: "Survived 1:12 · 3 bonks · best 1:30".
    static func gameResult(_ line: String) -> Notice { Notice(.info, line, seconds: 3.5) }
    static func laserStart(_ game: String, name: String) -> Notice { Notice(.info, "\(game): keep the dot away from \(name).", seconds: 2.2) }
    static func laserScore(_ catches: Int, name: String, record: Bool) -> Notice {
        Notice(.done, catches == 0 ? "\(name) never caught the dot." : "\(name) caught the dot \(catches) time\(catches == 1 ? "" : "s").\(record ? " A record." : "")", seconds: 3.5)
    }

    /// One of each, for tests and the storyboard.
    static func catalog(name: String = "Frogg") -> [Notice] {
        [answerSaved, answerNotSaved, noteSaved("Research"), noteNotSaved, noDevices, noOtherApp, localNetworkOff, tripDeclined,
         tripFailed("timeout"), notHere(name), travelling(name, to: "Laptop"), left(name, to: "Laptop"), arrived(name),
         ownerAway("Studio Mac"), callingFrom("Studio Mac"), accessibilityNeeded, serviceProblem("not running"),
         error(.upstream("NEAR AI hiccup")), checkingEnclave, thinking, polished("Verified in TEE · 17/17"), replaced, couldntWrite,
         copied, droppedIn, handingOff("Claude"), handedOff("Claude"), pasteIn("Claude"), walletPaused(true, perWeek: "0.25"),
         walletPaused(false, perWeek: "0.25"), walletLimit("Weekly limit set to 0.25 NEAR."), walletError("Couldn't change the limit."),
         focusStarted(25, name: name), focusLeft(12), focusDone, focusStopped, distracted("Safari"), loginOn, loginOff,
         loginNeedsApproval, paused, roamOn(name), calmOn(name), sittingStill(name), gameStart("Fly snap"),
         gameScore(7, "flies", best: 9, newBest: false), gameEnded, laserStart("Laser chase", name: name),
         laserScore(3, name: name, record: true)]
    }
}

/// Legacy helpers kept for the poke grumble and Roam chatter: they now return sounds and status.
public enum PixlVoice {
    /// Boo is shy: just ellipses (its sounds are dots and "boo").
    public static let ellipses = ["…", "…?", "……", "…!", "· · ·", "…  …"]
}
