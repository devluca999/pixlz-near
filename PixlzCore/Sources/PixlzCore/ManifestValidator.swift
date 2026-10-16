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
        if m.physics.gravity <= 0 && m.movement != .float { fail("gravity must be positive") }
        for (name, range) in [("hopApex", m.physics.hopApex), ("hopDistance", m.physics.hopDistance)] {
            if range.count != 2 || range[0] > range[1] || range[0] < 0 { fail("\(name) must be [min, max]") }
        }
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

    /// Checks the manifest plus every sprite file in `directory` (`assets/<pixl>/`).
    public static func validate(directory: URL) -> [ValidationIssue] {
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
