import AppKit
import PixlBridge
import PixlMemoryKit

/// Carries out what a typed request asks for when no model is needed (PixlIntent): opening an
/// app or a site, playing something, a browser search, saving the page in front. Nothing here
/// is sent anywhere except the saved text, which goes to the local memory service.
@MainActor
final class IntentRunner {
    unowned let app: AppController
    var finder = AppFinder()
    /// What the self-test asked for, instead of really opening anything.
    var selfTestOpened: [String] = []

    init(app: AppController) { self.app = app }

    /// Handles `q` if it's an action; `done` gets what to say and, for a save, what was saved.
    /// Returns false for a question (it goes to Ask).
    func run(_ q: String, front: NSRunningApplication?, done: @escaping @MainActor (String, HighlightItem?) -> Void) -> Bool {
        let intent = PixlIntent.parse(q)
        Debug.log("intent: \(Self.kind(intent))")
        switch intent {
        case .ask:
            return false
        case .open(let name, let web, let preferWeb):
            if app.travel.knowsPlace(name) { done(app.travel.go(to: name), nil); return true }
            if !preferWeb, let url = finder.find(name) {
                let shown = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                launch(url); done("Opening \(shown)!", nil)
            } else if let web {
                let shown = name == name.lowercased() ? name.prefix(1).uppercased() + name.dropFirst() : name   // "spotify" → "Spotify"
                open(web); done("Opening \(shown) in your browser.", nil)
            } else {
                // not an app here, not a site I know: the top result for it
                var c = URLComponents(string: "https://duckduckgo.com/")!
                c.queryItems = [URLQueryItem(name: "q", value: "\\" + name)]
                open(c.url!); done(preferWeb ? "Opening \(name) in your browser." : "There's no app called “\(name)” on this Mac, so I opened the top web result.", nil)
            }
        case .openURL(let url):
            open(url); done("Opening \(url.host ?? url.absoluteString).", nil)
        case .play(let query, let where_):
            let enc = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            let qEnc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            switch where_ {
            case "spotify":
                let url = finder.find("spotify") != nil ? URL(string: "spotify:search:\(enc)")! : URL(string: "https://open.spotify.com/search/\(enc)")!
                open(url); done("Found “\(query)” on Spotify. Press play!", nil)
            case "youtube":
                open(URL(string: "https://www.youtube.com/results?search_query=\(qEnc)")!); done("Looking up “\(query)” on YouTube.", nil)
            default:
                open(URL(string: "https://music.apple.com/search?term=\(qEnc)")!); done("Looking up “\(query)” in Apple Music.", nil)
            }
        case .searchInBrowser(let query):
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            open(c.url!); done("Searching for “\(query)”.", nil)
        case .savePage(let note):
            savePage(note: note, front: front, done: done)
        }
        return true
    }

    /// The browser extension saves the active tab (selection + text-fragment backlink, or the page
    /// and its URL). Without it: the selected text in the app in front, titled with its window.
    func savePage(note: String?, front: NSRunningApplication?, done: @escaping @MainActor (String, HighlightItem?) -> Void) {
        if CommandLine.arguments.contains("--selftest") { selfTestOpened.append("save"); done("(self-test) would save the page", nil); return }
        if app.bridge.connected, AX.isChromium(front) || front == nil {
            app.bridge.savePage(note: note) { [weak self] reply in
                if let r = reply, r.ok == true {
                    let item = HighlightItem(id: "", text: r.text ?? "", url: r.url, title: r.title, fragmentUrl: r.link)
                    done("Saved “\(r.title ?? "this page")” to your notes. The link takes you back to it.", item)
                } else {
                    self?.saveSelection(note: note, front: front, done: done, why: reply?.error)
                }
            }
            return
        }
        saveSelection(note: note, front: front, done: done, why: nil)
    }

    func saveSelection(note: String?, front: NSRunningApplication?, done: @escaping @MainActor (String, HighlightItem?) -> Void, why: String?) {
        let pid = front?.processIdentifier ?? 0
        let sel = AX.trusted ? AX.selectedText(pid: pid)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        // a browser in front: its page address and title, read through Accessibility (no extension needed)
        if AX.trusted { AX.enableWebAccessibility(for: front) }
        let page = AX.trusted ? AX.webPage(pid: pid) : nil
        Debug.log("save: front \(front?.bundleIdentifier ?? "none") bridge \(app.bridge.connected) ax \(AX.trusted) page \(page != nil) selection \(sel != nil)")
        if let page {
            let text = [note, sel ?? page.title ?? page.url.absoluteString].compactMap { $0 }.joined(separator: "\n\n")
            Task { @MainActor in
                do {
                    let h = try await app.client.saveNote(text, title: page.title, folder: nil, url: page.url.absoluteString)
                    done("Saved “\(page.title ?? page.url.host ?? "this page")” to your notes. The link takes you back to it.", h)
                } catch { done("I couldn't save that: \((error as? MemoryError)?.detail ?? error.localizedDescription)", nil) }
            }
            return
        }
        guard let text = sel, !text.isEmpty else {
            done(why == "no web page in front"
                 ? "There's no web page in front. Open the article, then say “save this”."
                 : "Select what to save first" + (app.bridge.connected ? "." : ", or connect the Chrome extension to save whole pages with a link back."), nil)
            return
        }
        let window = AX.focusedWindow(pid: pid).flatMap { AX.attr($0, kAXTitleAttribute) as String? }
        let title = window ?? front?.localizedName
        let body = note.map { "\($0)\n\n\(text)" } ?? text
        Task { @MainActor in
            do {
                let h = try await app.client.saveNote(body, title: title, folder: nil)
                done("Saved to your notes" + (title.map { " from “\($0)”" } ?? "") + ".", h)
            } catch { done("I couldn't save that: \((error as? MemoryError)?.detail ?? error.localizedDescription)", nil) }
        }
    }

    func open(_ url: URL) {
        if CommandLine.arguments.contains("--selftest") { selfTestOpened.append(url.absoluteString); return }
        NSWorkspace.shared.open(url)
    }

    func launch(_ appURL: URL) {
        if CommandLine.arguments.contains("--selftest") { selfTestOpened.append(appURL.lastPathComponent); return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// For the debug log: what kind of request, never its text.
    static func kind(_ i: PixlIntent) -> String {
        switch i {
        case .open: "open app"; case .openURL: "open url"; case .play: "play"; case .searchInBrowser: "browser search"
        case .savePage: "save page"; case .ask: "ask"
        }
    }
}
