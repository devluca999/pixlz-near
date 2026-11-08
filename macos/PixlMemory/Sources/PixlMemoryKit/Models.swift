import Foundation

/// Shapes returned by the local pixl-memory service (memory/src/pixl_memory/server.py).
public struct Check: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let status: String  // pass | warn | fail | skip
    public let detail: String
}

public struct Verification: Codable, Sendable, Equatable {
    public let verdict: String  // verified | partial | failed
    public let summary: String
    public let checks: [Check]
    public let model: String
    public let signatureKind: String?
    public let modelSigningAddress: String?

    enum CodingKeys: String, CodingKey {
        case verdict, summary, checks, model
        case signatureKind = "signature_kind"
        case modelSigningAddress = "model_signing_address"
    }

    public var passed: Int { checks.filter { $0.status == "pass" || $0.status == "warn" }.count }

    public var badge: String {
        switch verdict {
        case "verified": "Verified in TEE"
        case "partial": "Partly verified"
        default: "Not verified"
        }
    }

    /// The deployment line from the model's signed deployment log, if present.
    public var deployment: String? {
        checks.first { $0.id == "model.deploy" && $0.status == "pass" }?.detail
    }
}

public struct DiffOp: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case equal, insert, delete }
    public let op: Kind
    public let text: String
    public init(op: Kind, text: String) { self.op = op; self.text = text }
}

public struct PolishResult: Codable, Sendable, Equatable {
    public let draftId: String
    public let suggestion: String
    public let diff: [DiffOp]
    public let verification: Verification

    enum CodingKeys: String, CodingKey {
        case suggestion, diff, verification
        case draftId = "draft_id"
    }
}

/// What can go wrong, in words Frogg can say.
public enum MemoryError: Error, Equatable, Sendable {
    case serviceDown
    case noToken
    case badToken
    case noApiKey(String)
    case noCredits(String)
    case notPrivate(String)
    case attestationFailed(String, Verification?)
    case upstream(String)

    public var bubble: String {
        switch self {
        case .serviceDown: "Start me first: make -C memory serve"
        case .noToken: "No token yet: run pixl-memory token"
        case .badToken: "My token is wrong. Restart the service?"
        case .noApiKey: "No NEAR AI key in .env yet"
        case .noCredits: "NEAR AI is out of credits"
        case .notPrivate: "That model isn't in a TEE. Refused."
        case .attestationFailed: "Enclave failed checks. Not sent."
        case .upstream: "NEAR AI hiccup. Try again?"
        }
    }

    public var detail: String {
        switch self {
        case .serviceDown: "The Pixl Memory service isn't running on 127.0.0.1:7341."
        case .noToken: "~/Library/Application Support/PixlMemory/token doesn't exist yet."
        case .badToken: "The service rejected the token."
        case .noApiKey(let m), .noCredits(let m), .notPrivate(let m), .upstream(let m): m
        case .attestationFailed(let m, _): m + " Your text was not sent."
        }
    }
}
