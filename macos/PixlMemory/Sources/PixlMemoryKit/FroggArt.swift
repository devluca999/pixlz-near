import AppKit
import PixlzCore

typealias SquashStretchQuantize = SquashStretch

/// Frogg's frames, rendered from the Claude Design C7 engine (scripts/render-pixls.mjs).
/// Indexed colour, alpha 0 or 255 only, drawn nearest-neighbour at whole-number scales.
@MainActor
public final class FroggArt {
    public struct Frame: Decodable, Sendable {
        public let w: Int
        public let h: Int
        public let rows: [String]
        /// For hanging frames: the art pixel (x, y from top-left) held by the cursor.
        public let pin: [Int]?
    }

    struct File: Decodable {
        let chars: String
        let palette: [String]
        let transparent: String
        let frames: [String: Frame]
    }

    /// The current Pixl's art (the name stays: Frogg was first).
    public static var shared: FroggArt { PixlSkins.current.art }

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

    /// Draws a frame with squash/stretch, mirroring and lean, all in whole art pixels and
    /// anchored at the feet (bottom centre of `rect`), so the art stays crisp and planted.
    /// - squash: (sx, sy), snapped to whole art pixels.
    /// - lean: horizontal shear; the top row moves by `lean × height`, snapped to whole art pixels.
    public func draw(_ name: String, in rect: CGRect, scale: CGFloat, context: CGContext,
                     squash: CGSize, mirrored: Bool, lean: CGFloat) {
        guard let img = image(name) else { return }
        let art = CGSize(width: img.width, height: img.height)
        let q = SquashStretchQuantize.quantized(squash, sprite: art)
        let w = art.width * q.width * scale, h = art.height * q.height * scale
        let feetX = rect.midX.rounded(), feetY = rect.minY
        let topShift = (lean * art.height).rounded() * scale  // whole art pixels
        context.saveGState()
        context.interpolationQuality = .none
        context.translateBy(x: feetX, y: feetY)
        if topShift != 0 { context.concatenate(CGAffineTransform(a: 1, b: 0, c: topShift / max(h, 1), d: 1, tx: 0, ty: 0)) }
        if mirrored { context.scaleBy(x: -1, y: 1) }
        // half points are whole device pixels on Retina, so half-step scales stay on the grid
        context.draw(img, in: CGRect(x: (-w).rounded(.down) / 2, y: 0, width: w, height: h))
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

/// Every Pixl the app ships (scripts/render-pixls.mjs): its frames and its pixl.json.
@MainActor
public enum PixlSkins {
    public struct Skin {
        public let id: String
        public let manifest: PixlManifest
        public let art: FroggArt
        public var ui: PixlUI { manifest.ui ?? PixlData.fallbackUI }
    }

    public static let all: [Skin] = pixlOrder.map { id in
        do {
            return Skin(id: id, manifest: try PixlManifest.decode(Data(pixlManifestJSON[id]!.utf8)),
                        art: try FroggArt(json: Data(pixlSpriteJSON[id]!.utf8)))
        } catch { fatalError("bad Pixl data for \(id): \(error)") }
    }

    /// Which one is on screen. Set by the app from the saved setting.
    public static var currentID = "frogg"
    public static var current: Skin { skin(currentID) ?? all[0] }
    /// The name you gave your Pixl (the app keeps it in sync with Settings); else the skin's.
    public static var displayName: String?
    public static var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? current.manifest.name }

    /// The third-poke grumble, true to whichever Pixl you have: "Nox is busy being a black cat."
    public static func busyLine(name: String, busy: String?, species: String) -> String {
        if let busy, !busy.isEmpty { return "Hey! \(name) is busy \(busy)." }
        var kind = species.components(separatedBy: " · ")[0].trimmingCharacters(in: .whitespaces)
        if let f = kind.first { kind = f.lowercased() + kind.dropFirst() }
        let article = kind.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return "Hey! \(name) is busy being \(article) \(kind)."
    }
    public static func skin(_ id: String) -> Skin? { all.first { $0.id == id } }

    /// Every frame name the app asks for: all slots × 3, the six emotions.
    public static let requiredFrames: [String] =
        Slot.allCases.flatMap { s in (0..<3).map { "\(s.rawValue)_\($0)" } } + Emotion.allCases.map { "emotion_\($0.rawValue)" }
}

/// The current Pixl's species data and menu character (`ui`): accent, menu face, signature, voice.
@MainActor
public enum PixlData {
    public static var manifest: PixlManifest { PixlSkins.current.manifest }
    public static var ui: PixlUI { PixlSkins.current.ui }
    nonisolated static let fallbackUI = PixlUI(accent: "#7CD93A", menuFace: "emotion_curious", glassBody: false, signature: "Signature",
                                   askPlaceholder: "Ask anything…", personality: "a friendly pixel pet")
}
