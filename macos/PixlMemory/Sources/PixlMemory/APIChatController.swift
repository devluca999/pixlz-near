import Foundation
import PixlAgents
import PixlMemoryKit

/// Agent mode's "Chat with Claude": a conversation through the Anthropic API with the key in the
/// repo's .env.local (APIChat.model, Haiku for now), not through your Claude account.
@MainActor
final class APIChatController {
    private(set) var turns: [APIChat.Turn] = []
    private(set) var lines: [ChatCard.Line] = []
    private(set) var busy = false
    var onChange: (@MainActor () -> Void)?

    /// The repo (the service dir's parent, from Info.plist) holds .env.local.
    private var keyDirs: [URL] {
        let service = (Bundle.main.object(forInfoDictionaryKey: "PixlMemoryServiceDir") as? String).map { URL(fileURLWithPath: $0) }
        return [service?.deletingLastPathComponent(), service].compactMap { $0 }
    }

    var hasKey: Bool { APIChat.apiKey(dirs: keyDirs) != nil }

    func reset() {
        guard !busy else { return }
        turns = []
        lines = []
        onChange?()
    }

    /// Sends `text`; the reply (or what went wrong) lands in `lines`. `done` gets the error, if any.
    func send(_ text: String, done: @escaping @MainActor (APIChat.Failure?) -> Void) {
        guard !busy else { return }
        guard let key = APIChat.apiKey(dirs: keyDirs) else { done(.noKey); return }
        busy = true
        turns.append(APIChat.Turn(role: "user", content: text))
        lines.append(.init(.you, text))
        onChange?()
        let sent = turns
        Debug.log("apichat: asking \(APIChat.model) (\(sent.count) turns, \(text.count) chars)")
        Task { @MainActor in
            let r = await APIChat.send(sent, key: key)
            self.busy = false
            switch r {
            case .success(let reply):
                self.turns.append(APIChat.Turn(role: "assistant", content: reply.blocks))
                self.lines.append(.init(.claude, reply.text.isEmpty ? "(no text)" : reply.text))
                Debug.log("apichat: answered (\(reply.text.count) chars)")
                self.onChange?()
                done(nil)
            case .failure(let f):
                // the unanswered turn comes off, so the next send isn't two user turns in a row
                self.turns.removeLast()
                self.lines.append(.init(.tool, f.message))
                Debug.log("apichat: failed \(f)")
                self.onChange?()
                done(f)
            }
        }
    }
}
