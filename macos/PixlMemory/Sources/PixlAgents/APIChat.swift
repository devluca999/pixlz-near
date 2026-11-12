import Foundation

/// A chat with Claude through the Anthropic API, paid by an API key (not your Claude account):
/// Agent mode's "Chat with Claude". Swift has no official Anthropic SDK, so this is the
/// Messages API over plain HTTPS.
public enum APIChat {
    /// The cheapest model while we check this works end to end; change it here later.
    public static let model = "claude-haiku-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let version = "2026-10-21"
    static let system = "You are Claude, talking to the user through Pixlz, a small desktop pet on their Mac. Answer plainly and briefly unless they ask for detail."

    /// Key names read, in order. The first is the usual one; the second is how this repo's
    /// .env.local spells it.
    public static let keyNames = ["ANTHROPIC_API_KEY", "AnthopicAPIKEy"]

    /// The key from the environment, else from `.env.local` then `.env` in `dirs`. Never logged.
    public static func apiKey(env: [String: String] = ProcessInfo.processInfo.environment, dirs: [URL]) -> String? {
        for name in keyNames { if let v = env[name]?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v } }
        for dir in dirs {
            for file in [".env.local", ".env"] {
                guard let text = try? String(contentsOf: dir.appending(path: file), encoding: .utf8) else { continue }
                let values = parseEnv(text)
                for name in keyNames { if let v = values[name], !v.isEmpty { return v } }
            }
        }
        return nil
    }

    /// KEY=value lines; quotes and an `export ` prefix are dropped, comments skipped.
    public static func parseEnv(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    // MARK: the conversation

    /// One turn as the API keeps it: the assistant's content blocks go back unchanged
    /// (thinking blocks included), as the API asks.
    public struct Turn: @unchecked Sendable {
        public var role: String
        public var content: Any   // String for your turns, [[String: Any]] for Claude's
        public init(role: String, content: Any) { self.role = role; self.content = content }
    }

    public enum Failure: Error, Equatable {
        case noKey, http(Int, String), refused, unreadable, network(String)
        public var message: String {
            switch self {
            case .noKey: "No Anthropic API key: add ANTHROPIC_API_KEY to .env.local in the repo."
            case .http(401, _): "The Anthropic API key was refused (401). Check it in .env.local."
            case .http(429, _): "The Anthropic API is rate-limiting this key. Try again in a minute."
            case .http(let c, let m): "The Anthropic API said \(c)\(m.isEmpty ? "" : ": \(m)")"
            case .refused: "Claude declined to answer that one."
            case .unreadable: "Couldn't read the Anthropic API's answer."
            case .network(let m): "Couldn't reach the Anthropic API: \(m)"
            }
        }
    }

    public static func body(_ turns: [Turn], maxTokens: Int = 4096) -> [String: Any] {
        ["model": model, "max_tokens": maxTokens, "system": system,
         "output_config": ["effort": "low"],
         "messages": turns.map { ["role": $0.role, "content": $0.content] }]
    }

    public static func request(_ turns: [Turn], key: String) throws -> URLRequest {
        var r = URLRequest(url: endpoint, timeoutInterval: 120)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue(version, forHTTPHeaderField: "anthropic-version")
        r.httpBody = try JSONSerialization.data(withJSONObject: body(turns))
        return r
    }

    /// The reply's text and its content blocks (to send back next turn).
    public static func parse(status: Int, data: Data) -> Result<(text: String, blocks: [[String: Any]]), Failure> {
        let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let m = ((o?["error"] as? [String: Any])?["message"] as? String) ?? ""
            return .failure(.http(status, m))
        }
        guard let o, let blocks = o["content"] as? [[String: Any]] else { return .failure(.unreadable) }
        if o["stop_reason"] as? String == "refusal" { return .failure(.refused) }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
        return .success((text.trimmingCharacters(in: .whitespacesAndNewlines), blocks))
    }

    public static func send(_ turns: [Turn], key: String) async -> Result<(text: String, blocks: [[String: Any]]), Failure> {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request(turns, key: key))
            return parse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
