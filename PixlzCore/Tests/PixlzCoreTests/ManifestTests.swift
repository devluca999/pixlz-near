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
        let dirs = try FileManager.default.contentsOfDirectory(at: repoAssets, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        #expect(!dirs.isEmpty)
        for dir in dirs {
            let issues = ManifestValidator.validate(directory: dir)
            let missingSpritesOnly = !issues.isEmpty && issues.allSatisfy { $0.message == "missing" }
            if dir.lastPathComponent == "frogg" && missingSpritesOnly {
                // Frogg's sprites aren't rendered yet (needs the design PNGs via Git LFS, P6).
                // This turns into a failure on its own once the PNGs land and validate cleanly.
                withKnownIssue("Frogg sprites not rendered yet") {
                    Issue.record("\(dir.lastPathComponent): \(issues.count) sprite files missing")
                }
            } else {
                #expect(issues == [], "\(dir.lastPathComponent)")
            }
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
