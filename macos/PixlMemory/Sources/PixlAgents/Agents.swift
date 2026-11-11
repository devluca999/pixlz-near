import Foundation

// Agent mode (SPEC §16, D19): Claude Code's hooks tell Pixlz which sessions run on this Mac,
// what each is doing, and when one needs your OK. Pure state, no UI or sockets: fully testable.

/// One hook call, as Claude Code writes it on the hook's stdin (only the fields Pixlz reads).
public struct HookEvent: Sendable, Equatable {
    public var name: String            // hook_event_name
    public var sessionID: String
    public var cwd: String
    public var prompt: String?         // UserPromptSubmit
    public var toolName: String?       // PreToolUse, PostToolUse, PermissionRequest
    public var toolInput: [String: String]
    public var message: String?        // Notification

    public init(name: String, sessionID: String, cwd: String = "", prompt: String? = nil, toolName: String? = nil,
                toolInput: [String: String] = [:], message: String? = nil) {
        self.name = name; self.sessionID = sessionID; self.cwd = cwd; self.prompt = prompt
        self.toolName = toolName; self.toolInput = toolInput; self.message = message
    }

    /// From the raw stdin JSON. Nil when it isn't a hook event Pixlz understands.
    public init?(json: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let name = o["hook_event_name"] as? String, let id = o["session_id"] as? String, !id.isEmpty else { return nil }
        var input: [String: String] = [:]
        if let ti = o["tool_input"] as? [String: Any] {
            for (k, v) in ti {
                if let s = v as? String { input[k] = s } else if let n = v as? NSNumber { input[k] = n.stringValue }
            }
        }
        self.init(name: name, sessionID: id, cwd: o["cwd"] as? String ?? "", prompt: o["prompt"] as? String,
                  toolName: o["tool_name"] as? String, toolInput: input, message: o["message"] as? String)
    }
}

public struct AgentSession: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable { case working, idle, needsYou }
    public var id: String
    public var cwd: String
    public var project: String { cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent }
    public var prompt: String?          // the first line of what it was last asked
    public var doing: String            // "Running swift test", "Editing App.swift", "Done"
    public var state: State
    public var lastHeard: Date
}

public struct AgentRequest: Sendable, Equatable, Identifiable {
    public var id: String               // Pixlz's own id for this request
    public var sessionID: String
    public var project: String
    public var tool: String
    public var detail: String           // the exact command, file or URL
    public var summary: String          // "Run swift test", "Edit App.swift"
    public var received: Date
}

public enum AgentDecision: String, Sendable { case allow, deny }

public struct AgentHub: Sendable {
    /// A session not heard from for this long leaves the list.
    public static let sessionTimeout: TimeInterval = 30 * 60
    /// Pixlz gives up on a request after this long; Claude Code then asks in the terminal.
    public static let requestTimeout: TimeInterval = 55

    public private(set) var sessions: [String: AgentSession] = [:]
    public private(set) var requests: [AgentRequest] = []   // oldest first
    private var counter = 0

    public init() {}

    /// Waiting sessions first (oldest request first), then the most recently heard.
    public var list: [AgentSession] {
        sessions.values.sorted { a, b in
            if (a.state == .needsYou) != (b.state == .needsYou) { return a.state == .needsYou }
            return a.lastHeard > b.lastHeard
        }
    }

    /// Takes one hook event. For a PermissionRequest, returns the new request's id: the caller
    /// keeps the hook waiting until `resolve` or `expire` closes it.
    @discardableResult
    public mutating func receive(_ e: HookEvent, at now: Date) -> String? {
        var s = sessions[e.sessionID] ?? AgentSession(id: e.sessionID, cwd: e.cwd, prompt: nil, doing: "Starting", state: .idle, lastHeard: now)
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        s.lastHeard = now
        var newRequest: String?
        switch e.name {
        case "SessionStart":
            s.doing = "Ready"
            s.state = .idle
        case "SessionEnd":
            sessions[e.sessionID] = nil
            requests.removeAll { $0.sessionID == e.sessionID }
            return nil
        case "UserPromptSubmit":
            s.prompt = e.prompt.map(Self.firstLine)
            s.doing = "Thinking"
            s.state = .working
            answeredElsewhere(e.sessionID)
        case "PreToolUse":
            s.doing = Self.describe(tool: e.toolName ?? "", input: e.toolInput, present: true)
            if s.state != .needsYou { s.state = .working }
        case "PostToolUse":
            // It ran: whatever it asked about was answered (here or in the terminal).
            answeredElsewhere(e.sessionID)
            s.state = .working
        case "Stop":
            answeredElsewhere(e.sessionID)
            s.doing = "Done · waiting for your next prompt"
            s.state = .idle
        case "PermissionRequest":
            counter += 1
            let id = "req-\(counter)"
            let tool = e.toolName ?? "Tool"
            requests.append(AgentRequest(id: id, sessionID: e.sessionID, project: s.project, tool: tool,
                                         detail: Self.detail(tool: tool, input: e.toolInput),
                                         summary: Self.describe(tool: tool, input: e.toolInput, present: false),
                                         received: now))
            s.doing = "Needs you: " + Self.describe(tool: tool, input: e.toolInput, present: false)
            s.state = .needsYou
            newRequest = id
        case "Notification":
            if let m = e.message, !m.isEmpty { s.doing = Self.firstLine(m) }
        default:
            break
        }
        sessions[e.sessionID] = s
        return newRequest
    }

    /// The request was answered (or its hook went away): it leaves the list.
    public mutating func resolve(_ requestID: String) {
        guard let i = requests.firstIndex(where: { $0.id == requestID }) else { return }
        let sid = requests.remove(at: i).sessionID
        settle(sid)
    }

    /// Drops old requests and quiet sessions. Returns the ids of requests that timed out.
    @discardableResult
    public mutating func expire(at now: Date) -> [String] {
        let old = requests.filter { now.timeIntervalSince($0.received) >= Self.requestTimeout }.map(\.id)
        old.forEach { resolve($0) }
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastHeard) < Self.sessionTimeout }
        return old
    }

    private mutating func answeredElsewhere(_ sessionID: String) {
        requests.removeAll { $0.sessionID == sessionID }
    }

    private mutating func settle(_ sessionID: String) {
        guard var s = sessions[sessionID], s.state == .needsYou, !requests.contains(where: { $0.sessionID == sessionID }) else { return }
        s.state = .working
        s.doing = "Working"
        sessions[sessionID] = s
    }

    // MARK: words

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    static func file(_ input: [String: String]) -> String? {
        (input["file_path"] ?? input["notebook_path"] ?? input["path"]).map { ($0 as NSString).lastPathComponent }
    }

    /// "Running swift test" (present) or "Run swift test" (what it asks to do).
    public static func describe(tool: String, input: [String: String], present: Bool) -> String {
        func verb(_ now: String, _ ask: String) -> String { present ? now : ask }
        switch tool {
        case "Bash": return verb("Running", "Run") + " " + firstLine(input["description"].flatMap { $0.isEmpty ? nil : $0 } ?? input["command"] ?? "a command")
        case "Edit", "MultiEdit": return verb("Editing", "Edit") + " " + (file(input) ?? "a file")
        case "Write": return verb("Writing", "Write") + " " + (file(input) ?? "a file")
        case "Read": return verb("Reading", "Read") + " " + (file(input) ?? "a file")
        case "NotebookEdit": return verb("Editing", "Edit") + " " + (file(input) ?? "a notebook")
        case "Grep", "Glob": return verb("Searching", "Search") + " " + (input["pattern"] ?? "files")
        case "WebFetch": return verb("Reading", "Open") + " " + (input["url"].flatMap { URL(string: $0)?.host } ?? "a web page")
        case "WebSearch": return verb("Searching the web for", "Search the web for") + " " + (input["query"] ?? "something")
        case "Agent", "Task": return verb("Running a helper", "Start a helper")
        default: return verb("Using", "Use") + " " + tool
        }
    }

    /// The exact thing being approved, shown in full on the card.
    public static func detail(tool: String, input: [String: String]) -> String {
        switch tool {
        case "Bash": return input["command"] ?? ""
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": return input["file_path"] ?? input["notebook_path"] ?? ""
        case "WebFetch": return input["url"] ?? ""
        case "WebSearch": return input["query"] ?? ""
        default: return input.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
    }

    /// What the hook prints to answer a PermissionRequest.
    public static func reply(_ decision: AgentDecision) -> Data {
        var d: [String: Any] = ["behavior": decision.rawValue]
        if decision == .deny { d["message"] = "Denied from Pixlz." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }
}
