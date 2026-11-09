import AppKit
import PixlBridge
import PixlMemoryKit

/// Carries out what a typed request asks for when no model is needed (PixlIntent): opening an
/// app or a site, playing something, a browser search, saving the page in front. Nothing here
/// is sent anywhere except the saved text, which goes to the local memory service.
/// What a request did: what the Pixl says, and what it saved or found (shown with backlinks).
struct IntentReply {
    var said: String
    var items: [HighlightItem] = []
    /// Items found in memory (recall) rather than just saved.
    var found = false
}

@MainActor
final class IntentRunner {
    unowned let app: AppController
    var finder = AppFinder()
    /// What the self-test asked for, instead of really opening anything.
    var selfTestOpened: [String] = []
    /// Interim status while a request takes a moment ("Reading the page…").
    var progress: (@MainActor (String) -> Void)?

    init(app: AppController) { self.app = app }

    /// Handles `q` if it's an action; `done` gets what to say and, for a save, what was saved.
    /// Returns false for a question (it goes to Ask).
    func run(_ q: String, front: NSRunningApplication?, done: @escaping @MainActor (IntentReply) -> Void) -> Bool {
        let intent = PixlIntent.parse(q)
        Debug.log("intent: \(Self.kind(intent))")
        return perform(intent, front: front, done: done)
    }

    func perform(_ intent: PixlIntent, front: NSRunningApplication?, done reply: @escaping @MainActor (IntentReply) -> Void) -> Bool {
        let done: @MainActor (String, HighlightItem?) -> Void = { said, item in reply(IntentReply(said: said, items: item.map { [$0] } ?? [])) }
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
        case .savePart(let about):
            savePart(about: about, front: front, done: reply)
        case .openAndSavePart(let first, let about):
            openThenSave(first, about: about, done: reply)
        case .recall(let topic):
            recall(topic, done: reply)
        }
        return true
    }

    // MARK: the part about a topic

    /// Reads the page in front (the extension, else Accessibility), finds the passage about
    /// `about`, and saves it with a link that opens the page at that passage.
    func savePart(about: String, front: NSRunningApplication?, done: @escaping @MainActor (IntentReply) -> Void) {
        if CommandLine.arguments.contains("--selftest") { selfTestOpened.append("save part"); done(IntentReply(said: "(self-test) would save the part")); return }
        progress?("Reading the page…")
        readPage(front: front) { [weak self] page in
            guard let self else { return }
            guard let page else {
                done(IntentReply(said: "I can't read the page in front. Open the article in your browser, then ask again."))
                return
            }
            let name = page.title ?? page.url.host ?? "this page"
            guard let passage = PassageFinder.best(blocks: page.blocks, about: about) else {
                Debug.log("save part: \(page.blocks.count) blocks, no match")
                done(IntentReply(said: "I read “\(name)” but couldn't find a part about \(about). Select it and say “save this”."))
                return
            }
            let link = TextFragment.link(page: page.url, passage: passage)
            Debug.log("save part: \(page.blocks.count) blocks, passage \(passage.count) chars, link \(link != nil)")
            Task { @MainActor in
                do {
                    let h = try await self.app.client.saveNote(passage, title: page.title, folder: nil, url: page.url.absoluteString,
                                                               fragmentURL: link?.absoluteString)
                    done(IntentReply(said: "Saved the part about \(about) from “\(name)”. The link opens the page right at it.", items: [h]))
                } catch { done(IntentReply(said: "I couldn't save that: \((error as? MemoryError)?.detail ?? error.localizedDescription)")) }
            }
        }
    }

    struct Page { var url: URL; var title: String?; var blocks: [String] }

    /// The page in the browser in front: from the extension when it's connected, else Accessibility.
    func readPage(front: NSRunningApplication?, done: @escaping @MainActor (Page?) -> Void) {
        let viaAX = { [weak self] in
            guard self != nil, AX.trusted, let pid = front?.processIdentifier else {
                Debug.log("read page: no accessibility (trusted \(AX.trusted), front \(front != nil))"); done(nil); return
            }
            // Chromium builds its page tree only once asked: ask, and give it a moment the first time
            let fresh = AX.enableWebAccessibility(for: front)
            DispatchQueue.main.asyncAfter(deadline: .now() + (fresh ? 0.8 : 0)) { MainActor.assumeIsolated {
                let p = AX.pageText(pid: pid)
                Debug.log("read page: accessibility \(p?.blocks.count ?? -1) blocks from \(front?.bundleIdentifier ?? "?") fresh \(fresh)")
                done(p.map { Page(url: $0.url, title: $0.title, blocks: $0.blocks) })
            } }
        }
        if app.bridge.connected, front == nil || AX.isChromium(front) {
            app.bridge.pageText { url, title, blocks in
                Debug.log("read page: extension \(blocks.count) blocks")
                if let url, !blocks.isEmpty { done(Page(url: url, title: title, blocks: blocks)) } else { viaAX() }
            }
        } else {
            viaAX()
        }
    }

    /// "go to <page> and save the part about <topic>": opens it in the browser, waits until the
    /// page has loaded (its address settles, its text mentions something), then saves the part.
    func openThenSave(_ first: PixlIntent, about: String, done: @escaping @MainActor (IntentReply) -> Void) {
        let url: URL
        switch first {
        case .openURL(let u): url = u
        case .open(let name, let web, _):
            if let web { url = web } else {
                var c = URLComponents(string: "https://duckduckgo.com/")!
                c.queryItems = [URLQueryItem(name: "q", value: "\\" + name)]   // the top result for it
                url = c.url!
            }
        default: done(IntentReply(said: "I can only open a web page for that.")); return
        }
        if CommandLine.arguments.contains("--selftest") { selfTestOpened.append(url.absoluteString); savePart(about: about, front: nil, done: done); return }
        let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        progress?("Opening \(url.host == "duckduckgo.com" ? "the page" : url.host ?? "the page")…")
        open(url)
        let started = Date()
        var lastURL: URL?, steady = 0
        func poll() {
            let front = browser.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            if AX.trusted { AX.enableWebAccessibility(for: front) }   // Chromium builds its page tree only when asked
            let current: URL? = front.flatMap { AX.trusted ? AX.webPage(pid: $0.processIdentifier)?.url : nil }
            if let c = current, c.host != "duckduckgo.com", c == lastURL { steady += 1 } else { steady = 0 }
            lastURL = current
            let waited = Date().timeIntervalSince(started)
            // settled for ~1 s, or (no Accessibility to watch with) a fixed wait
            if steady >= 2 || (!AX.trusted && waited > 4) || waited > 15 {
                self.progress?("Reading the page…")
                self.readUntilFound(about: about, front: front, tries: 3, done: done)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { poll() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { poll() } }
    }

    /// A page can still be filling in: a few reads, a second apart, before giving up on the topic.
    func readUntilFound(about: String, front: NSRunningApplication?, tries: Int, done: @escaping @MainActor (IntentReply) -> Void) {
        readPage(front: front) { [weak self] page in
            guard let self else { return }
            let found = page.map { PassageFinder.best(blocks: $0.blocks, about: about) != nil } ?? false
            if found || tries <= 1 {
                self.savePart(about: about, front: front, done: done)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated {
                    self.readUntilFound(about: about, front: front, tries: tries - 1, done: done)
                } }
            }
        }
    }

    // MARK: recall

    /// "what did I save about X": the user's saves, ranked on the Mac (no model, nothing sent).
    func recall(_ topic: String, done: @escaping @MainActor (IntentReply) -> Void) {
        Task { @MainActor in
            let all = await app.client.highlights(limit: 500)
            let hits = Recall.rank(all, about: topic, limit: 3)
            Debug.log("recall: \(all.count) saves, \(hits.count) hits")
            let said: String
            if all.isEmpty { said = "You haven't saved anything yet. On any page, say “save this”." }
            else if topic.isEmpty { said = "Your latest saves:" }
            else if hits.isEmpty { said = "Nothing saved about \(topic) yet." }
            else { said = hits.count == 1 ? "You saved one thing about \(topic):" : "You saved \(hits.count) things about \(topic). Here they are, newest first:" }
            done(IntentReply(said: said, items: hits, found: true))
        }
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
        case .savePart: "save part"; case .openAndSavePart: "open and save part"; case .recall: "recall"
        }
    }
}
