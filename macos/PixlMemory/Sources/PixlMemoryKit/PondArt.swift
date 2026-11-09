import AppKit

/// Frogg's pond (C14): per frame a layer behind Frogg (the far rim and water, Frogg's under-water
/// body, the ripple ring), a waterline mask (where Frogg shows normally) and a layer in front (the
/// near rim and effects). The app draws: behind → Frogg's pose clipped by the mask → over.
@MainActor
public final class PondArt {
    public struct Frame {
        public let title: String
        public let ms: Int
        public let behind: [String]
        public let over: [String]
        public let mask: [String]
        public let sprite: (frame: String, x: Int, y: Int)?
        public let bank: Bool
    }

    public let width: Int
    public let height: Int
    /// Frogg's feet in pond pixels.
    public let anchor: CGPoint
    /// The sleep loop (C14: 4 frames at 2 fps).
    public let loop: ClosedRange<Int>
    public let frames: [Frame]
    let colors: [Character: (UInt8, UInt8, UInt8)]
    var cache: [String: CGImage] = [:]

    public static let shared: PondArt? = PondArt(json: pixlPondJSON)

    init?(json: String) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let w = d["w"] as? Int, let h = d["h"] as? Int, let a = d["anchor"] as? [Double], let l = d["loop"] as? [Int],
              let chars = d["chars"] as? String, let pal = d["palette"] as? [String], let fs = d["frames"] as? [[String: Any]] else { return nil }
        width = w; height = h; anchor = CGPoint(x: a[0], y: a[1]); loop = l[0]...l[1]
        var c: [Character: (UInt8, UInt8, UInt8)] = [:]
        for (ch, hex) in zip(chars, pal) {
            let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
            c[ch] = (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
        }
        colors = c
        frames = fs.map { f in
            let s = f["sprite"] as? [String: Any]
            return Frame(title: f["title"] as? String ?? "", ms: f["ms"] as? Int ?? 500,
                         behind: (f["behind"] as? [String] ?? []).map(Self.expand), over: (f["over"] as? [String] ?? []).map(Self.expand),
                         mask: (f["mask"] as? [String] ?? []).map(Self.expand),
                         sprite: s.flatMap { s in (s["frame"] as? String).map { ($0, s["x"] as? Int ?? 0, s["y"] as? Int ?? 0) } },
                         bank: f["bank"] as? Bool ?? false)
        }
    }

    /// "~<char><count>|" back to the run it stands for.
    static func expand(_ row: String) -> String {
        guard row.contains("~") else { return row }
        var out = "", it = row.makeIterator()
        while let c = it.next() {
            guard c == "~", let ch = it.next() else { out.append(c); continue }
            var n = ""
            while let d = it.next(), d != "|" { n.append(d) }
            out += String(repeating: ch, count: Int(n) ?? 0)
        }
        return out
    }

    /// One layer of frame `i` as an image ("behind" or "over"), pond pixels at 1×.
    public func image(_ i: Int, _ layer: String) -> CGImage? {
        let key = "\(i).\(layer)"
        if let c = cache[key] { return c }
        let rows = layer == "behind" ? frames[i].behind : frames[i].over
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                guard let (r, g, b) = colors[ch] else { continue }
                let k = (y * width + x) * 4
                bytes[k] = r; bytes[k + 1] = g; bytes[k + 2] = b; bytes[k + 3] = 255
            }
        }
        let img = Self.cgImage(bytes, width, height)
        cache[key] = img
        return img
    }

    /// The waterline mask of frame `i`: opaque where Frogg shows normally.
    public func mask(_ i: Int) -> CGImage? {
        let key = "\(i).mask"
        if let c = cache[key] { return c }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (y, row) in frames[i].mask.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" { bytes[(y * width + x) * 4 + 3] = 255 }
        }
        let img = Self.cgImage(bytes, width, height)
        cache[key] = img
        return img
    }

    static func cgImage(_ bytes: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
