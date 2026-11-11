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

    /// One Claude Code session for the Mosaico's Agents page (SPEC §16.3).
    public struct AgentRow: Sendable {
        public var id, project, doing: String
        public var request: String?      // a waiting request's id
        public var summary, detail: String
        public var answerable: Bool      // Pixlz holds it: Deny on the Mosaico answers it
        public var replyOpen: Bool       // finished and held open for a reply
        public init(id: String, project: String, doing: String, request: String? = nil, summary: String = "",
                    detail: String = "", answerable: Bool = false, replyOpen: Bool = false) {
            self.id = id; self.project = project; self.doing = doing; self.request = request
            self.summary = summary; self.detail = detail; self.answerable = answerable; self.replyOpen = replyOpen
        }
    }
    public static let maxAgents = 6

    /// `{"agents":{"alerts":bool,"sessions":[{id,project,doing,req,summary,detail,answerable}]}}`,
    /// waiting sessions first; trimmed until it fits `maxBytes`.
    public static func agentsBody(_ rows: [AgentRow], alerts: Bool, from: DeviceRef? = nil) -> Data {
        var r = Array(rows.prefix(maxAgents))
        while true {
            var json: [String: Any] = ["agents": [
                "alerts": alerts,
                "sessions": r.map { a -> [String: Any] in
                    var o: [String: Any] = ["id": ascii(a.id, 40), "project": ascii(a.project, 24), "doing": ascii(a.doing, 60)]
                    if a.replyOpen { o["reply"] = true }
                    if let req = a.request {
                        o["req"] = ascii(req, 15)
                        o["summary"] = ascii(a.summary, 60)
                        o["detail"] = ascii(a.detail, 140)
                        o["answerable"] = a.answerable
                    }
                    return o
                },
            ]]
            if let from {
                json["from"] = from.deviceId
                json["fromName"] = from.deviceName
            }
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            if data.count <= maxBytes || r.isEmpty { return data }
            r.removeLast()
        }
    }

    /// The quick replies a paired Mosaico can send (its four bubbles), in order.
    public static let quickReplies = ["Continue", "Yes", "No", "Run the tests"]

    /// A session's chat for the Mosaico's reader: `{"chat":{"id","title","lines":[{"r":"y|c|t","t"}]}}`,
    /// newest last, oldest dropped until it fits `maxBytes`.
    public static func chatBody(id: String, title: String?, lines: [(role: String, text: String)], from: DeviceRef? = nil) -> Data {
        var l = Array(lines.suffix(12))
        while true {
            var json: [String: Any] = ["chat": [
                "id": ascii(id, 40), "title": ascii(title ?? "", 60),
                "lines": l.map { ["r": $0.role, "t": ascii($0.text, 290)] },
            ]]
            if let from { json["from"] = from.deviceId; json["fromName"] = from.deviceName }
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            if data.count <= maxBytes || l.isEmpty { return data }
            l.removeFirst()
        }
    }

    /// `{"agentChat":{"id"}}`: the Mosaico wants that session's chat.
    public static func chatRequest(_ body: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let c = o["agentChat"] as? [String: Any] else { return nil }
        return c["id"] as? String
    }

    /// The Mosaico's answer to a request: `{"agentDecision":{"id","behavior"}}`. Nil otherwise.
    public static func agentDecision(_ body: Data) -> (id: String, behavior: String)? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let d = o["agentDecision"] as? [String: Any], let id = d["id"] as? String, let b = d["behavior"] as? String else { return nil }
        return (id, b)
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
