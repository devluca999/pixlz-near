import Foundation

// Two-way Agent mode: you can message a Claude Code session from Pixlz. A message waits in the
// session's outbox and goes the first way that's open:
//   • at its next step: the PostToolUse hook answers with it as `additionalContext`;
//   • now: the session finished a turn and Pixlz holds its Stop hook; the reply blocks the stop
//     (`{"decision":"block","reason":…}`) so Claude carries on with it;
//   • by resuming it: nothing is listening (closed, or quiet for 2 min), so the app runs
//     `claude -p --resume <id>` in the session's folder.

/// Text you typed in a chat panel: the only thing that can go into an outbox. It has no public
/// initializer; `AgentChatInput` (the panel's text field) makes one when you press Send.
public struct TypedMessage: Sendable, Equatable {
    public let text: String
    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        self.text = String(t.prefix(8000))
    }
}

public enum Delivery: String, Sendable, Equatable { case queued, delivered, failed }

public struct OutboxEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var time: Date
    public var status: Delivery
    /// How it went (or why not): "at its next step", "resumed", "claude isn't installed".
    public var note: String?
}

/// How a message to a session will be delivered right now.
public enum DeliveryRoute: Sendable, Equatable {
    case nextStep   // it's working: PostToolUse (or its next Stop) carries it
    case now        // its Stop is held: the reply goes straight in
    case resume     // nothing listening: `claude -p --resume`

    public var label: String {
        switch self {
        case .nextStep: "Sends at its next step"
        case .now: "Sends now"
        case .resume: "Resumes the session"
        }
    }
}

/// What to do with a Stop hook.
public enum StopAction: Sendable, Equatable {
    case block(Data)   // carry on with this (your message)
    case hold          // keep it open for the reply window
    case release       // let it stop
}

extension AgentHub {
    /// A session quiet this long, with no Stop held, has nothing listening: a message resumes it.
    public static let quietForResume: TimeInterval = 120

    /// Puts a message you typed in the session's outbox. Returns its id (for its status).
    @discardableResult
    public mutating func queue(_ message: TypedMessage, for sessionID: String, at now: Date) -> String {
        outboxCounter += 1
        let id = "msg-\(outboxCounter)"
        outbox[sessionID, default: []].append(OutboxEntry(id: id, text: message.text, time: now, status: .queued))
        return id
    }

    /// Whether anything waits to go to this session.
    public func hasQueued(_ sessionID: String) -> Bool { outbox[sessionID]?.contains { $0.status == .queued } == true }

    /// Takes everything waiting for the session (joined, oldest first) and marks it delivered.
    public mutating func take(for sessionID: String, note: String? = nil) -> String? {
        guard var list = outbox[sessionID] else { return nil }
        let waiting = list.indices.filter { list[$0].status == .queued }
        guard !waiting.isEmpty else { return nil }
        let text = waiting.map { list[$0].text }.joined(separator: "\n\n")
        for i in waiting { list[i].status = .delivered; list[i].note = note }
        outbox[sessionID] = list
        return text
    }

    /// Marks what's waiting as failed (a resume that couldn't run).
    public mutating func fail(_ sessionID: String, note: String) {
        guard var list = outbox[sessionID] else { return }
        for i in list.indices where list[i].status == .queued { list[i].status = .failed; list[i].note = note }
        outbox[sessionID] = list
    }

    /// How a message would go now.
    public func route(for sessionID: String, at now: Date) -> DeliveryRoute {
        if heldStops[sessionID] != nil { return .now }
        guard let s = sessions[sessionID] else { return .resume }
        if s.ended || now.timeIntervalSince(s.lastHeard) >= Self.quietForResume { return .resume }
        return .nextStep
    }

    /// Resuming a session that was heard from lately and never ended: it may still be open in a
    /// terminal, where a second run can conflict.
    public func mayBeOpenElsewhere(_ sessionID: String, at now: Date) -> Bool {
        guard let s = sessions[sessionID] else { return false }
        return !s.ended && now.timeIntervalSince(s.lastHeard) < Self.quietForResume
    }

    /// PostToolUse: the queued message as context for its next step, or nothing (instantly).
    public mutating func answerPostToolUse(_ sessionID: String) -> Data? {
        guard let text = take(for: sessionID, note: "at its next step") else { return nil }
        return Self.json(["hookSpecificOutput": ["hookEventName": "PostToolUse",
                                                 "additionalContext": "Message from the user via Pixlz: " + text]])
    }

    /// Stop: block with your message if one is waiting; otherwise hold it for a reply, unless
    /// this stop comes from a chain Pixlz already continued (`stop_hook_active`) and you typed
    /// nothing new: then it stops, so Pixlz can never loop it.
    public mutating func answerStop(_ e: HookEvent, at now: Date) -> StopAction {
        if let text = take(for: e.sessionID, note: "when it finished its turn") {
            heldStops[e.sessionID] = nil
            return .block(Self.stopReply(text))
        }
        if e.stopHookActive { heldStops[e.sessionID] = nil; return .release }
        heldStops[e.sessionID] = now
        return .hold
    }

    /// Your reply while its Stop is held: the answer that sends it in. Nil if nothing's held or waiting.
    public mutating func replyToHeldStop(_ sessionID: String) -> Data? {
        guard heldStops[sessionID] != nil, let text = take(for: sessionID, note: "sent now") else { return nil }
        heldStops[sessionID] = nil
        return Self.stopReply(text)
    }

    /// Let a held stop go (dismissed, or its hook went away).
    public mutating func releaseStop(_ sessionID: String) { heldStops[sessionID] = nil }

    /// Held stops older than the reply window: let them go. Returns their sessions.
    public mutating func expireStops(at now: Date, window: TimeInterval) -> [String] {
        let old = heldStops.filter { now.timeIntervalSince($0.value) >= window }.map(\.key)
        old.forEach { heldStops[$0] = nil }
        return old
    }

    public static func stopReply(_ text: String) -> Data { json(["decision": "block", "reason": text]) }

    static func json(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// `claude -p --resume <id> --output-format stream-json --verbose <message>`: the arguments
    /// for resuming a session with one message (run in the session's folder).
    public static func resumeArguments(sessionID: String, message: String) -> [String] {
        ["-p", "--resume", sessionID, "--output-format", "stream-json", "--verbose", message]
    }
}

extension AgentHub {
    /// One line of `--output-format stream-json`: what to show for it (its words, a tool call as
    /// one line, the final result), or nil (system lines, partial events, anything unknown).
    public static func streamText(_ line: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        switch o["type"] as? String {
        case "assistant":
            guard (o["parent_tool_use_id"] as? String) == nil else { return nil }   // a helper's own talk
            let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            let parts = blocks.compactMap { b -> String? in
                switch b["type"] as? String {
                case "text": return (b["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                case "tool_use":
                    var input: [String: String] = [:]
                    for (k, v) in b["input"] as? [String: Any] ?? [:] { if let s = v as? String { input[k] = s } }
                    return "→ " + describe(tool: b["name"] as? String ?? "a tool", input: input, present: false)
                default: return nil
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        case "result":
            if o["is_error"] as? Bool == true { return "⚠︎ " + ((o["result"] as? String) ?? "It stopped with an error.") }
            return nil   // the final text was already streamed as its last assistant message
        default:
            return nil
        }
    }
}
