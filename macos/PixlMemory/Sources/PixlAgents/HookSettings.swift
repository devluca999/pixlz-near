import Foundation

/// Adds Pixlz's hooks to Claude Code's settings (`~/.claude/settings.json`) and takes them out
/// again, leaving everything else as it was. Pixlz's entries are the ones whose command runs
/// `pixl-agent-hook`; installing twice changes nothing.
public enum HookSettings {
    public static let marker = "pixl-agent-hook"
    /// Tool events take a matcher ("*" = every tool); the others don't.
    public static let events: [(name: String, toolMatcher: Bool, timeout: Int)] = [
        ("SessionStart", false, 10), ("SessionEnd", false, 10), ("UserPromptSubmit", false, 10),
        ("PreToolUse", true, 10), ("PostToolUse", true, 10), ("PostToolUseFailure", true, 10), ("Stop", false, 330), ("Notification", false, 10),
        ("PermissionRequest", true, 60),
    ]

    public static func url(home: URL) -> URL { home.appending(path: ".claude/settings.json") }

    public static func command(hookPath: String) -> String {
        "'" + hookPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func isPixlz(_ entry: Any) -> Bool {
        guard let e = entry as? [String: Any], let hooks = e["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains(where: isPixlzHook)
    }

    static func isPixlzHook(_ hook: [String: Any]) -> Bool { (hook["command"] as? String)?.contains(marker) == true }

    /// Every event has Pixlz's hook, with the timeout this version needs (an older install
    /// shows "Update" so Connect adds what's new).
    /// Every event has Pixlz's hook, pointing at this app's helper (`hookPath`, when given) with
    /// the timeout this version needs. An older or moved install shows "Update".
    public static func installed(in settings: [String: Any], hookPath: String? = nil) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            (hooks[ev.name] as? [Any])?.contains { e in
                guard let list = (e as? [String: Any])?["hooks"] as? [[String: Any]] else { return false }
                return list.contains { h in
                    isPixlzHook(h) && (h["timeout"] as? Int) == ev.timeout &&
                        (hookPath.map { (h["command"] as? String) == command(hookPath: $0) } ?? true)
                }
            } == true
        }
    }

    public static func removing(from settings: [String: Any]) -> [String: Any] {
        var s = settings
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        for (name, value) in hooks {
            guard let list = value as? [Any] else { continue }
            // Take out only Pixlz's commands; an entry that also holds your own hooks keeps them.
            let kept: [Any] = list.compactMap { entry in
                guard var e = entry as? [String: Any], let inner = e["hooks"] as? [[String: Any]] else { return entry }
                let rest = inner.filter { !isPixlzHook($0) }
                if rest.count == inner.count { return entry }
                if rest.isEmpty { return nil }
                e["hooks"] = rest
                return e
            }
            hooks[name] = kept.isEmpty ? nil : kept
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        return s
    }

    public static func adding(to settings: [String: Any], hookPath: String) -> [String: Any] {
        var s = removing(from: settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        for ev in events {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(hookPath: hookPath), "timeout": ev.timeout]]]
            if ev.toolMatcher { entry["matcher"] = "*" }
            hooks[ev.name] = (hooks[ev.name] as? [Any] ?? []) + [entry]
        }
        s["hooks"] = hooks
        return s
    }

    // MARK: the file

    public enum Failure: Error, Equatable { case unreadable }

    /// The settings as they are; empty when the file doesn't exist. Throws when it exists but
    /// isn't a JSON object: then Pixlz leaves it alone.
    public static func read(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable
        }
        return o
    }

    /// Writes atomically, after copying the current file to settings.json.pixlz-backup.
    public static func write(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The file as it was just before this change (replaced each time Pixlz writes).
        let backup = url.appendingPathExtension("pixlz-backup")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// Where the app listens for the hook: a Unix socket only this user can open.
public enum AgentSocket {
    public static func path(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appending(path: "Library/Application Support/PixlMemory/agents.sock").path
    }
}
