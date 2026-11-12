import Foundation
import Testing
@_spi(DeviceInput) @testable import PixlAgents

@Suite struct AgentChatTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func hub(_ id: String = "s", at t: Date? = nil) -> AgentHub {
        var h = AgentHub()
        h.receive(HookEvent(name: "SessionStart", sessionID: id, cwd: "/Users/me/pixlz", transcriptPath: "/Users/me/.claude/projects/-Users-me-pixlz/\(id).jsonl"), at: t ?? t0)
        return h
    }
    func typed(_ s: String) -> TypedMessage { TypedMessage(s)! }
    func object(_ d: Data?) -> [String: Any]? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    // MARK: hook input

    @Test func readsTranscriptPathStopHookActiveAndTheLastReply() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"abc","cwd":"/p","transcript_path":"/Users/me/.claude/projects/-p/abc.jsonl","stop_hook_active":true,"last_assistant_message":"All tests pass."}"#
        let e = try #require(HookEvent(json: Data(json.utf8)))
        #expect(e.transcriptPath == "/Users/me/.claude/projects/-p/abc.jsonl")
        #expect(e.stopHookActive)
        #expect(e.lastAssistantMessage == "All tests pass.")
        var h = AgentHub()
        h.receive(e, at: t0)
        #expect(h.sessions["abc"]?.transcriptPath == e.transcriptPath)
        #expect(h.sessions["abc"]?.lastReply == "All tests pass.")
        // updated on every event, like cwd
        h.receive(HookEvent(name: "PreToolUse", sessionID: "abc", toolName: "Read", transcriptPath: "/Users/me/.claude/projects/-p/abc2.jsonl"), at: t0)
        #expect(h.sessions["abc"]?.transcriptPath?.hasSuffix("abc2.jsonl") == true)
        let bare = try #require(HookEvent(json: Data(#"{"hook_event_name":"Stop","session_id":"x"}"#.utf8)))
        #expect(bare.transcriptPath == nil && !bare.stopHookActive)
    }

    // MARK: transcript

    @Test func onlyTranscriptsUnderClaudeProjectsAreRead() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pixl-home-\(UUID().uuidString)")
        let dir = home.appending(path: ".claude/projects/-p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "s.jsonl")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(TranscriptReader.validated(file.path, home: home) != nil)
        #expect(TranscriptReader.validated("/etc/passwd", home: home) == nil)
        #expect(TranscriptReader.validated(home.path + "/.claude/projects/-p/../../../../etc/passwd", home: home) == nil)
        #expect(TranscriptReader.validated(home.path + "/.claude/projects/../secrets.jsonl", home: home) == nil)
        #expect(TranscriptReader.validated(dir.appending(path: "s.json").path, home: home) == nil)       // not .jsonl
        #expect(TranscriptReader.validated("relative/s.jsonl", home: home) == nil)
        // a symlink that points outside is followed, and refused
        let outside = home.appending(path: "outside.jsonl")
        try Data().write(to: outside)
        let link = dir.appending(path: "link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(TranscriptReader.validated(link.path, home: home) == nil)
    }

    @Test func theTailSkipsBadLinesAndCollapsesToolCalls() {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"fix the tests"},"timestamp":"2026-11-11T10:00:00.000Z"}"#,
            #"this line is not JSON {"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."},{"type":"tool_use","name":"Bash","input":{"command":"swift test","description":""}}]},"timestamp":"2026-11-11T10:00:05Z"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"summary","summary":"whatever"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All green."}]}}"#,
        ]
        let entries = TranscriptReader.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(entries.map(\.role) == [.user, .assistant, .assistant])
        #expect(entries[0].text == "fix the tests" && entries[0].time != nil)
        #expect(entries[1].text == "On it.\n→ Run swift test")
        #expect(entries[2].text == "All green.")
        // cut mid-line by the 256 KB tail: the first (partial) line is dropped
        let cut = TranscriptReader.parse(Data(("ssage\":{}}\n" + lines[0]).utf8), partialFirstLine: true)
        #expect(cut.count == 1)
        #expect(TranscriptReader.parse(Data("{{{{".utf8)).isEmpty)
    }

    // MARK: delivery

    @Test func aMessageGoesAtTheNextStepThroughPostToolUse() throws {
        var h = hub()
        h.receive(HookEvent(name: "UserPromptSubmit", sessionID: "s", prompt: "go"), at: t0)
        #expect(h.route(for: "s", at: t0) == .nextStep)
        h.queue(typed("also update the README"), for: "s", at: t0)
        #expect(h.outbox["s"]?.first?.status == .queued)
        let r1 = h.answerPostToolUse("s")
        let reply = try #require(r1)
        let out = try #require(object(reply)?["hookSpecificOutput"] as? [String: Any])
        #expect(out["hookEventName"] as? String == "PostToolUse")
        #expect(out["additionalContext"] as? String == "Message from you via Pixlz (typed on the Mac): also update the README")
        #expect(h.outbox["s"]?.first?.status == .delivered)
        #expect(h.answerPostToolUse("s") == nil)          // nothing queued: no output at all
    }

    @Test func aWaitingMessageContinuesTheSessionWhenItStops() throws {
        var h = hub()
        h.queue(typed("now run the linter"), for: "s", at: t0)
        let stop = HookEvent(name: "Stop", sessionID: "s")
        h.receive(stop, at: t0)
        guard case .block(let d) = h.answerStop(stop, at: t0) else { Issue.record("not blocked"); return }
        #expect(object(d)?["decision"] as? String == "block")
        #expect(object(d)?["reason"] as? String == Transcript.label(via: "typed on the Mac") + "now run the linter")
        #expect(h.heldStops["s"] == nil)
    }

    @Test func withNothingWaitingTheStopIsHeldForAReplyThenSentNow() throws {
        var h = hub()
        let stop = HookEvent(name: "Stop", sessionID: "s")
        #expect(h.answerStop(stop, at: t0) == .hold)
        #expect(h.route(for: "s", at: t0) == .now)
        h.queue(typed("yes, ship it"), for: "s", at: t0.addingTimeInterval(10))
        let r2 = h.replyToHeldStop("s")
        let reply = try #require(r2)
        #expect(object(reply)?["reason"] as? String == Transcript.label(via: "typed on the Mac") + "yes, ship it")
        #expect(h.heldStops["s"] == nil && h.outbox["s"]?.first?.status == .delivered)
    }

    @Test func noReplyInTheWindowLetsTheStopThrough() {
        var h = hub()
        _ = h.answerStop(HookEvent(name: "Stop", sessionID: "s"), at: t0)
        #expect(h.expireStops(at: t0.addingTimeInterval(59), window: 60).isEmpty)
        #expect(h.expireStops(at: t0.addingTimeInterval(60), window: 60) == ["s"])
        #expect(h.heldStops.isEmpty)
        #expect(h.replyToHeldStop("s") == nil)             // too late: nothing to answer
    }

    @Test func stopHookActiveNeverBlocksAgainWithoutANewMessage() {
        var h = hub()
        let again = HookEvent(name: "Stop", sessionID: "s", stopHookActive: true)
        // continuing because Pixlz blocked: stop now, don't even hold
        #expect(h.answerStop(again, at: t0) == .release)
        #expect(h.heldStops.isEmpty)
        // unless you typed something new
        h.queue(typed("one more thing"), for: "s", at: t0)
        if case .block = h.answerStop(again, at: t0) {} else { Issue.record("a new message should go") }
        #expect(h.answerStop(again, at: t0) == .release)   // and only once
    }

    @Test func idleOrClosedSessionsAreResumed() {
        var h = hub()
        #expect(h.route(for: "s", at: t0.addingTimeInterval(30)) == .nextStep)
        #expect(h.mayBeOpenElsewhere("s", at: t0.addingTimeInterval(30)))
        #expect(h.route(for: "s", at: t0.addingTimeInterval(121)) == .resume)
        #expect(!h.mayBeOpenElsewhere("s", at: t0.addingTimeInterval(121)))
        h.receive(HookEvent(name: "SessionEnd", sessionID: "s"), at: t0.addingTimeInterval(5))
        #expect(h.sessions["s"]?.ended == true)            // kept, so you can still message it
        #expect(h.route(for: "s", at: t0.addingTimeInterval(6)) == .resume)
        #expect(!h.mayBeOpenElsewhere("s", at: t0.addingTimeInterval(6)))
        #expect(h.route(for: "never-seen", at: t0) == .resume)
    }

    @Test func theResumeCommand() {
        #expect(AgentHub.resumeArguments(sessionID: "abc-123", message: "carry on; rm -rf $HOME") ==
                ["-p", "--resume", "abc-123", "--output-format", "stream-json", "--verbose", "carry on; rm -rf $HOME"])
        // the message is one argument, never parsed by a shell
    }

    @Test func aResumedRunsStreamIsShownAsWordsAndToolLines() {
        let a = #"{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Done."},{"type":"tool_use","name":"Edit","input":{"file_path":"/x/README.md"}}]}}"#
        #expect(AgentHub.streamText(Data(a.utf8)) == "Done.\n→ Edit README.md")
        #expect(AgentHub.streamText(Data(#"{"type":"system","subtype":"init"}"#.utf8)) == nil)
        #expect(AgentHub.streamText(Data(#"{"type":"result","is_error":true,"result":"Out of credits"}"#.utf8)) == "⚠︎ Out of credits")
        #expect(AgentHub.streamText(Data("garbage".utf8)) == nil)
    }

    @Test func failuresAreShownNotDropped() {
        var h = hub()
        h.queue(typed("hi"), for: "s", at: t0)
        h.fail("s", note: "Claude Code isn't installed")
        #expect(h.outbox["s"]?.first?.status == .failed && h.take(for: "s") == nil)
    }

    @Test func aReplyFromAPairedDeviceSaysWhereItCameFrom() throws {
        var h = hub()
        h.queue(try #require(TypedMessage.fromPairedDevice("ship it", via: "dictated on the Mosaico")), for: "s", at: t0)
        h.queue(typed("and tag it"), for: "s", at: t0)
        let r = h.take(for: "s")
        #expect(r == Transcript.label(via: "dictated on the Mosaico") + "ship it\n\n" + Transcript.label(via: "typed on the Mac") + "and tag it")
    }

    @Test func emptyMessagesArentMessages() {
        #expect(TypedMessage("   \n ") == nil)
        #expect(TypedMessage(" hi ")?.text == "hi")
    }

    // MARK: settings

    @Test func stopIsHeldLongerThanTheLongestReplyWindowAndPostToolUseIsHooked() {
        let s = HookSettings.adding(to: [:], hookPath: "/A/pixl-agent-hook")
        let hooks = s["hooks"] as? [String: Any] ?? [:]
        func timeout(_ name: String) -> Int? {
            ((hooks[name] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int
        }
        #expect((timeout("Stop") ?? 0) > HookSettings.maxReplyWindow)
        #expect(timeout("PostToolUse") != nil)
        #expect(!HookSettings.outdated(in: s))
        var old = s
        var oh = hooks
        oh["Stop"] = [["hooks": [["type": "command", "command": "'/A/pixl-agent-hook'", "timeout": 10]]]]
        old["hooks"] = oh
        #expect(HookSettings.outdated(in: old))
    }
}

/// Safety rules, checked on the source (Swift can't express "only this view may call that").
@Suite struct AgentSafetyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sources").standardized
    func sources(_ dirs: [String]) throws -> [(name: String, text: String)] {
        try dirs.flatMap { d -> [(String, String)] in
            let dir = Self.root.appending(path: d)
            return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        }
    }

    @Test func onlyTextTypedInTheChatPanelCanBeQueued() throws {
        let all = try sources(["PixlAgents", "PixlMemory", "PixlMemoryKit", "PixlBridge"])
        // a TypedMessage has no public way to be made; the panel's field makes them
        let chat = all.first { $0.name == "AgentChat.swift" }!.text
        #expect(!chat.contains("public init?(_ text") && !chat.contains("public init(_ text"))
        let makers = all.filter { $0.text.contains("TypedMessage(") && !$0.text.contains("struct TypedMessage") }.map(\.name)
        #expect(makers == ["AgentChatInput.swift"])
        // a paired device's replies come in through one opted-in door, used only by the device link
        let deviceDoor = all.filter { $0.text.contains("@_spi(DeviceInput)") && $0.name != "AgentChat.swift" }.map(\.name)
        #expect(deviceDoor.allSatisfy { $0 == "TravelController.swift" })
        // the outbox is filled only by AgentController.send, and send only from the chat panel's field
        let queuers = all.filter { $0.text.contains(".queue(") }.map(\.name)
        #expect(queuers == ["AgentController.swift"])
        let senders = all.filter { $0.text.contains("agents.send(") || $0.text.contains("app.agents.send(") }.map(\.name)
        #expect(senders.sorted() == ["AgentChatPanel.swift", "TravelController.swift"])   // the panel's field; a paired device
    }

    @Test func transcriptsAndChatsNeverTouchTheNetwork() throws {
        // "Chat with Claude (API key)" is its own conversation with the Anthropic API: it may use
        // the network, but it never reads a transcript or a session's outbox
        let apiChat = try sources(["PixlAgents", "PixlMemory"]).filter { $0.name.hasPrefix("APIChat") }
        for f in apiChat {
            for t in ["Transcript", "transcriptPath", "outbox", ".chat(", "hub."] { #expect(!f.text.contains(t), "\(f.name) touches \(t)") }
        }
        let files = try sources(["PixlAgents"]).filter { !$0.name.hasPrefix("APIChat") }
            + (try sources(["PixlMemory"]).filter { ["AgentChatPanel.swift", "AgentController.swift"].contains($0.name) })
        for f in files {
            for api in ["URLSession", "URLRequest", "NWConnection", "CFNetwork", "MemoryClient", "http://", "https://claude.ai/api"] {
                #expect(!f.text.contains(api), "\(f.name) uses \(api)")
            }
        }
    }
}
