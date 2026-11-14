import Foundation

/// A picture of something an answer names (a landmark, an animal, a person), from Wikipedia.
public struct AnswerPicture: Sendable, Equatable {
    public var subject: String
    public var title: String
    public var thumb: URL
    public var page: URL
    public init(subject: String, title: String, thumb: URL, page: URL) {
        self.subject = subject; self.title = title; self.thumb = thumb; self.page = page
    }
}

/// Pictures for an answer that lists things ("Chicago landmarks" → Willis Tower, Cloud Gate, …).
/// Only the names the answer lists are looked up, on Wikipedia; the question isn't sent.
/// Opt-in (Settings › Privacy & Memory › Pictures for answers): see `shouldFetch`.
public enum AnswerPictures {
    /// Whether to look up pictures for this answer at all. Only when you turned it on in
    /// Settings (it sends the names an answer lists to Wikipedia), and never for an answer
    /// drawn from your saved highlights (their names are yours, not the web's).
    public static func shouldFetch(for r: AskResult, enabled: Bool) -> Bool {
        enabled && (r.highlights ?? []).isEmpty
    }

    /// The things an answer lists: its bold names, else the lead of each list item
    /// ("- Navy Pier: a lakefront …" → "Navy Pier"). At least two, or nothing: one bold word
    /// in a paragraph isn't a list of things to picture.
    public static func subjects(in answer: String, limit: Int = 6) -> [String] {
        var out: [String] = []
        func add(_ raw: String) {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":–—-,.*"))
            s = s.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)   // "Cloud Gate (The Bean)"
                .trimmingCharacters(in: .whitespaces)
            let words = s.split(separator: " ").count
            guard words >= 1, words <= 6, s.count >= 3, s.first?.isUppercase == true || s.first?.isNumber == true,
                  !out.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) else { return }
            out.append(s)
        }
        for m in matches(#"\*\*([^*\n]{2,60})\*\*"#, in: answer) { add(m) }
        if out.count < 2 {
            out.removeAll()
            for m in matches(#"(?m)^\s*(?:[-•*]|\d+[.)])\s+(?:\*\*)?([^:\n–—]{2,60}?)(?:\*\*)?\s*(?::|–|—| - )"#, in: answer) { add(m) }
        }
        return out.count >= 2 ? Array(out.prefix(limit)) : []
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }

    /// Wikipedia's best page for `subject` and its lead image, in one request.
    public static func searchURL(_ subject: String, size: Int = 320) -> URL {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "formatversion", value: "2"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: subject), .init(name: "gsrlimit", value: "1"),
            .init(name: "prop", value: "pageimages|info"), .init(name: "piprop", value: "thumbnail"),
            .init(name: "pithumbsize", value: String(size)), .init(name: "inprop", value: "url"),
        ]
        return c.url!
    }

    /// Reads a search reply; nil when the page has no picture.
    public static func parse(_ data: Data, subject: String) -> AnswerPicture? {
        struct Reply: Decodable {
            struct Query: Decodable { let pages: [Page]? }
            struct Page: Decodable {
                struct Thumb: Decodable { let source: String }
                let title: String; let fullurl: String?; let thumbnail: Thumb?
            }
            let query: Query?
        }
        guard let r = try? JSONDecoder().decode(Reply.self, from: data), let p = r.query?.pages?.first,
              let t = p.thumbnail.flatMap({ URL(string: $0.source) }), let page = p.fullurl.flatMap(URL.init(string:)),
              !isEmblem(t) else { return nil }   // maps, flags, logos: not a picture of the thing
        return AnswerPicture(subject: subject, title: p.title, thumb: t, page: page)
    }

    /// A logo, map, flag or seal (often an SVG drawn to PNG) rather than a photo.
    static func isEmblem(_ u: URL) -> Bool {
        let name = u.lastPathComponent.lowercased()
        return name.hasSuffix(".svg.png") || name.range(of: #"logo|wordmark|emblem|seal_of|flag_of|coat_of_arms|locator|_map|map_"#, options: .regularExpression) != nil
    }

    /// Looks every subject up at once; the pictures come back in the answer's order.
    public static func find(for answer: String, session: URLSession = .shared) async -> [AnswerPicture] {
        let names = subjects(in: answer)
        guard !names.isEmpty else { return [] }
        var found: [Int: AnswerPicture] = [:]
        await withTaskGroup(of: (Int, AnswerPicture?).self) { g in
            for (i, n) in names.enumerated() {
                g.addTask {
                    var r = URLRequest(url: searchURL(n), timeoutInterval: 6)
                    r.setValue("PixlMemory/1.0 (desktop pet; pictures for answers)", forHTTPHeaderField: "User-Agent")
                    guard let (d, resp) = try? await session.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return (i, nil) }
                    return (i, parse(d, subject: n))
                }
            }
            for await (i, p) in g { if let p { found[i] = p } }
        }
        // two names can land on the same page ("The Bean", "Cloud Gate")
        var seen = Set<URL>()
        return found.keys.sorted().compactMap { found[$0] }.filter { seen.insert($0.page).inserted }
    }
}
