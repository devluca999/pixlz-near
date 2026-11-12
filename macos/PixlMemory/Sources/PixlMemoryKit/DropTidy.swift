import Foundation

/// A polished text dragged into the draft lands where it is dropped: usually inside the text it
/// was made from, which it splits ("hey s" + polished + "o basically…"). This finds the stretch
/// to put right: the original, whole or split around the dropped text, with the dropped text.
public enum DropTidy {
    /// The range of `value` (UTF-16, as Accessibility counts) that holds `dropped` together with
    /// `original` right around it: before it, after it, or split by it. Writing `dropped` over
    /// that range leaves the polished text in the original's place.
    /// Nil when the original isn't there intact, or when more than one reading fits: then
    /// nothing should be touched.
    public static func range(in value: String, original: String, dropped: String) -> NSRange? {
        let v = value as NSString, o = original as NSString, d = dropped as NSString
        guard o.length > 0, d.length > 0 else { return nil }
        var found: NSRange?
        var from = 0
        while from < v.length {
            let r = v.range(of: dropped, options: .literal, range: NSRange(location: from, length: v.length - from))
            guard r.location != NSNotFound else { break }
            let after = r.location + r.length
            for k in 0...o.length where r.location >= k && after + o.length - k <= v.length {   // k: how much of the original sits before the drop
                let head = NSRange(location: r.location - k, length: k), tail = NSRange(location: after, length: o.length - k)
                guard v.substring(with: head) == o.substring(to: k), v.substring(with: tail) == o.substring(from: k) else { continue }
                let whole = NSRange(location: head.location, length: o.length + d.length)
                if let f = found, f != whole { return nil }
                found = whole
            }
            from = r.location + 1
        }
        return found
    }
}
