import Foundation

/// What a typed request to the Pixl asks for. Parsed on the Mac, before anything is sent:
/// opening an app or a site, and saving the page in front, happen here without a model.
/// Everything else is a question for Ask (privately, with web search when it helps).
public enum PixlIntent: Equatable, Sendable {
    /// Open an app by name; `web` is its website when the app isn't installed (or `preferWeb`).
    case open(name: String, web: URL?, preferWeb: Bool)
    /// Open a web address in the default browser.
    case openURL(URL)
    /// Play something on Spotify (the app if installed, else the web player).
    case play(query: String, app: String)
    /// A web search in the browser ("google …").
    case searchInBrowser(String)
    /// Save the page in front (its selection if there is one) to memory, with a backlink.
    case savePage(note: String?)
    /// Save the passage of the page in front that's about a topic, linked to that exact spot.
    case savePart(about: String)
    /// Open a page (an `.open` or `.openURL`), wait for it, then save the part about a topic.
    indirect case openAndSavePart(open: PixlIntent, about: String)
    /// Find what the user saved about a topic ("" = the latest saves). Read locally.
    case recall(String)
    /// Anything else: a question for Ask.
    case ask(String)

    public static func parse(_ raw: String) -> PixlIntent { parse(raw, inCompound: false) }

    static func parse(_ raw: String, inCompound: Bool) -> PixlIntent {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = original.lowercased()
        s = s.replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        // "hey frogg, could you please …" → "…"
        let lead = #"^(hey|hi|ok|okay|yo)?\s*[\w'-]*,\s*|^(please|pls|can you|could you|would you|will you|i want you to|go ahead and)\s+"#
        while let r = s.range(of: lead, options: .regularExpression), !r.isEmpty { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"\s+(please|pls|for me|real quick|now)$"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)

        // "go to <page> and save the part about <topic>": two steps, one request
        if !inCompound, let m = s.firstMatch(#"^(.+?)\s*,?\s+(and|then|and then)\s+((save|clip|grab|keep|remember|store|copy)\s+.+)$"#) {
            let first = parse(Self.keepCase(m[1], from: original), inCompound: true)
            let second = parse(Self.keepCase(m[3], from: original), inCompound: true)
            if case .savePart(let about) = second {
                switch first {
                case .open, .openURL: return .openAndSavePart(open: first, about: about)
                default: break
                }
            }
        }
        // what did I save about X
        let recallPatterns = [
            #"^(what|which)\s+(did|have)\s+i\s+(saved|save|clipped|clip|kept|keep|stored|store|bookmarked|bookmark)(\s+(about|on|regarding|for|from))?\s*(?<t>.*)$"#,
            #"^did\s+i\s+(save|clip|keep|store|bookmark)\s+anything\s+(about|on|regarding|from)\s+(?<t>.+)$"#,
            #"^(find|show|show me|search|search for|get|list|look in|look through|check)\s+(me\s+)?(my|the)\s+(notes|saves|saved stuff|saved things|saved notes|highlights|clips|bookmarks|memory)(\s+(about|on|for|regarding|from|that mention))?\s*(?<t>.*)$"#,
            #"^(my\s+)?(notes|saves|highlights)\s+(about|on|regarding)\s+(?<t>.+)$"#,
        ]
        for p in recallPatterns {
            if let re = try? NSRegularExpression(pattern: p), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(withName: "t"), in: s) {
                return .recall(Self.keepCase(String(s[r]).trimmingCharacters(in: .whitespaces), from: original))
            }
        }
        // save the part about X (before "save this": "save the …" would match that)
        if let m = s.firstMatch(#"^(save|clip|grab|keep|remember|store|bookmark|copy)\s+(the\s+|a\s+)?(part|parts|bit|bits|section|paragraph|passage|piece|stuff|lines?|sentences?|quote|info|information|what (it|they|this|this page|the page|the article) says?)\s+(about|on|regarding|that talks about|where it talks about|where they talk about|that mentions|mentioning|explaining|that explains|describing|on how|of)\s+(.+)$"#) {
            return .savePart(about: Self.keepCase(m[6], from: original))
        }
        // save the page in front
        if let m = s.firstMatch(#"^(save|remember|bookmark|keep|store|clip)\s+(this|that|it|the|this page|this article|this tab|this link|this site|a reference|a note|this reference)\b(.*)$"#) {
            let rest = m[3].trimmingCharacters(in: .whitespaces)
            let note = rest.replacingOccurrences(of: #"^(page|article|tab|link|site|reference|note|to (my )?(notes|memory))\b\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^(as|with( the)? note|because|:|-|—)\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return .savePage(note: note.isEmpty ? nil : Self.keepCase(note, from: original))
        }
        // play X on spotify
        if let m = s.firstMatch(#"^(play|put on)\s+(.+?)\s+on\s+(spotify|apple music|music|youtube)$"#) {
            return .play(query: Self.keepCase(m[2], from: original), app: m[3])
        }
        // google X / search google for X
        if let m = s.firstMatch(#"^(google|search google for|look up on google)\s+(.+)$"#) {
            return .searchInBrowser(Self.keepCase(m[2], from: original))
        }
        // open / launch / go to / take me to X [in the browser | in a new tab]
        if let m = s.firstMatch(#"^(open( up)?|launch|start|run|go to|take me to|pull up|bring up|navigate to|visit|load)\s+(.+)$"#) {
            var target = m[3]
            var preferWeb = false
            if let r = target.range(of: #"\s+(in|on)\s+(a\s+)?(new\s+)?(the\s+)?(browser|tab|chrome|safari|web|website|web browser)$|\s+(website|site|web ?page|tab)$|\s+\.com$"#, options: .regularExpression) {
                preferWeb = true
                target.removeSubrange(r)
            }
            target = target.replacingOccurrences(of: #"^(the|my|a new tab (for|with|to)|a tab (for|with|to)|up)\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+(app|application)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return .ask(original) }
            if let url = Self.webAddress(Self.keepCase(target, from: original)) { return .openURL(url) }
            if let url = Self.wikipedia(target, original: original) { return .openURL(url) }
            // a long phrase: a question, not an app name (in "go to … and save …" it's a page to find)
            if target.split(separator: " ").count > 3 {
                return inCompound ? .open(name: Self.keepCase(target, from: original), web: nil, preferWeb: true) : .ask(original)
            }
            return .open(name: Self.keepCase(target, from: original), web: Self.knownSites[target], preferWeb: preferWeb)
        }
        return .ask(original)
    }

    /// "the wikipedia page for glass frogs", "glass frogs on wikipedia" → Wikipedia's article for it.
    static func wikipedia(_ target: String, original: String) -> URL? {
        let topic = target.firstMatch(#"^(the\s+)?wikipedia(\s+(page|article|entry))?\s+(for|on|about|of)\s+(.+)$"#)?[5]
            ?? target.firstMatch(#"^(the\s+)?(.+?)\s+(page\s+|article\s+)?(on|from)\s+wikipedia$"#)?[2]
        guard let topic, !topic.isEmpty else { return nil }
        var c = URLComponents(string: "https://en.wikipedia.org/w/index.php")!
        c.queryItems = [URLQueryItem(name: "search", value: keepCase(topic, from: original)), URLQueryItem(name: "go", value: "Go")]
        return c.url
    }

    /// "spotify.com", "https://x.com/foo", "news.ycombinator.com" → a URL; a plain word → nil.
    public static func webAddress(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" ") else { return nil }
        if t.hasPrefix("http://") || t.hasPrefix("https://") { return URL(string: t) }
        guard t.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|io|ai|app|dev|co|edu|gov|me|tv|fm|xyz|news|uk|de|fr|ca|us)(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return URL(string: "https://" + t)
    }

    /// Sites people ask for by name, opened when there's no app of that name (or a tab is asked for).
    public static let knownSites: [String: URL] = [
        "spotify": "https://open.spotify.com", "youtube": "https://www.youtube.com", "youtube music": "https://music.youtube.com",
        "gmail": "https://mail.google.com", "google": "https://www.google.com", "google docs": "https://docs.google.com",
        "google drive": "https://drive.google.com", "google calendar": "https://calendar.google.com", "calendar": "https://calendar.google.com",
        "google maps": "https://maps.google.com", "maps": "https://maps.google.com", "github": "https://github.com",
        "twitter": "https://x.com", "x": "https://x.com", "reddit": "https://www.reddit.com", "netflix": "https://www.netflix.com",
        "linkedin": "https://www.linkedin.com", "instagram": "https://www.instagram.com", "facebook": "https://www.facebook.com",
        "wikipedia": "https://www.wikipedia.org", "hacker news": "https://news.ycombinator.com", "notion": "https://www.notion.so",
        "figma": "https://www.figma.com", "slack": "https://app.slack.com", "discord": "https://discord.com/app",
        "chatgpt": "https://chatgpt.com", "claude": "https://claude.ai", "near": "https://near.org", "near ai": "https://near.ai",
        "amazon": "https://www.amazon.com", "twitch": "https://www.twitch.tv", "soundcloud": "https://soundcloud.com",
        "apple music": "https://music.apple.com", "whatsapp": "https://web.whatsapp.com", "outlook": "https://outlook.live.com",
    ].compactMapValues(URL.init(string:))

    /// The user's own capitalisation of `lowered` (a piece of `original`), when it's there.
    static func keepCase(_ lowered: String, from original: String) -> String {
        if let r = original.range(of: lowered, options: .caseInsensitive) { return String(original[r]) }
        return lowered
    }
}

/// Finds an installed app by the name someone said ("spotify", "vs code", "notes").
public struct AppFinder: Sendable {
    public var folders: [URL]
    public init(folders: [URL] = AppFinder.defaultFolders) { self.folders = folders }

    public static var defaultFolders: [URL] {
        let fm = FileManager.default
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
                "/System/Library/CoreServices/Applications"].map { URL(fileURLWithPath: $0) }
    }

    /// Spoken names that differ from the bundle's name.
    static let aliases: [String: String] = ["vs code": "visual studio code", "vscode": "visual studio code", "code": "visual studio code",
                                            "chrome": "google chrome", "settings": "system settings", "preferences": "system settings",
                                            "app store": "app store", "word": "microsoft word", "excel": "microsoft excel",
                                            "powerpoint": "microsoft powerpoint", "teams": "microsoft teams", "outlook": "microsoft outlook",
                                            "terminal": "terminal", "music": "music", "itunes": "music"]

    /// The best match: exact name, then a name that starts with it, then one that contains it as a word.
    public func find(_ spoken: String) -> URL? {
        let want = Self.norm(Self.aliases[spoken.lowercased()] ?? spoken)
        guard !want.isEmpty else { return nil }
        var apps: [(name: String, url: URL)] = []
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for u in items where u.pathExtension == "app" { apps.append((Self.norm(u.deletingPathExtension().lastPathComponent), u)) }
        }
        if let hit = apps.first(where: { $0.name == want }) { return hit.url }
        if want.count >= 3, let hit = apps.filter({ $0.name.hasPrefix(want + " ") || $0.name.hasPrefix(want) }).min(by: { $0.name.count < $1.name.count }) { return hit.url }
        if want.count >= 4, let hit = apps.first(where: { (" " + $0.name + " ").contains(" " + want + " ") }) { return hit.url }
        return nil
    }

    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    /// The capture groups of the first match (index 0 is the whole match), or nil.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: self).map { String(self[$0]) } ?? "" }
    }
}
