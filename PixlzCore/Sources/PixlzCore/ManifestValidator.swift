import CoreGraphics
import Foundation
import ImageIO

/// Alpha channel of a decoded sprite, row-major, top-left origin.
public struct AlphaBitmap: Sendable {
    public let width: Int
    public let height: Int
    public let alpha: [UInt8]

    public init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(alpha.count == width * height)
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    public subscript(x: Int, y: Int) -> UInt8 { alpha[y * width + x] }

    /// Decodes a PNG (or anything ImageIO reads) into its alpha channel.
    public static func load(_ url: URL) -> AlphaBitmap? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // CGContext memory is top row first, matching our layout.
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = rgba[i * 4 + 3] }
        return AlphaBitmap(width: w, height: h, alpha: alpha)
    }
}

/// One problem found by `ManifestValidator`.
public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public var file: String
    public var message: String
    public var description: String { "\(file): \(message)" }
}

/// SPEC §3.2 validation. Missing frames fail the build (D6).
public enum ManifestValidator {
    /// Frames drawn while the Pixl stands on a platform, so their feet must touch `anchor.y`.
    /// Derived from the mode table (SPEC §4.2). `mischief` frame 1 is clipped into the pond, so it's excluded.
    public static let groundedFrames: [Slot: [Int]] = [
        .idle: [0, 1, 2], .move: [0, 2], .rest: [0, 1, 2], .poke: [0, 1, 2],
        .perch: [2], .signature: [0, 1, 2], .mischief: [0, 2],
    ]

    /// Frames whose hold may be 0 ("as long as physics needs").
    public static let physicsHeldFrames: [Slot: Set<Int>] = [.move: [1], .grab: [1]]

    static let anchorTolerance = 2
    static let lfsPointerPrefix = "version https://git-lfs.github.com/spec/v1"

    /// Checks the manifest's own fields.
    public static func validate(_ m: PixlManifest) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func fail(_ msg: String) { issues.append(ValidationIssue(file: "pixl.json", message: msg)) }

        if m.canvas.w <= 0 || m.canvas.h <= 0 { fail("canvas must be positive") }
        if !(0..<m.canvas.w).contains(m.anchor.x) || !(0..<m.canvas.h).contains(m.anchor.y) {
            fail("anchor outside canvas")
        }
        let hb = m.hitbox
        if hb.w <= 0 || hb.h <= 0 || hb.x < 0 || hb.y < 0 || hb.x + hb.w > m.canvas.w || hb.y + hb.h > m.canvas.h {
            fail("hitbox outside canvas")
        }
        // A standing Pixl's hitbox must end at its feet, or it could never perch on the focused window (SPEC §6.4).
        if hb.y + hb.h > m.anchor.y { fail("hitbox must end at or above anchor.y") }
        // Every species hops between displays (a float one too), and a hop needs both > 0 (HopPlan).
        if !(m.physics.gravity > 0) { fail("gravity must be positive") }
        for (name, range) in [("hopApex", m.physics.hopApex), ("hopDistance", m.physics.hopDistance)] {
            if range.count != 2 || range[0] > range[1] || range[0] < 0 { fail("\(name) must be [min, max]") }
        }
        if m.physics.hopApex.count == 2, !(m.physics.hopApex[0] > 0) { fail("hopApex minimum must be positive") }
        if m.movement == .walk && m.physics.walkSpeed <= 0 { fail("walk species needs walkSpeed > 0") }
        for slot in Slot.allCases {
            guard let spec = m.slots[slot] else { fail("missing slot \(slot.rawValue)"); continue }
            if spec.holds.count != 3 { fail("\(slot.rawValue): holds must have 3 entries"); continue }
            for (i, h) in spec.holds.enumerated() {
                if h < 0 { fail("\(slot.rawValue): negative hold") }
                if h == 0 && !(physicsHeldFrames[slot]?.contains(i) ?? false) {
                    fail("\(slot.rawValue): hold 0 only allowed on physics-held frames")
                }
            }
        }
        return issues
    }

    /// Indexed-colour frames (`sprites.json`, from scripts/render-pixls.mjs): the format the
    /// app ships, since the repo keeps PNGs in Git LFS. Same rules as the PNG sheets: every
    /// slot frame and emotion present and non-empty, grounded frames standing on their feet,
    /// grab pins inside the sprite.
    public struct IndexedSprites: Decodable {
        public struct Frame: Decodable { public let w: Int; public let h: Int; public let rows: [String]; public let pin: [Int]? }
        public let transparent: String
        public let chars: String
        public let palette: [String]
        public let frames: [String: Frame]
    }

    public static func validate(indexed s: IndexedSprites, file: String = "sprites.json") -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func fail(_ m: String) { issues.append(.init(file: file, message: m)) }
        if s.chars.count != s.palette.count { fail("palette and chars differ in length") }
        let t = Character(s.transparent)
        let names = Slot.allCases.flatMap { sl in (0..<3).map { "\(sl.rawValue)_\($0)" } } + Emotion.allCases.map { "emotion_\($0.rawValue)" }
        for name in names {
            guard let f = s.frames[name] else { fail("frame \(name) is missing"); continue }
            if f.rows.count != f.h || f.rows.contains(where: { $0.count != f.w }) { fail("frame \(name): rows don't match \(f.w)×\(f.h)"); continue }
            if !f.rows.contains(where: { $0.contains { $0 != t } }) { fail("frame \(name) is empty"); continue }
            for row in f.rows where row.contains(where: { $0 != t && !s.chars.contains($0) }) { fail("frame \(name): unknown colour"); break }
            let parts = name.split(separator: "_")
            if let i = Int(parts.last ?? ""), let slot = Slot(rawValue: parts.dropLast().joined(separator: "_")),
               groundedFrames[slot]?.contains(i) == true, f.rows.last?.contains(where: { $0 != t }) != true {
                fail("frame \(name): doesn't stand on its feet (bottom row empty)")
            }
            if name.hasPrefix("grab_"), name != "grab_2" {
                guard let pin = f.pin, pin.count == 2, (0..<f.w).contains(pin[0]), (0..<f.h).contains(pin[1]) else { fail("frame \(name): no pin inside the sprite"); continue }
            }
        }
        return issues
    }

    /// Checks the manifest plus every sprite file in `directory` (`assets/<pixl>/`).
    public static func validate(directory: URL) -> [ValidationIssue] {
        let indexed = directory.appending(path: "sprites.json")
        if FileManager.default.fileExists(atPath: indexed.path) {
            // the shipped format: the manifest plus the indexed frames
            var issues: [ValidationIssue] = []
            do {
                let m = try PixlManifest.decode(Data(contentsOf: directory.appending(path: "pixl.json")))
                issues += validate(m)
                issues += validate(indexed: try JSONDecoder().decode(IndexedSprites.self, from: Data(contentsOf: indexed)))
            } catch {
                issues.append(.init(file: "pixl.json / sprites.json", message: "unreadable: \(error)"))
            }
            return issues
        }
        let manifestURL = directory.appendingPathComponent("pixl.json")
        let manifest: PixlManifest
        do {
            manifest = try PixlManifest.load(from: manifestURL)
        } catch {
            return [ValidationIssue(file: "pixl.json", message: "can't decode: \(error)")]
        }
        var issues = validate(manifest)
        let w = manifest.canvas.w, h = manifest.canvas.h

        for slot in Slot.allCases {
            let file = "\(slot.rawValue).png"
            guard let bmp = loadSprite(directory.appendingPathComponent(file), file: file, issues: &issues) else { continue }
            guard bmp.width == 3 * w, bmp.height == h else {
                issues.append(.init(file: file, message: "size \(bmp.width)×\(bmp.height), expected \(3 * w)×\(h)"))
                continue
            }
            checkAlpha(bmp, file: file, issues: &issues)
            for frame in 0..<3 {
                let x0 = frame * w
                if !hasOpaque(bmp, x: x0..<(x0 + w), y: 0..<h) {
                    issues.append(.init(file: file, message: "frame \(frame) is empty"))
                }
            }
            for frame in groundedFrames[slot] ?? [] {
                let x0 = frame * w
                let y = max(0, manifest.anchor.y - anchorTolerance)...min(h - 1, manifest.anchor.y + anchorTolerance)
                if !hasOpaque(bmp, x: x0..<(x0 + w), y: y.lowerBound..<(y.upperBound + 1)) {
                    issues.append(.init(file: file, message: "frame \(frame): no opaque pixels at anchor.y ±\(anchorTolerance)"))
                }
            }
        }
        for emotion in Emotion.allCases {
            let file = "emotions/\(emotion.rawValue).png"
            guard let bmp = loadSprite(directory.appendingPathComponent(file), file: file, issues: &issues) else { continue }
            guard bmp.width == w, bmp.height == h else {
                issues.append(.init(file: file, message: "size \(bmp.width)×\(bmp.height), expected \(w)×\(h)"))
                continue
            }
            checkAlpha(bmp, file: file, issues: &issues)
            if !hasOpaque(bmp, x: 0..<w, y: 0..<h) { issues.append(.init(file: file, message: "frame is empty")) }
        }
        return issues
    }

    private static func loadSprite(_ url: URL, file: String, issues: inout [ValidationIssue]) -> AlphaBitmap? {
        guard let data = try? Data(contentsOf: url) else {
            issues.append(.init(file: file, message: "missing"))
            return nil
        }
        if data.starts(with: Data(lfsPointerPrefix.utf8)) {
            issues.append(.init(file: file, message: "is a Git LFS pointer; run `git lfs pull`"))
            return nil
        }
        guard let bmp = AlphaBitmap.load(url) else {
            issues.append(.init(file: file, message: "not a readable image"))
            return nil
        }
        return bmp
    }

    private static func checkAlpha(_ bmp: AlphaBitmap, file: String, issues: inout [ValidationIssue]) {
        if let bad = bmp.alpha.firstIndex(where: { $0 != 0 && $0 != 255 }) {
            issues.append(.init(file: file, message: "partial alpha at (\(bad % bmp.width), \(bad / bmp.width)); only 0 or 255 allowed"))
        }
    }

    private static func hasOpaque(_ bmp: AlphaBitmap, x: Range<Int>, y: Range<Int>) -> Bool {
        for yy in y { for xx in x where bmp[xx, yy] == 255 { return true } }
        return false
    }
}
