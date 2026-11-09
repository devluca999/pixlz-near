import Foundation

/// Words that say nothing about a topic ("the part about *how* *the* frog …").
let stopwords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "about", "how", "what",
                              "why", "when", "where", "who", "which", "is", "are", "was", "were", "be", "it", "its", "this",
                              "that", "these", "those", "their", "they", "them", "his", "her", "my", "your", "our", "do",
                              "does", "did", "can", "from", "by", "as", "at", "into", "part", "bit", "section", "says", "say",
                              "talks", "talk", "anything", "something", "stuff", "thing", "things", "i", "me", "you"]

/// Lower-cased content words with a light stem ("frogs" → "frog", "living" → "liv"), for matching
/// a topic against text without a model.
public func topicTerms(_ s: String) -> [String] {
    let words = s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    var out: [String] = []
    for w in words where !stopwords.contains(w) && (w.count > 1 || w.first?.isNumber == true) {
        let t = stem(w)
        if !out.contains(t) { out.append(t) }
    }
    return out
}

func stem(_ w: String) -> String {
    for suffix in ["ing", "ies", "es", "ed", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
        return suffix == "ies" ? String(w.dropLast(3)) + "y" : String(w.dropLast(suffix.count))
    }
    return w
}

/// How well `text` covers `terms`: each term found counts once (rarer, longer words a little more),
/// a phrase match counts double. 0 means no term at all.
func coverage(_ text: String, terms: [String], phrase: String) -> Double {
    guard !terms.isEmpty else { return 0 }
    let words = Set(text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { stem(String($0)) })
    var score = 0.0
    for t in terms where words.contains(t) { score += 1 + Double(min(t.count, 10)) / 20 }
    if score > 0, terms.count > 1, text.lowercased().contains(phrase) { score *= 2 }
    return score
}

/// Picks the passage of a page that's about a topic, from its text blocks (paragraphs, headings,
/// list items in reading order). No model: the page never leaves the Mac to be read.
public enum PassageFinder {
    /// The best passage and how many topic words it covers, or nil when nothing on the page mentions the topic.
    public static func best(blocks raw: [String], about topic: String, maxChars: Int = 900) -> String? {
        let terms = topicTerms(topic)
        guard !terms.isEmpty else { return nil }
        let phrase = topic.lowercased().trimmingCharacters(in: .whitespaces)
        let blocks = raw.map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
        var bestScore = 0.0, bestIndex = -1
        for (i, b) in blocks.enumerated() where b.count >= 2 {
            var s = coverage(b, terms: terms, phrase: phrase)
            if s == 0 { continue }
            // a heading names the topic; the paragraph under it is the part about it
            if isHeading(b), i + 1 < blocks.count { s = s * 0.9 + coverage(blocks[i + 1], terms: terms, phrase: phrase) * 0.5 }
            // prose beats a stray link or caption, but a huge block isn't better for being huge
            s += min(Double(b.count), 400) / 800
            if s > bestScore { bestScore = s; bestIndex = i }
        }
        guard bestIndex >= 0 else { return nil }
        var passage = blocks[bestIndex]
        // a heading on its own: take the paragraph(s) under it
        if isHeading(passage) {
            var j = bestIndex + 1
            var body: [String] = []
            while j < blocks.count, !isHeading(blocks[j]), body.joined(separator: " ").count < maxChars / 2 {
                if blocks[j].count > 1 { body.append(blocks[j]) }
                j += 1
            }
            if !body.isEmpty { passage = body.joined(separator: " ") }
        }
        return trim(passage, terms: terms, maxChars: maxChars)
    }

    /// Short and without closing punctuation: a heading, not prose.
    static func isHeading(_ s: String) -> Bool {
        s.count < 80 && !s.hasSuffix(".") && !s.hasSuffix("?") && !s.hasSuffix("!") && !s.hasSuffix(":") && s.split(separator: " ").count <= 10
    }

    /// A long block cut to the sentences around the topic, whole sentences only.
    static func trim(_ text: String, terms: [String], maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let sentences = splitSentences(text)
        guard sentences.count > 1 else { return String(text.prefix(maxChars)) }
        let scores = sentences.map { coverage($0, terms: terms, phrase: "") }
        let start = scores.indices.max { scores[$0] < scores[$1] } ?? 0
        var lo = start, hi = start
        var length = sentences[start].count
        while true {
            let next = hi + 1 < sentences.count ? sentences[hi + 1].count + 1 : Int.max
            let prev = lo > 0 ? sentences[lo - 1].count + 1 : Int.max
            if next <= prev, length + next <= maxChars { hi += 1; length += next }
            else if prev < Int.max, length + prev <= maxChars { lo -= 1; length += prev }
            else { break }
        }
        return sentences[lo...hi].joined(separator: " ")
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { out.append(s) }
        }
        return out
    }
}

/// Links that open a page scrolled to (and highlighting) a passage: `#:~:text=start,end`
/// (https://wicg.github.io/scroll-to-text-fragment/). Same rules as the extension's fragment.js.
public enum TextFragment {
    public static func link(page: URL, passage: String) -> URL? {
        let words = passage.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, var c = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        guard let base = c.url?.absoluteString else { return nil }
        let edge = { (ws: ArraySlice<String>) in clean(ws.joined(separator: " ")) }
        let term: String
        if passage.count <= 80 || words.count <= 8 {
            term = encode(edge(words[...]))
        } else {
            term = encode(edge(words.prefix(4))) + "," + encode(edge(words.suffix(4)))
        }
        guard !term.isEmpty, term != "," else { return nil }
        return URL(string: base + "#:~:text=" + term)
    }

    /// Strips punctuation at the ends: a fragment only matches at word boundaries.
    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Percent-encodes one term; "-", "," and "&" are delimiters in the syntax.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "-,&#=?+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Finds saved notes about a topic (the user's own library, decrypted locally by the service).
public enum Recall {
    public static func rank(_ items: [HighlightItem], about topic: String, limit: Int = 3) -> [HighlightItem] {
        let terms = topicTerms(topic)
        guard !terms.isEmpty else { return Array(items.prefix(limit)) }
        let phrase = topic.lowercased()
        let scored = items.enumerated().compactMap { i, h -> (HighlightItem, Double, Int)? in
            let hay = [h.title, h.text, h.url, h.folder].compactMap { $0 }.joined(separator: " ")
            let s = coverage(hay, terms: terms, phrase: phrase)
            // most of the topic, not one stray word of a long question
            let needed = terms.count <= 2 ? 1.0 : Double(terms.count) * 0.5
            return s >= needed ? (h, s, i) : nil
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.prefix(limit).map(\.0)
    }
}
