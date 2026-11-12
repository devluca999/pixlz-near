import Foundation

/// Reads the tail of a Claude Code session's transcript (`~/.claude/projects/<project>/<id>.jsonl`)
/// for the chat panel. Read only, on this Mac only: nothing here (or anywhere it's shown) goes
/// over the network. The line format is internal to Claude Code and changes between versions,
/// so anything that doesn't parse is skipped, and nothing here throws.
public enum TranscriptReader {
    public struct Entry: Sendable, Equatable {
        public enum Role: String, Sendable { case user, assistant }
        public var role: Role
        public var text: String
        public var time: Date?
    }

    public static let tailBytes = 256 * 1024

    /// The transcript file, only if the path resolves (symlinks and all) inside
    /// `~/.claude/projects/` and ends in `.jsonl`. Anything else is refused.
    public static func validated(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard !path.isEmpty, path.hasPrefix("/") || path.hasPrefix("~") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let file = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let root = home.appending(path: ".claude/projects").standardizedFileURL.resolvingSymlinksInPath()
        guard file.pathExtension == "jsonl" else { return nil }
        let r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(r) else { return nil }
        return file
    }

    /// The last messages of a transcript (up to the last 256 KB of the file).
    public static func tail(_ url: URL, maxBytes: Int = tailBytes) -> [Entry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        return parse(data, partialFirstLine: start > 0)
    }

    /// One entry per user or assistant message; tool calls collapse to one line each.
    public static func parse(_ data: Data, partialFirstLine: Bool = false) -> [Entry] {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if partialFirstLine, !lines.isEmpty { lines.removeFirst() }   // cut mid-line by the tail
        var out: [Entry] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for line in lines {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let type = o["type"] as? String
            guard type == "user" || type == "assistant", let msg = o["message"] as? [String: Any] else { continue }
            if o["isMeta"] as? Bool == true { continue }
            let role: Entry.Role = (msg["role"] as? String ?? type) == "assistant" ? .assistant : .user
            let time = (o["timestamp"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            var parts: [String] = []
            if let text = msg["content"] as? String {
                parts.append(text)
            } else if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text": if let t = b["text"] as? String { parts.append(t) }
                    case "tool_use":
                        var input: [String: String] = [:]
                        for (k, v) in b["input"] as? [String: Any] ?? [:] {
                            if let s = v as? String { input[k] = s } else if let n = v as? NSNumber { input[k] = n.stringValue }
                        }
                        parts.append("→ " + AgentHub.describe(tool: b["name"] as? String ?? "a tool", input: input, present: false))
                    default: break   // tool results, thinking, images: not shown
                    }
                }
            }
            let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out.append(Entry(role: role, text: text, time: time))
        }
        return out
    }
}
