import Foundation
import Testing
@testable import PixlAgents

@Suite struct AgentHubTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSessionShowsWhatItIsDoing() {
        var hub = AgentHub()
        hub.receive(HookEvent(name: "SessionStart", sessionID: "a", cwd: "/Users/me/pixlz"), at: t0)
        #expect(hub.list.first?.project == "pixlz")
        hub.receive(HookEvent(name: "UserPromptSubmit", sessionID: "a", prompt: "fix the tests\nplease"), at: t0)
        #expect(hub.sessions["a"]?.prompt == "fix the tests" && hub.sessions["a"]?.state == .working)
        hub.receive(HookEvent(name: "PreToolUse", sessionID: "a", toolName: "Bash", toolInput: ["command": "swift test", "description": ""]), at: t0)
        #expect(hub.sessions["a"]?.doing == "Running swift test")
        hub.receive(HookEvent(name: "PreToolUse", sessionID: "a", toolName: "Edit", toolInput: ["file_path": "/x/App.swift"]), at: t0)
        #expect(hub.sessions["a"]?.doing == "Editing App.swift")
        hub.receive(HookEvent(name: "Stop", sessionID: "a"), at: t0)
        #expect(hub.sessions["a"]?.state == .idle)
        hub.receive(HookEvent(name: "SessionEnd", sessionID: "a"), at: t0)
        #expect(hub.sessions["a"]?.ended == true && hub.sessions["a"]?.state == .idle)   // kept: a message resumes it
    }

    @Test func aRequestWaitsUntilAnsweredHereOrInTheTerminal() {
        var hub = AgentHub()
        hub.receive(HookEvent(name: "SessionStart", sessionID: "b", cwd: "/p/other"), at: t0)
        hub.receive(HookEvent(name: "SessionStart", sessionID: "a", cwd: "/p/pixlz"), at: t0.addingTimeInterval(5))
        let id = hub.receive(HookEvent(name: "PermissionRequest", sessionID: "b", toolName: "Bash", toolInput: ["command": "rm -rf build"]), at: t0)
        #expect(id != nil)
        #expect(hub.requests.first?.detail == "rm -rf build" && hub.requests.first?.project == "other")
        #expect(hub.list.first?.id == "b")      // waiting ones come first
        hub.resolve(id!)
        #expect(hub.requests.isEmpty && hub.sessions["b"]?.state == .working)

        // Answered in the terminal: the tool runs, PostToolUse clears it.
        hub.receive(HookEvent(name: "PermissionRequest", sessionID: "a", toolName: "Write", toolInput: ["file_path": "/p/a.txt"]), at: t0)
        #expect(hub.requests.first?.summary == "Write a.txt")
        hub.receive(HookEvent(name: "PostToolUse", sessionID: "a", toolName: "Write"), at: t0)
        #expect(hub.requests.isEmpty)

        // Denied in the terminal: the next tool call settles it.
        hub.receive(HookEvent(name: "PermissionRequest", sessionID: "a", toolName: "Bash", toolInput: ["command": "rm x"]), at: t0)
        #expect(hub.sessions["a"]?.state == .needsYou)
        hub.receive(HookEvent(name: "PreToolUse", sessionID: "a", toolName: "Read", toolInput: ["file_path": "/p/b"]), at: t0)
        #expect(hub.requests.isEmpty && hub.sessions["a"]?.state == .working)
    }

    @Test func oldRequestsAndQuietSessionsExpire() {
        var hub = AgentHub()
        let id = hub.receive(HookEvent(name: "PermissionRequest", sessionID: "a", toolName: "Bash", toolInput: ["command": "ls"]), at: t0)!
        // Left to the terminal: listed for up to 10 min.
        #expect(hub.expire(at: t0.addingTimeInterval(60)).isEmpty && hub.requests.count == 1)
        hub.markHeld(id)
        #expect(hub.expire(at: t0.addingTimeInterval(54)).isEmpty)
        #expect(hub.expire(at: t0.addingTimeInterval(55)) == [id])
        #expect(hub.sessions.count == 1)
        hub.expire(at: t0.addingTimeInterval(31 * 60))
        #expect(hub.sessions.isEmpty)
    }

    @Test func hookJSONDecodes() {
        let json = #"{"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/a/b","tool_name":"Bash","tool_input":{"command":"npm test","timeout":5000}}"#
        let e = HookEvent(json: Data(json.utf8))
        #expect(e?.name == "PermissionRequest" && e?.toolInput["command"] == "npm test" && e?.toolInput["timeout"] == "5000")
        #expect(HookEvent(json: Data("{}".utf8)) == nil)
    }

    @Test func replyIsTheDocumentedShape() throws {
        let o = try JSONSerialization.jsonObject(with: AgentHub.reply(.allow)) as? [String: Any]
        let h = o?["hookSpecificOutput"] as? [String: Any]
        #expect(h?["hookEventName"] as? String == "PermissionRequest")
        #expect((h?["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        let d = try JSONSerialization.jsonObject(with: AgentHub.reply(.deny)) as? [String: Any]
        let dd = (d?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        #expect(dd?["behavior"] as? String == "deny" && dd?["message"] != nil)
    }
}

@Suite struct HookSettingsTests {
    let hook = "/Users/me/Applications/Pixl Memory.app/Contents/MacOS/pixl-agent-hook"

    @Test func installKeepsTheUsersOwnSettingsAndIsIdempotent() {
        let mine: [String: Any] = ["model": "opus", "hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let once = HookSettings.adding(to: mine, hookPath: hook)
        #expect(HookSettings.installed(in: once))
        #expect(once["model"] as? String == "opus")
        let stop = (once["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stop?.count == 2)
        let twice = HookSettings.adding(to: once, hookPath: hook)
        #expect(((twice["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 2)
        let pre = ((once["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first
        #expect(pre?["matcher"] as? String == "*")
        let cmd = ((pre?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(cmd == "'\(hook)'")
    }

    @Test func removeLeavesOnlyWhatWasThere() {
        let mine: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "say done"]]]]]]
        let back = HookSettings.removing(from: HookSettings.adding(to: mine, hookPath: hook))
        #expect(!HookSettings.installed(in: back))
        let hooks = back["hooks"] as? [String: Any]
        #expect(hooks?.count == 1 && (hooks?["Stop"] as? [Any])?.count == 1)
        #expect(HookSettings.removing(from: HookSettings.adding(to: [:], hookPath: hook))["hooks"] == nil)
    }

    @Test func fileRoundTripKeepsABackup() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pixlz-hooks-\(UUID().uuidString)")
        let url = HookSettings.url(home: dir)
        #expect(try HookSettings.read(url).isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: url)
        try HookSettings.write(HookSettings.adding(to: try HookSettings.read(url), hookPath: hook), to: url)
        #expect(HookSettings.installed(in: try HookSettings.read(url)))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("pixlz-backup").path))
        try Data("not json".utf8).write(to: url)
        #expect(throws: HookSettings.Failure.unreadable) { try HookSettings.read(url) }
        try? FileManager.default.removeItem(at: dir)
    }
}
