import CryptoKit
import Foundation
import PixlzCore

/// Pairing this Mac with a Mosaico (D20): numeric comparison. The Mac commits to its X25519
/// key, the Mosaico answers with its own, the Mac reveals; both show the same 6-digit code and
/// the user confirms on both screens. Same frames and maths as mosaico/pixl_trip/pt_pair.h.
public struct MosaicoPairing {
    public enum Event: Equatable {
        case send(Data)          // a frame body for the Mosaico
        case showCode(String)    // ask the user: does the Mosaico show this?
        case paired(Data)        // the 32-byte key: save it with the device
        case cancelled(String)   // why
    }

    public let me: DeviceRef
    public let peer: DeviceRef
    private let priv: Curve25519.KeyAgreement.PrivateKey
    private let commit: Data
    private var key: SymmetricKey?
    public private(set) var code: String?
    private var userOK = false, deviceOK = false
    public private(set) var finished = false

    public init(me: DeviceRef, peer: DeviceRef, privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.me = me; self.peer = peer; priv = privateKey
        commit = Data(SHA256.hash(data: privateKey.publicKey.rawRepresentation))
    }

    public func start() -> Data {
        Self.json(["pair": ["step": "start", "commit": commit.hex], "from": me.deviceId, "fromName": me.deviceName])
    }

    public mutating func receive(_ body: Data) -> [Event] {
        guard !finished, let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let p = o["pair"] as? [String: Any], let step = p["step"] as? String else { return [] }
        switch step {
        case "key":
            guard key == nil, let hex = p["pub"] as? String, let pub = Data(hex: hex), pub.count == 32,
                  let devicePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub),
                  let secret = try? priv.sharedSecretFromKeyAgreement(with: devicePub),
                  secret.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { return cancel("The Mosaico sent a bad key.") }
            let t = Self.transcript(commit: commit, devicePub: pub, macPub: priv.publicKey.rawRepresentation,
                                    macId: me.deviceId, deviceId: peer.deviceId)
            let k = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: t, sharedInfo: Data("pixlz-key".utf8), outputByteCount: 32)
            key = k
            let c = Self.code(k)
            code = c
            return [.send(Self.json(["pair": ["step": "reveal", "pub": priv.publicKey.rawRepresentation.hex]])), .showCode(c)]
        case "confirm":
            guard let k = key, let hex = p["tag"] as? String, let got = Data(hex: hex),
                  HMAC<SHA256>.isValidAuthenticationCode(got, authenticating: Data("mosaico-ok".utf8), using: k)
            else { return cancel("The Mosaico's answer didn't check out.") }
            deviceOK = true
            return finishIfBoth()
        case "cancel":
            return cancel("The Mosaico said no (or the codes didn't match).", tell: false)
        default:
            return []
        }
    }

    /// The user's answer on the Mac: the codes match, or not.
    public mutating func user(_ accept: Bool) -> [Event] {
        guard !finished, key != nil else { return [] }
        guard accept else { return cancel("Pairing cancelled.") }
        userOK = true
        return finishIfBoth()
    }

    private mutating func finishIfBoth() -> [Event] {
        guard userOK, deviceOK, let k = key else { return [] }
        finished = true
        let tag = Data(HMAC<SHA256>.authenticationCode(for: Data("mac-ok".utf8), using: k))
        return [.send(Self.json(["pair": ["step": "done", "tag": tag.hex]])), .paired(k.withUnsafeBytes { Data($0) })]
    }

    private mutating func cancel(_ why: String, tell: Bool = true) -> [Event] {
        finished = true
        return (tell ? [.send(Self.json(["pair": ["step": "cancel"]]))] : []) + [.cancelled(why)]
    }

    // MARK: maths shared with pt_pair.c

    static func transcript(commit: Data, devicePub: Data, macPub: Data, macId: String, deviceId: String) -> Data {
        var h = SHA256()
        h.update(data: Data("pixlz-pair-v1".utf8)); h.update(data: commit); h.update(data: devicePub); h.update(data: macPub)
        h.update(data: Data(macId.utf8)); h.update(data: Data([0])); h.update(data: Data(deviceId.utf8))
        return Data(h.finalize())
    }

    static func code(_ k: SymmetricKey) -> String {
        let m = Array(HMAC<SHA256>.authenticationCode(for: Data("pixlz-sas".utf8), using: k))
        let v = UInt32(m[0]) << 24 | UInt32(m[1]) << 16 | UInt32(m[2]) << 8 | UInt32(m[3])
        return String(format: "%06u", v % 1_000_000)
    }

    static func json(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    // MARK: decisions from a paired Mosaico

    /// What a paired Mosaico signed: valid only with the right key, a number above the last one
    /// used, and `seen` matching what this Mac sent for that request (summary and detail as sent).
    public static func verifyDecision(_ body: Data, deviceId: String, key: Data, lastCounter: UInt32,
                                      summary: String, detail: String) -> (id: String, behavior: String, n: UInt32)? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let d = o["agentDecision"] as? [String: Any], let id = d["id"] as? String, let behavior = d["behavior"] as? String,
              let n = (d["n"] as? NSNumber)?.uint32Value, let seen = d["seen"] as? String,
              let tagHex = d["tag"] as? String, let tag = Data(hex: tagHex), n > lastCounter,
              seen == Self.seen(summary: summary, detail: detail) else { return nil }
        let msg = "pixlz-decision-v1|\(deviceId)|\(n)|\(id)|\(behavior)|\(seen)"
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data(msg.utf8), using: SymmetricKey(data: key)) else { return nil }
        return (id, behavior, n)
    }

    /// A quick reply from a paired Mosaico: `{"agentReply":{"id","text","n","seen","tag"}}`, signed
    /// like a decision with behavior "reply" over ("reply", text). Only the known quick replies pass.
    public static func verifyReply(_ body: Data, deviceId: String, key: Data, lastCounter: UInt32) -> (id: String, text: String, n: UInt32)? {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let r = o["agentReply"] as? [String: Any], let id = r["id"] as? String, let text = r["text"] as? String,
              MosaicoFeed.quickReplies.contains(text) else { return nil }
        var d = r
        d["behavior"] = "reply"
        guard let wrapped = try? JSONSerialization.data(withJSONObject: ["agentDecision": d]),
              let ok = verifyDecision(wrapped, deviceId: deviceId, key: key, lastCounter: lastCounter, summary: "reply", detail: text),
              ok.id == id else { return nil }
        return (id, text, ok.n)
    }

    public static func seen(summary: String, detail: String) -> String {
        Data(SHA256.hash(data: Data((summary + "\n" + detail).utf8))).hex
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            d.append(b)
            i = j
        }
        self = d
    }
}
