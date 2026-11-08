import AppKit

public enum DiffText {
    /// Deletions struck through in red, insertions in green; the rest in ink.
    public static func attributed(_ ops: [DiffOp], size: CGFloat = 13) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.text,
                                                   .paragraphStyle: para]
        for op in ops {
            var a = base
            switch op.op {
            case .equal: break
            case .delete:
                a[.foregroundColor] = Theme.failed
                a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                a[.strikethroughColor] = Theme.failed
                a[.backgroundColor] = Theme.deleteBG
            case .insert:
                a[.foregroundColor] = Theme.verified
                a[.font] = NSFont.systemFont(ofSize: size, weight: .semibold)
                a[.backgroundColor] = Theme.insertBG
            }
            out.append(NSAttributedString(string: op.text, attributes: a))
        }
        return out
    }

    /// Words added and removed, for the panel header.
    public static func stats(_ ops: [DiffOp]) -> (added: Int, removed: Int) {
        func words(_ s: String) -> Int { s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count }
        return (ops.filter { $0.op == .insert }.map { words($0.text) }.reduce(0, +),
                ops.filter { $0.op == .delete }.map { words($0.text) }.reduce(0, +))
    }
}
