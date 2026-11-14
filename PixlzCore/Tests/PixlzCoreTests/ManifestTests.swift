import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixlzCore

/// `<repo>/assets`, found from this file's location.
let repoAssets = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets")

private func writePNG(_ url: URL, width: Int, height: Int, alpha: (Int, Int) -> UInt8) throws {
    var px = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let a = alpha(x, y), i = (y * width + x) * 4
            px[i] = a; px[i + 1] = a; px[i + 2] = 0; px[i + 3] = a
        }
    }
    let ctx = CGContext(
        data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

/// A complete synthetic Pixl: Frogg's manifest, every frame a solid block down to the anchor row.
private func makeSpecies(in dir: URL) throws -> PixlManifest {
    let manifest = try PixlManifest.load(from: repoAssets.appendingPathComponent("frogg/pixl.json"))
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("emotions"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: repoAssets.appendingPathComponent("frogg/pixl.json"), to: dir.appendingPathComponent("pixl.json"))
    let w = manifest.canvas.w, h = manifest.canvas.h, ay = manifest.anchor.y
    let body: (Int, Int) -> UInt8 = { x, y in (x % w) > 20 && (x % w) < 80 && y > 30 && y <= ay ? 255 : 0 }
    for slot in Slot.allCases {
        try writePNG(dir.appendingPathComponent("\(slot.rawValue).png"), width: 3 * w, height: h, alpha: body)
    }
    for e in Emotion.allCases {
        try writePNG(dir.appendingPathComponent("emotions/\(e.rawValue).png"), width: w, height: h, alpha: body)
    }
    return manifest
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixlz-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ManifestTests {
    @Test func froggManifestDecodesAndIsValid() throws {
        let m = try PixlManifest.load(from: repoAssets.appendingPathComponent("frogg/pixl.json"))
        #expect(m.canvas == PixelSize(w: 104, h: 76))
        #expect(m.slots.count == 9)
        #expect(m.slots[.fileRide]?.loop == .last)
        #expect(ManifestValidator.validate(m) == [])
    }

    @Test func manifestFieldErrors() throws {
        var m = try PixlManifest.load(from: repoAssets.appendingPathComponent("frogg/pixl.json"))
        m.slots[.poke] = nil
        m.slots[.idle] = SlotSpec(holds: [6, 0, 8], loop: .all)
        m.hitbox.w = 500
        let messages = ManifestValidator.validate(m).map(\.message)
        #expect(messages.contains("missing slot poke"))
        #expect(messages.contains("idle: hold 0 only allowed on physics-held frames"))
        #expect(messages.contains("hitbox outside canvas"))
    }

    // A hop needs gravity > 0 and a positive apex, float species too (HopPlan would trap otherwise).
    @Test func floatSpeciesStillNeedsAHoppablePhysics() throws {
        var m = try PixlManifest.load(from: repoAssets.appendingPathComponent("ghost/pixl.json"))
        #expect(m.movement == .float && ManifestValidator.validate(m) == [])
        m.physics.gravity = 0
        m.physics.hopApex = [0, 30]
        let messages = ManifestValidator.validate(m).map(\.message)
        #expect(messages.contains("gravity must be positive"))
        #expect(messages.contains("hopApex minimum must be positive"))
    }

    @Test func completeSyntheticSpeciesPasses() throws {
        let dir = tempDir()
        _ = try makeSpecies(in: dir)
        #expect(ManifestValidator.validate(directory: dir) == [])
    }

    @Test func spriteErrorsAreReported() throws {
        let dir = tempDir()
        let m = try makeSpecies(in: dir)
        let w = m.canvas.w, h = m.canvas.h
        try FileManager.default.removeItem(at: dir.appendingPathComponent("emotions/proud.png"))
        try writePNG(dir.appendingPathComponent("poke.png"), width: 2 * w, height: h) { _, _ in 255 }
        try writePNG(dir.appendingPathComponent("rest.png"), width: 3 * w, height: h) { x, y in
            x >= 2 * w ? 0 : (y == 70 ? 128 : (y == 70 + 1 ? 255 : 0))
        }
        try writePNG(dir.appendingPathComponent("idle.png"), width: 3 * w, height: h) { _, y in y < 10 ? 255 : 0 }
        try Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n".utf8)
            .write(to: dir.appendingPathComponent("perch.png"))

        let issues = ManifestValidator.validate(directory: dir).map(\.description)
        #expect(issues.contains("emotions/proud.png: missing"))
        #expect(issues.contains("poke.png: size 208×76, expected 312×76"))
        #expect(issues.contains { $0.hasPrefix("rest.png: partial alpha") })
        #expect(issues.contains("rest.png: frame 2 is empty"))
        #expect(issues.contains("idle.png: frame 0: no opaque pixels at anchor.y ±2"))
        #expect(issues.contains("perch.png: is a Git LFS pointer; run `git lfs pull`"))
    }

    /// The real gate (D6): every Pixl in `assets/` validates, sprites included.
    @Test func everyRepoPixlValidates() throws {
        // Frogg, the cat, the Shiba, the ghost and the widow
        let dirs = try FileManager.default.contentsOfDirectory(at: repoAssets, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        #expect(!dirs.isEmpty)
        for dir in dirs {
            // every Pixl ships indexed frames (sprites.json, scripts/render-pixls.mjs) + pixl.json
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: "sprites.json").path), "\(dir.lastPathComponent)")
            let issues = ManifestValidator.validate(directory: dir)
            #expect(issues == [], "\(dir.lastPathComponent): \(issues)")
        }
    }
}


struct PixlUITests {
    @Test func froggCarriesItsMenuCharacterInData() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../assets/frogg/pixl.json").standardized
        let m = try PixlManifest.load(from: url)
        let ui = try #require(m.ui)
        #expect(ui.accent == "#7CD93A" && ui.menuFace == "emotion_curious" && !ui.glassBody)
        #expect(!ui.signature.isEmpty && !ui.personality.isEmpty)
    }
}

struct IndexedSpriteTests {
    func sprites(_ edit: (inout [String: [String: Any]]) -> Void) throws -> ManifestValidator.IndexedSprites {
        var frames: [String: [String: Any]] = [:]
        let names = Slot.allCases.flatMap { s in (0..<3).map { "\(s.rawValue)_\($0)" } } + Emotion.allCases.map { "emotion_\($0.rawValue)" }
        for n in names { frames[n] = ["w": 3, "h": 2, "rows": [".a.", "aaa"], "pin": [1, 0]] }
        edit(&frames)
        let json = try JSONSerialization.data(withJSONObject: ["transparent": ".", "chars": "a", "palette": ["#112233"], "frames": frames])
        return try JSONDecoder().decode(ManifestValidator.IndexedSprites.self, from: json)
    }

    @Test func aCompleteSetPasses() throws {
        #expect(ManifestValidator.validate(indexed: try sprites { _ in }).isEmpty)
    }

    @Test func catchesMissingEmptyFloatingAndUnpinnedFrames() throws {
        let bad = try sprites { f in
            f["poke_1"] = nil                                                      // missing
            f["idle_0"] = ["w": 2, "h": 1, "rows": [".."]]                          // empty
            f["rest_0"] = ["w": 2, "h": 2, "rows": ["aa", ".."]]                    // grounded but floating
            f["grab_0"] = ["w": 2, "h": 1, "rows": ["aa"], "pin": [5, 0]]           // pin outside
            f["emotion_happy"] = ["w": 2, "h": 1, "rows": ["az"]]                   // unknown colour
        }
        let msgs = ManifestValidator.validate(indexed: bad).map(\.message).joined(separator: "\n")
        for needle in ["poke_1 is missing", "idle_0 is empty", "rest_0: doesn't stand", "grab_0: no pin", "emotion_happy: unknown colour"] {
            #expect(msgs.contains(needle), "\(needle)")
        }
    }
}
