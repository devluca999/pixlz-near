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

/// What Frogg paid for this request from its own testnet account (memory/wallet.py).
public struct Receipt: Codable, Sendable, Equatable {
    public let status: String  // paid | refused | failed
    public let amountNear: String?
    public let to: String?
    public let txHash: String?
    public let explorer: String?
    public let balanceAfterNear: String?
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case status, to, explorer, reason
        case amountNear = "amount_near"
        case txHash = "tx_hash"
        case balanceAfterNear = "balance_after_near"
    }

    public init(status: String, amountNear: String?, to: String?, txHash: String?, explorer: String?,
                balanceAfterNear: String?, reason: String?) {
        self.status = status; self.amountNear = amountNear; self.to = to; self.txHash = txHash
        self.explorer = explorer; self.balanceAfterNear = balanceAfterNear; self.reason = reason
    }

    /// One line for Frogg's thought bubble.
    public var bubble: String {
        switch status {
        case "paid":
            let left = balanceAfterNear.map { " · \($0) Ⓝ left" } ?? ""
            return "Paid \(amountNear ?? "?") Ⓝ\(left)"
        case "refused": return "Didn't pay: \(reason ?? "cap reached")"
        default: return "Payment failed"
        }
    }
}

public struct PolishResult: Codable, Sendable, Equatable {
    public let draftId: String
    public let suggestion: String
    public let diff: [DiffOp]
    public let verification: Verification
    public let receipt: Receipt?

    enum CodingKeys: String, CodingKey {
        case suggestion, diff, verification, receipt
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
    case outOfAllowance(String)
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
        case .outOfAllowance: "I'm out of allowance for today"
        case .upstream: "NEAR AI hiccup. Try again?"
        }
    }

    public var detail: String {
        switch self {
        case .serviceDown: "The Pixl Memory service isn't running on 127.0.0.1:7341."
        case .noToken: "~/Library/Application Support/PixlMemory/token doesn't exist yet."
        case .badToken: "The service rejected the token."
        case .noApiKey(let m), .noCredits(let m), .notPrivate(let m), .upstream(let m): m
        case .outOfAllowance(let m): m + " Your text was not sent. Top up Frogg or wait until tomorrow (UTC)."
        case .attestationFailed(let m, _): m + " Your text was not sent."
        }
    }
}

/// GET /wallet (memory/wallet.py `status`).
public struct WalletInfo: Codable, Sendable, Equatable {
    public struct Caps: Codable, Sendable, Equatable {
        public let perRequestNear: String, perDayNear: String, reserveNear: String
        public let perWeekNear: String?
        enum CodingKeys: String, CodingKey {
            case perRequestNear = "per_request_near", perDayNear = "per_day_near", reserveNear = "reserve_near", perWeekNear = "per_week_near"
        }
    }
    /// The owner's ceilings (.env): the user's limits can go up to these.
    public struct Ceilings: Codable, Sendable, Equatable {
        public let perDayNear: String, perWeekNear: String
        enum CodingKeys: String, CodingKey { case perDayNear = "per_day_near", perWeekNear = "per_week_near" }
    }
    public let account: String?
    public let payee: String?
    public let balanceNear: String?
    public let spendableNear: String?
    public let spentTodayNear: String?
    public let caps: Caps?
    public let ready: Bool?
    public let setup: String?
    public let explorer: String?
    public var ceilings: Ceilings? = nil
    public var paused: Bool? = nil
    public var spentWeekNear: String? = nil
    public var weekResets: String? = nil
    enum CodingKeys: String, CodingKey {
        case account, payee, caps, ready, setup, explorer, ceilings, paused
        case balanceNear = "balance_near", spendableNear = "spendable_near", spentTodayNear = "spent_today_near"
        case spentWeekNear = "spent_week_near", weekResets = "week_resets"
    }
    public init(account: String?, payee: String?, balanceNear: String?, spendableNear: String?, spentTodayNear: String?,
                caps: Caps?, ready: Bool?, setup: String?, explorer: String?) {
        self.account = account; self.payee = payee; self.balanceNear = balanceNear; self.spendableNear = spendableNear
        self.spentTodayNear = spentTodayNear; self.caps = caps; self.ready = ready; self.setup = setup; self.explorer = explorer
    }
    /// The bubble label's sub-line, e.g. "0.95 Ⓝ".
    public var short: String? { ready == true ? balanceNear.map { "\($0) Ⓝ" } : nil }
}

/// GET /highlights.
public struct HighlightItem: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let url: String?
    public let title: String?
    public let fragmentUrl: String?
    enum CodingKeys: String, CodingKey { case id, text, url, title, fragmentUrl = "fragment_url" }
    public init(id: String, text: String, url: String?, title: String?, fragmentUrl: String?) {
        self.id = id; self.text = text; self.url = url; self.title = title; self.fragmentUrl = fragmentUrl
    }
    public var link: URL? { (fragmentUrl ?? url).flatMap(URL.init(string:)) }
}

/// POST /ask.
public struct AskResult: Codable, Sendable, Equatable {
    public let answer: String
    public let verification: Verification
    public let receipt: Receipt?
    /// Saved highlights that matched the question and went along as context, with backlinks.
    public let highlights: [HighlightItem]?
}
