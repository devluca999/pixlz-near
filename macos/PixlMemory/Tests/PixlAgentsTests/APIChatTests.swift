import Foundation
import Testing
@testable import PixlAgents

@Suite struct APIChatTests {
    @Test func readsTheKeyFromEnvLocalUnderEitherName() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "apichat-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(APIChat.apiKey(env: [:], dirs: [dir]) == nil)
        try "# keys\nAnthopicAPIKEy=\"sk-test-1\"\n".write(to: dir.appending(path: ".env.local"), atomically: true, encoding: .utf8)
        #expect(APIChat.apiKey(env: [:], dirs: [dir]) == "sk-test-1")
        // the environment wins over the file
        #expect(APIChat.apiKey(env: ["ANTHROPIC_API_KEY": "sk-env"], dirs: [dir]) == "sk-env")
    }

    @Test func parsesEnvLines() {
        let v = APIChat.parseEnv("export A=1\nB = 'two'\n# C=3\n\nD=x=y")
        #expect(v == ["A": "1", "B": "two", "D": "x=y"])
    }

    @Test func requestUsesHaikuAndTheKeyHeader() throws {
        let r = try APIChat.request([APIChat.Turn(role: "user", content: "hi")], key: "sk-test")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == APIChat.version)
        let body = try #require(JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["messages"] as? [[String: Any]])?.count == 1)
    }

    @Test func parsesTextRefusalsAndErrors() throws {
        let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hello"}],"stop_reason":"end_turn"}"#
        let r = try APIChat.parse(status: 200, data: Data(ok.utf8)).get()
        #expect(r.text == "Hello")
        #expect(r.blocks.count == 2)   // thinking kept, to send back unchanged
        let no = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: APIChat.Failure.refused) { try APIChat.parse(status: 200, data: Data(no.utf8)).get() }
        let bad = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        #expect(throws: APIChat.Failure.http(401, "invalid x-api-key")) { try APIChat.parse(status: 401, data: Data(bad.utf8)).get() }
    }
}
