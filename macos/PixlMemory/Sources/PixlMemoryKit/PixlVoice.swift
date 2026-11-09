import Foundation
import PixlzCore

/// How a Pixl talks in its own chatter (greetings, grumbles, what it's up to). Functional
/// messages ("No internet", "Copied") don't go through here: they always read plainly.
public enum PixlVoice {
    /// Boo is shy: just ellipses.
    public static let ellipses = ["…", "…?", "……", "…!", "· · ·", "…  …"]

    /// `text` in this Pixl's voice: as is, or an ellipsis if it's shy.
    public static func chatter(_ text: String, ui: PixlUI?) -> String {
        ui?.shy == true ? ellipses.randomElement()! : text
    }

    /// What it's up to, like a loading word: "Weaving…", "Judging you softly…".
    public static func doing(ui: PixlUI?) -> String {
        guard ui?.shy != true, let s = ui?.status?.randomElement() else { return ellipses.randomElement()! }
        return s.prefix(1).uppercased() + s.dropFirst() + "…"
    }

    /// The poke grumble, a different one each time: "Hey! Nox is busy loafing."
    public static func busy(name: String, ui: PixlUI?, species: String) -> String {
        if ui?.shy == true { return ellipses.randomElement()! }
        if let s = ui?.status?.randomElement() {
            // "being …" reads after "busy"; plain verbs ("weaving", "loafing") too
            return "Hey! \(name) is busy \(s)."
        }
        return PixlSkins.busyLineSync(name: name, busy: ui?.busy, species: species)
    }
}
