import Foundation
import PixlzCore
import Testing
@testable import PixlTravel

/// Two devices in one process, talking over real Bonjour on this Mac.
@MainActor
struct BonjourTripTests {
    func device(_ name: String) -> DeviceRef { DeviceRef(deviceId: "\(name)-\(UUID().uuidString.prefix(8))", deviceName: name) }

    /// Spins the main run loop until `ok` or the timeout.
    func waitUntil(_ timeout: Double, _ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ok()
    }

    @Test(.timeLimit(.minutes(1))) func aPixlHopsToAnotherDeviceAndOnlyOneOwnsIt() async throws {
        let macA = device("Studio Mac"), macB = device("Laptop")
        let a = TripRunner(me: macA, store: InMemoryPetStore(), knownSpecies: ["frogg", "cat"])
        let b = TripRunner(me: macB, store: InMemoryPetStore(), knownSpecies: ["frogg", "cat"])
        a.adoptIfNeeded(species: "cat", name: "Nox")
        var asked: (DeviceRef, String)?
        var entered: PetState?, exitedTo: DeviceRef?
        b.onAsk = { asked = ($0, $1) }
        b.onEntrance = { entered = $0 }
        a.onExit = { exitedTo = $0 }
        try a.start(); try b.start()
        defer { a.stop(); b.stop() }

        // discovery: each sees the other (Bonjour, like AirDrop finding a device)
        let found = await waitUntil(15) { a.peers.contains(macB) && b.peers.contains(macA) }
        #expect(found, "the two devices didn't find each other over Bonjour")
        guard found else { return }

        // the first offer from an unknown device waits for the user's yes
        a.send(to: macB)
        #expect(await waitUntil(5) { asked != nil })
        #expect(asked?.0 == macA && asked?.1 == "Nox" && entered == nil)
        b.consent(true, for: macA)

        // the trip: B owns Nox (epoch + 1), A plays the exit and keeps only the away record
        #expect(await waitUntil(10) { entered != nil && exitedTo != nil })
        #expect(entered?.name == "Nox" && entered?.species == "cat" && entered?.owner == macB && entered?.epoch == 2)   // a new Pixl starts at epoch 1; every move adds one
        #expect(exitedTo == macB)
        #expect(b.owned != nil && a.owned == nil)
        if case .away(_, let epoch, let ownerName, _, _)? = a.record { #expect(epoch == 2 && ownerName == "Laptop") }
        else { Issue.record("A should hold an away record, has \(String(describing: a.record))") }

        // and back: B now trusts nothing from A automatically… but A trusts nobody yet either,
        // so the return trip asks A first; declining keeps Nox on B
        var askedA = false
        a.onAsk = { _, _ in askedA = true }
        b.send(to: macA)
        #expect(await waitUntil(5) { askedA })
        var shrug: String?
        b.onShrug = { shrug = $0 }
        a.consent(false, for: macB)
        #expect(await waitUntil(5) { shrug != nil })
        #expect(b.owned?.name == "Nox" && a.owned == nil)   // declined: the Pixl stays where it is
    }

    @Test func thisDeviceHasAStableIdAndAnOverrideForASecondCopy() throws {
        let d = try #require(UserDefaults(suiteName: "pixl-dev-\(UUID())"))
        let first = ThisDevice.ref(defaults: d, env: [:])
        #expect(ThisDevice.ref(defaults: d, env: [:]) == first)                       // stable across launches
        let second = ThisDevice.ref(defaults: d, env: ["PIXL_DEVICE_ID": "copy-2", "PIXL_DEVICE_NAME": "Second copy"])
        #expect(second == DeviceRef(deviceId: "copy-2", deviceName: "Second copy"))
    }

    @Test func manualPeersParseFromDefaults() throws {
        let p = try #require(ManualPeer("MOSAICO-D1199C|Mosaico 199C|10.0.30.13|47860"))
        #expect(p.ref == DeviceRef(deviceId: "MOSAICO-D1199C", deviceName: "Mosaico 199C"))
        #expect(p.host == "10.0.30.13" && p.port == 47860)
        #expect(ManualPeer("id||host|1")?.ref.deviceName == "id")          // a missing name falls back to the id
        for bad in ["", "a|b|c", "a|b||1", "|b|c|1", "a|b|c|0", "a|b|c|port", "a|b|c|70000"] {
            #expect(ManualPeer(bad) == nil, "\(bad)")
        }
        let d = try #require(UserDefaults(suiteName: "pixl-peers-\(UUID())"))
        d.set(["MOSAICO-1|Mosaico|10.0.0.5|47860", "junk"], forKey: ManualPeer.defaultsKey)
        #expect(ManualPeer.fromDefaults(d).map(\.ref.deviceId) == ["MOSAICO-1"])
    }

    @Test func manualPeersShowUpAsReachableDevices() async throws {
        let t = BonjourTransport(me: device("Mac"))
        var seen: [DeviceRef] = []
        t.onPeers = { seen = $0 }
        let mosaico = DeviceRef(deviceId: "MOSAICO-TEST", deviceName: "Mosaico")
        t.setManualPeers([ManualPeer(ref: mosaico, host: "127.0.0.1", port: 47860),
                          ManualPeer(ref: t.me, host: "127.0.0.1", port: 1)])   // never ourselves
        #expect(await waitUntil(2) { seen == [mosaico] })
        #expect(t.peers == [mosaico])
        t.setManualPeers([])
        #expect(await waitUntil(2) { seen.isEmpty })
    }

    @Test func mosaicoFeedIsAsciiTrimmedAndFits() throws {
        #expect(MosaicoFeed.ascii("Glass frogs’ skin — “see-through”… **bold** `x`", 100)
                == "Glass frogs' skin - \"see-through\"... bold x")
        #expect(MosaicoFeed.ascii("Café  naïve\n\tline", 100) == "Cafe naive line")
        #expect(MosaicoFeed.ascii("🐸 ribbit", 100) == "ribbit")
        #expect(MosaicoFeed.ascii(String(repeating: "a", count: 50), 10) == "aaaaaaa...")

        let body = MosaicoFeed.body(answers: [("Why are frogs green?", "Camouflage.")],
                                    highlights: [("Glass frogs", "Their skin is see-through.")])
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let feed = try #require(json["feed"] as? [String: Any])
        let answers = try #require(feed["answers"] as? [[String: String]])
        #expect(answers == [["q": "Why are frogs green?", "a": "Camouflage."]])
        #expect((feed["highlights"] as? [[String: String]])?.first?["title"] == "Glass frogs")

        // Many long items: trimmed to fit the Mosaico's buffer, newest kept.
        let long = String(repeating: "word ", count: 400)
        let big = MosaicoFeed.body(answers: (0..<10).map { ("q\($0) " + long, long) },
                                   highlights: (0..<10).map { ("t\($0) " + long, long) })
        #expect(big.count <= MosaicoFeed.maxBytes)
        let bigFeed = try #require((try JSONSerialization.jsonObject(with: big) as? [String: Any])?["feed"] as? [String: Any])
        let first = (bigFeed["answers"] as? [[String: String]])?.first?["q"] ?? ""
        #expect(first.hasPrefix("q0 "))
    }

    @Test func agentsForTheMosaicoFitAndDecisionsParse() throws {
        let rows = (0..<10).map { i in
            MosaicoFeed.AgentRow(id: "s\(i)", project: "project-\(i)", doing: String(repeating: "Running a very long command ", count: 6),
                                 request: i == 0 ? "req-1" : nil, summary: "Run rm -rf build", detail: String(repeating: "x", count: 900),
                                 answerable: true)
        }
        let body = MosaicoFeed.agentsBody(rows, alerts: true)
        #expect(body.count <= MosaicoFeed.maxBytes)
        let o = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["agents"] as? [String: Any])
        let sessions = try #require(o["sessions"] as? [[String: Any]])
        #expect(o["alerts"] as? Bool == true && sessions.count == MosaicoFeed.maxAgents)
        #expect(sessions[0]["req"] as? String == "req-1" && (sessions[0]["detail"] as? String)?.count == 140)
        #expect(sessions[1]["req"] == nil)
        let d = MosaicoFeed.agentDecision(Data(#"{"agentDecision":{"id":"req-1","behavior":"deny"}}"#.utf8))
        #expect(d?.id == "req-1" && d?.behavior == "deny")
        #expect(MosaicoFeed.agentDecision(Data(#"{"feed":{}}"#.utf8)) == nil)
    }
}

import CryptoKit

@Suite struct PairingTests {
    static func hexData(_ s: String) -> Data { Data(stride(from: 0, to: s.count, by: 2).map { i in
        UInt8(s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)], radix: 16)! }) }
    // RFC 7748 §6.1 keys: Alice is the Mac, Bob the Mosaico. pt_pair tests use the same ones.
    static let macPriv = hexData("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    static let devPriv = hexData("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    let mac = DeviceRef(deviceId: "MAC-1", deviceName: "Test Mac")
    let dev = DeviceRef(deviceId: "MOSAICO-1", deviceName: "Mosaico 1")

    /// The Mosaico's side, as pt_pair.c computes it.
    func device(_ start: Data) throws -> (key: SymmetricKey, code: String, keyFrame: Data, pub: Data) {
        let o = try #require(try JSONSerialization.jsonObject(with: start) as? [String: Any])
        let commit = Self.hexData(try #require((o["pair"] as? [String: Any])?["commit"] as? String))
        let p = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.devPriv)
        let macPub = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.macPriv).publicKey
        let s = try p.sharedSecretFromKeyAgreement(with: macPub)
        let t = MosaicoPairing.transcript(commit: commit, devicePub: p.publicKey.rawRepresentation, macPub: macPub.rawRepresentation,
                                          macId: mac.deviceId, deviceId: dev.deviceId)
        let k = s.hkdfDerivedSymmetricKey(using: SHA256.self, salt: t, sharedInfo: Data("pixlz-key".utf8), outputByteCount: 32)
        let frame = MosaicoPairing.json(["pair": ["step": "key", "pub": p.publicKey.rawRepresentation.hex]])
        return (k, MosaicoPairing.code(k), frame, p.publicKey.rawRepresentation)
    }

    @Test func bothSidesShowTheSameCodeAndPair() throws {
        var m = MosaicoPairing(me: mac, peer: dev, privateKey: try .init(rawRepresentation: Self.macPriv))
        let d = try device(m.start())
        let ev = m.receive(d.keyFrame)
        #expect(ev.contains(.showCode(d.code)))
        #expect(d.code == "635989")   // the value pt_pair's test expects too
        #expect(d.key.withUnsafeBytes { Data($0) }.hex == "1b832b28e81b8ed9aeafb2e9167a45a7dc29d952534c9d23df19d19c065cfa09")
        #expect(m.user(true).isEmpty)          // waits for the Mosaico's yes
        let tag = Data(HMAC<SHA256>.authenticationCode(for: Data("mosaico-ok".utf8), using: d.key))
        let done = m.receive(MosaicoPairing.json(["pair": ["step": "confirm", "tag": tag.hex]]))
        #expect(done.count == 2)
        guard case .paired(let key)? = done.last else { Issue.record("not paired"); return }
        #expect(key == d.key.withUnsafeBytes { Data($0) })
    }

    @Test func aBadConfirmOrANoCancels() throws {
        var m = MosaicoPairing(me: mac, peer: dev)
        _ = m.start()
        let d = try device(MosaicoPairing(me: mac, peer: dev, privateKey: try .init(rawRepresentation: Self.macPriv)).start())
        _ = m.receive(d.keyFrame)   // different Mac key: the Mosaico's tag can't match
        let ev = m.receive(MosaicoPairing.json(["pair": ["step": "confirm", "tag": String(repeating: "0", count: 64)]]))
        #expect(ev.contains { if case .cancelled = $0 { true } else { false } })
        var n = MosaicoPairing(me: mac, peer: dev)
        _ = n.receive(d.keyFrame)
        #expect(n.user(false).contains { if case .cancelled = $0 { true } else { false } })
    }

    @Test func quickRepliesVerifyLikeTheMosaicoSignsThem() {
        // The body pt_pair_sign_reply writes for key 07…, n = 1 (see test_pixl_trip.c).
        let sid = "0d5c1f5e-1111-4222-8333-944455556666"
        let body = #"{"agentReply":{"text":"Run the tests","behavior":"reply","id":"0d5c1f5e-1111-4222-8333-944455556666","n":1,"seen":"39167a70b8bc685f4ef3bbcf52243f4af2befe26da4c88734383ff0b92150dfc","tag":"a4ef693ac6022fd8e6ed1c91f3431177ca56354e73eaef9030d6bb4e4e37fbfc"}}"#
        let key = Data(repeating: 7, count: 32)
        let ok = MosaicoPairing.verifyReply(Data(body.utf8), deviceId: "MOSAICO-1", key: key, lastCounter: 0)
        #expect(ok?.id == sid && ok?.text == "Run the tests" && ok?.n == 1)
        #expect(MosaicoPairing.verifyReply(Data(body.utf8), deviceId: "MOSAICO-1", key: key, lastCounter: 1) == nil)   // replayed
        let other = body.replacingOccurrences(of: "Run the tests", with: "Yes")
        #expect(MosaicoPairing.verifyReply(Data(other.utf8), deviceId: "MOSAICO-1", key: key, lastCounter: 0) == nil)   // text swapped
    }

    @Test func decisionsVerifyOnlyWithKeySeenAndANewNumber() throws {
        let key = Data(repeating: 7, count: 32)
        let seen = MosaicoPairing.seen(summary: "Run ls", detail: "ls -la")
        func body(n: UInt32, behavior: String = "allow", seen: String = seen, key k: Data = key) -> Data {
            let msg = "pixlz-decision-v1|MOSAICO-1|\(n)|req-3|\(behavior)|\(seen)"
            let tag = Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: k))).hex
            return MosaicoPairing.json(["agentDecision": ["id": "req-3", "behavior": behavior, "n": n, "seen": seen, "tag": tag]])
        }
        let ok = MosaicoPairing.verifyDecision(body(n: 5), deviceId: "MOSAICO-1", key: key, lastCounter: 4, summary: "Run ls", detail: "ls -la")
        #expect(ok?.id == "req-3" && ok?.behavior == "allow" && ok?.n == 5)
        #expect(MosaicoPairing.verifyDecision(body(n: 4), deviceId: "MOSAICO-1", key: key, lastCounter: 4, summary: "Run ls", detail: "ls -la") == nil)
        #expect(MosaicoPairing.verifyDecision(body(n: 5), deviceId: "MOSAICO-1", key: key, lastCounter: 4, summary: "Run ls", detail: "rm -rf /") == nil)
        #expect(MosaicoPairing.verifyDecision(body(n: 5, key: Data(repeating: 8, count: 32)), deviceId: "MOSAICO-1", key: key, lastCounter: 4, summary: "Run ls", detail: "ls -la") == nil)
        #expect(MosaicoPairing.verifyDecision(body(n: 5), deviceId: "MOSAICO-2", key: key, lastCounter: 4, summary: "Run ls", detail: "ls -la") == nil)
    }
}
