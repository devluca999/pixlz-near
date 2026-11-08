import AppKit

/// Frogg's frames, rendered from the Claude Design C7 engine (scripts/render-frogg.mjs).
/// Indexed colour, alpha 0 or 255 only, drawn nearest-neighbour at whole-number scales.
@MainActor
public final class FroggArt {
    public struct Frame: Decodable, Sendable {
        public let w: Int
        public let h: Int
        public let rows: [String]
    }

    struct File: Decodable {
        let chars: String
        let palette: [String]
        let transparent: String
        let frames: [String: Frame]
    }

    public static let shared: FroggArt = {
        do { return try FroggArt(json: Data(froggSpriteJSON.utf8)) } catch { fatalError("bad sprite data: \(error)") }
    }()

    public let frames: [String: Frame]
    private let colors: [Character: (UInt8, UInt8, UInt8)]
    private var cache: [String: CGImage] = [:]

    /// The canvas every frame is placed on, bottom-centred (feet on the bottom row).
    public let canvas: CGSize

    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        guard file.chars.count == file.palette.count else { throw ArtError.palette }
        var colors: [Character: (UInt8, UInt8, UInt8)] = [:]
        for (ch, hex) in zip(file.chars, file.palette) {
            guard let rgb = Self.rgb(hex) else { throw ArtError.color(hex) }
            colors[ch] = rgb
        }
        for (name, f) in file.frames {
            guard f.rows.count == f.h, f.rows.allSatisfy({ $0.count == f.w }) else { throw ArtError.shape(name) }
            for row in f.rows {
                for ch in row where String(ch) != file.transparent && colors[ch] == nil { throw ArtError.unknownPixel(name, ch) }
            }
        }
        self.frames = file.frames
        self.colors = colors
        canvas = CGSize(width: file.frames.values.map(\.w).max() ?? 0, height: file.frames.values.map(\.h).max() ?? 0)
    }

    public enum ArtError: Error { case palette, color(String), shape(String), unknownPixel(String, Character) }

    static func rgb(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        guard hex.count == 7, hex.first == "#", let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    public func size(_ name: String) -> CGSize {
        guard let f = frames[name] else { return .zero }
        return CGSize(width: f.w, height: f.h)
    }

    /// Whether the art pixel at (x, y) from the frame's top-left is opaque.
    public func isOpaque(_ name: String, x: Int, y: Int) -> Bool {
        guard let f = frames[name], y >= 0, y < f.h, x >= 0, x < f.w else { return false }
        let row = f.rows[y]
        return row[row.index(row.startIndex, offsetBy: x)] != "."
    }

    /// The frame as a 1× image (1 pixel per art pixel).
    public func image(_ name: String) -> CGImage? {
        if let img = cache[name] { return img }
        guard let f = frames[name] else { return nil }
        var bytes = [UInt8](repeating: 0, count: f.w * f.h * 4)
        for (y, row) in f.rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let (r, g, b) = colors[ch] else { continue }
                let i = (y * f.w + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: f.w, height: f.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        cache[name] = img
        return img
    }

    /// Draws a frame bottom-centred in `rect` at an integer scale, without smoothing.
    public func draw(_ name: String, in rect: CGRect, scale: CGFloat, context: CGContext, flipped: Bool = false) {
        guard let img = image(name) else { return }
        let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
        let x = (rect.midX - w / 2).rounded(.down)
        let y = flipped ? rect.maxY - h : rect.minY
        context.saveGState()
        context.interpolationQuality = .none
        if flipped {
            context.translateBy(x: 0, y: y + h)
            context.scaleBy(x: 1, y: -1)
            context.draw(img, in: CGRect(x: x, y: 0, width: w, height: h))
        } else {
            context.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
        }
        context.restoreGState()
    }

    /// An NSImage of one frame at an integer scale (for image views and the menu bar).
    public func nsImage(_ name: String, scale: CGFloat) -> NSImage? {
        guard let img = image(name) else { return nil }
        let size = NSSize(width: CGFloat(img.width) * scale, height: CGFloat(img.height) * scale)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: rect)
            return true
        }
    }
}
