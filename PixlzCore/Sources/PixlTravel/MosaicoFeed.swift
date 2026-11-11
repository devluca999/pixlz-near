import Foundation
import PixlzCore

/// What the Mac shows on a Mosaico (SPEC §12.1: results only; the Mosaico runs no AI): its latest
/// Ask answers and saved highlights, as one framed JSON message:
/// `{"feed":{"answers":[{"q","a"}…],"highlights":[{"title","text"}…]}}`.
///
/// Text is reduced to printable ASCII (the Mosaico's pixel font) and trimmed so the whole frame
/// fits the Mosaico's receive buffer. Opt-in per device (`defaultsKey`): it carries personal notes
/// over the same unencrypted local link as the trip spike.
public enum MosaicoFeed {
    public static let maxAnswers = 4, maxHighlights = 6
    public static let questionLimit = 70, answerLimit = 360, titleLimit = 60, textLimit = 200
    /// The Mosaico's receive buffer is ~5 KB; stay well under it.
    public static let maxBytes = 4096
    /// Device ids that get the feed (an array of strings).
    public static let defaultsKey = "PixlMemory.feedDevices"

    public static func devices(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    /// The JSON body (unframed). Newest first; trimmed further until it fits `maxBytes`.
    public static func body(answers: [(question: String, answer: String)], highlights: [(title: String, text: String)],
                            from: DeviceRef? = nil) -> Data {
        var a = Array(answers.prefix(maxAnswers)), h = Array(highlights.prefix(maxHighlights))
        while true {
            var json: [String: Any] = ["feed": [
                "answers": a.map { ["q": ascii($0.question, questionLimit), "a": ascii($0.answer, answerLimit)] },
                "highlights": h.map { ["title": ascii($0.title, titleLimit), "text": ascii($0.text, textLimit)] },
            ]]
            if let from {   // who it's from, as an envelope says it (the feed may be the first frame)
                json["from"] = from.deviceId
                json["fromName"] = from.deviceName
            }
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            if data.count <= maxBytes || (a.isEmpty && h.isEmpty) { return data }
            if h.count >= a.count, !h.isEmpty { h.removeLast() } else { a.removeLast() }
        }
    }

    /// Printable ASCII, single spaces, at most `limit` characters (an ellipsis when cut).
    public static func ascii(_ text: String, _ limit: Int) -> String {
        let swaps: [Character: String] = ["’": "'", "‘": "'", "“": "\"", "”": "\"", "—": "-", "–": "-",
                                          "…": "...", "•": "-", "→": "->", "·": "-", "\u{00A0}": " "]
        var out = ""
        for ch in text {
            if let s = swaps[ch] { out += s; continue }
            if ch.isWhitespace { out += " "; continue }
            if let a = ch.asciiValue, a >= 32, a < 127 { out.append(ch); continue }
            let folded = String(ch).folding(options: .diacriticInsensitive, locale: .init(identifier: "en"))
            if let f = folded.first, let a = f.asciiValue, a >= 32, a < 127 { out.append(f) }
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // drop light markdown the model uses (**bold**, `code`) — the pixel font shows it literally
        out = out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if out.count > limit { out = String(out.prefix(max(0, limit - 3))).trimmingCharacters(in: .whitespaces) + "..." }
        return out
    }
}
