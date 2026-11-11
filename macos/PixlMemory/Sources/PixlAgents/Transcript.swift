import Foundation

/// The readable part of a Claude Code session's transcript (the JSONL file a hook names in
/// `transcript_path`): your prompts, Claude's replies, and one line per tool it ran. Thinking,
/// tool results, subagents and bookkeeping entries are left out.
public struct ChatLine: Sendable, Equatable {
    public enum Role: String, Sendable { case you, claude, tool }
    public var role: Role
    public var text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

public enum Transcript {
    /// Only the end of a long transcript is read.
    public static let tailBytes = 400_000

    /// The session's title (Claude Code writes one) and its last `limit` lines, oldest first.
    public static func read(_ url: URL, limit: Int = 30) -> (title: String?, lines: [ChatLine]) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, []) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }   // a cut first line
        return parse(text, limit: limit)
    }

    public static func parse(_ jsonl: String, limit: Int = 30) -> (title: String?, lines: [ChatLine]) {
        var title: String?
        var lines: [ChatLine] = []
        for raw in jsonl.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            if type == "ai-title", let t = o["aiTitle"] as? String { title = t; continue }
            if o["isSidechain"] as? Bool == true { continue }
            guard type == "user" || type == "assistant", let m = o["message"] as? [String: Any] else { continue }
            if let s = m["content"] as? String {
                if type == "user", !s.hasPrefix("<") { lines.append(ChatLine(role: .you, text: clean(s))) }
                continue
            }
            for item in m["content"] as? [[String: Any]] ?? [] {
                switch (type, item["type"] as? String) {
                case ("user", "text"?):
                    if let s = item["text"] as? String, !s.hasPrefix("<") { lines.append(ChatLine(role: .you, text: clean(s))) }
                case ("assistant", "text"?):
                    if let s = item["text"] as? String, !s.isEmpty { lines.append(ChatLine(role: .claude, text: clean(s))) }
                case ("assistant", "tool_use"?):
                    var input: [String: String] = [:]
                    for (k, v) in item["input"] as? [String: Any] ?? [:] {
                        if let s = v as? String { input[k] = s } else if let n = v as? NSNumber { input[k] = n.stringValue }
                    }
                    lines.append(ChatLine(role: .tool, text: AgentHub.describe(tool: item["name"] as? String ?? "a tool", input: input, present: false)))
                default:
                    break
                }
            }
        }
        return (title, Array(lines.suffix(limit)))
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
