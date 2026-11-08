import AppKit
import Foundation
import Testing
@testable import PixlMemoryKit

@MainActor
struct ArtTests {
    let art = FroggArt.shared

    @Test func allFramesDecode() {
        let expected = ["idle_0", "idle_1", "idle_2", "move_0", "move_1", "move_2", "poke_0", "poke_1", "poke_2", "rest_1",
                        "emotion_happy", "emotion_annoyed", "emotion_sleepy", "emotion_startled", "emotion_curious", "emotion_proud"]
        #expect(Set(art.frames.keys) == Set(expected))
        for name in expected {
            let img = art.image(name)
            #expect(img?.width == art.frames[name]?.w)
            #expect(img?.height == art.frames[name]?.h)
        }
        #expect(art.canvas == CGSize(width: 91, height: 74))
    }

    /// Feet on the bottom row: every frame is placed bottom-centred, so this is what keeps
    /// Frogg standing on the window edge instead of floating (SPEC §3.2 anchor check).
    @Test func everyFrameStandsOnItsBottomRow() {
        for (name, f) in art.frames {
            #expect(f.rows.last?.contains(where: { $0 != "." }) == true, "\(name) has an empty bottom row")
            #expect(f.rows.first?.contains(where: { $0 != "." }) == true, "\(name) isn't cropped at the top")
        }
    }

    @Test func opacityMatchesPixels() {
        let f = art.frames["idle_0"]!
        let row = Array(f.rows[f.h - 2])
        let x = row.firstIndex(where: { $0 != "." })!
        #expect(art.isOpaque("idle_0", x: x, y: f.h - 2))
        #expect(!art.isOpaque("idle_0", x: 0, y: 0))
        #expect(!art.isOpaque("idle_0", x: -1, y: 0))
        #expect(!art.isOpaque("nope", x: 0, y: 0))
    }

    @Test func badDataIsRejected() {
        let bad = ##"{"chars":"0","palette":["#123456"],"transparent":".","frames":{"a":{"w":2,"h":1,"rows":["0Z"]}}}"##
        #expect(throws: FroggArt.ArtError.self) { try FroggArt(json: Data(bad.utf8)) }
    }

    @Test func viewHitsOnlyOpaquePixels() {
        let v = FroggView(scale: 2, frameName: "idle_0")
        #expect(!v.hitsArt(at: NSPoint(x: 1, y: v.bounds.maxY - 1)))  // top-left corner: transparent
        #expect(v.hitsArt(at: NSPoint(x: v.bounds.midX, y: 40)))      // belly
        #expect(!v.hitsArt(at: NSPoint(x: v.bounds.midX, y: 4)))       // the gap between the feet
    }
}

struct PerchTests {
    let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)  // visible frame, top-left coords
    let sprite = CGSize(width: 140, height: 100)

    @Test func standsOnTheActiveWindowsTitleBar() throws {
        let w = CGRect(x: 200, y: 300, width: 900, height: 500)
        let s = try #require(Perch.spot(window: w, screens: [screen], sprite: sprite))
        #expect(s.place == .windowTop)
        #expect(s.foot.y == w.minY + 2)                       // inside the allowed 2 pt band
        #expect(s.foot.x - sprite.width / 2 >= w.minX + 90)   // clear of the traffic lights
        #expect(s.foot.x + sprite.width / 2 <= w.maxX)
    }

    @Test func maximizedWindowSendsFroggToTheGround() throws {
        let w = CGRect(x: 0, y: 25, width: 1512, height: 870)
        let s = try #require(Perch.spot(window: w, screens: [screen], sprite: sprite))
        #expect(s.place == .ground)
        #expect(s.foot.y == screen.maxY)
    }

    @Test func narrowWindowAndNoWindowUseTheGround() throws {
        #expect(Perch.spot(window: CGRect(x: 400, y: 400, width: 180, height: 300), screens: [screen], sprite: sprite)?.place == .ground)
        #expect(Perch.spot(window: nil, screens: [screen], sprite: sprite)?.place == .ground)
        #expect(Perch.spot(window: nil, screens: [], sprite: sprite) == nil)
    }

    @Test func picksTheScreenTheWindowIsOn() throws {
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1055)
        let w = CGRect(x: 1700, y: 300, width: 800, height: 400)
        let s = try #require(Perch.spot(window: w, screens: [screen, second], sprite: sprite))
        #expect(s.place == .windowTop)
        #expect(second.contains(CGPoint(x: s.foot.x, y: s.foot.y - 1)))
    }

    @Test func staysOnScreenWhenTheWindowHangsOffTheEdge() throws {
        let w = CGRect(x: 1300, y: 300, width: 800, height: 400)  // right part off-screen
        let s = try #require(Perch.spot(window: w, screens: [screen], sprite: sprite))
        #expect(s.foot.x + sprite.width / 2 <= screen.maxX)
    }

    @Test func coordinateConversion() {
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(Perch.toAppKit(r, primaryHeight: 900) == CGRect(x: 10, y: 840, width: 30, height: 40))
        #expect(Perch.toAppKit(Perch.toAppKit(r, primaryHeight: 900), primaryHeight: 900) == r)
        let f = Perch.panelFrame(foot: CGPoint(x: 500, y: 300), canvas: CGSize(width: 184, height: 150), primaryHeight: 900)
        #expect(f == CGRect(x: 408, y: 600, width: 184, height: 150))  // panel bottom = foot
    }
}

struct ClientTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "polish_response", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func decodesARealVerifiedReply() throws {
        let r = try MemoryClient.decodePolish(data: fixture(), status: 200)
        #expect(r.verification.verdict == "verified")
        #expect(r.verification.signatureKind == "provider_tee")
        #expect(r.verification.passed == r.verification.checks.count)
        #expect(r.verification.deployment?.contains("GLM-5.3-Flash") == true)
        #expect(!r.draftId.isEmpty)
    }

    @Test func mapsServiceErrors() {
        func err(_ status: Int, _ body: String) -> MemoryError? {
            do { _ = try MemoryClient.decodePolish(data: Data(body.utf8), status: status); return nil } catch { return error }
        }
        #expect(err(401, "{}") == .badToken)
        #expect(err(412, #"{"error":"no_api_key","message":"set it"}"#) == .noApiKey("set it"))
        #expect(err(402, #"{"error":"no_credits","message":"pay"}"#) == .noCredits("pay"))
        #expect(err(402, #"{"error":"frogg_out_of_allowance","message":"cap"}"#) == .outOfAllowance("cap"))
        #expect(err(400, #"{"error":"not_private","message":"no"}"#) == .notPrivate("no"))
        #expect(err(502, "not json") == .upstream("HTTP 502"))
        if case .attestationFailed(let m, _)? = err(409, #"{"error":"attestation_failed","message":"bad nonce"}"#) {
            #expect(m == "bad nonce")
        } else {
            Issue.record("409 should be attestationFailed")
        }
        #expect(MemoryError.attestationFailed("x", nil).detail.contains("not sent"))
    }

    @Test func missingTokenIsReported() {
        let c = MemoryClient(tokenURL: URL(fileURLWithPath: "/nonexistent/token"))
        #expect(throws: MemoryError.noToken) { _ = try c.token() }
    }
}

@MainActor
struct DiffTests {
    @Test func attributedTextKeepsBothVersions() throws {
        let r = try MemoryClient.decodePolish(data: ClientTests().fixture(), status: 200)
        let s = DiffText.attributed(r.diff).string
        let new = r.diff.filter { $0.op != .delete }.map(\.text).joined()
        #expect(new == r.suggestion)
        #expect(s.count == r.diff.map(\.text.count).reduce(0, +))
        let stats = DiffText.stats(r.diff)
        #expect(stats.added > 0 && stats.removed > 0)
    }

    @Test func panelLaysOutForEveryState() throws {
        let r = try MemoryClient.decodePolish(data: ClientTests().fixture(), status: 200)
        let a = PolishView(.result(r, instruction: "Polish this", app: "Mail"))
        a.fit()
        let b = PolishView(.result(r, instruction: "Polish this", app: "Mail"), showDetails: true)
        b.fit()
        #expect(a.frame.width == PolishView.width)
        #expect(b.frame.height > a.frame.height + 200)  // 17 checks shown
        let c = PolishView(.error(.serviceDown, app: nil))
        c.fit()
        #expect(c.frame.height > 80 && c.frame.height < a.frame.height)
    }
}

struct ReceiptTests {
    @Test func bubbleLines() {
        let paid = Receipt(status: "paid", amountNear: "0.0001", to: "sylversurferr.testnet", txHash: "abc",
                           explorer: "https://testnet.nearblocks.io/txns/abc", balanceAfterNear: "0.9999", reason: nil)
        #expect(paid.bubble == "Paid 0.0001 Ⓝ · 0.9999 Ⓝ left")
        let refused = Receipt(status: "refused", amountNear: "0.0005", to: nil, txHash: nil, explorer: nil,
                              balanceAfterNear: nil, reason: "today's cap of 0.1 Ⓝ is reached")
        #expect(refused.bubble.hasPrefix("Didn't pay: today's cap"))
    }

    @Test func replyWithoutAWalletStillDecodes() throws {
        let r = try MemoryClient.decodePolish(data: ClientTests().fixture(), status: 200)
        #expect(r.receipt == nil)
    }
}
