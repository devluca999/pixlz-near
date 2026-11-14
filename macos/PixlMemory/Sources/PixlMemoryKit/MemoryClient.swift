import Foundation

/// Talks to pixl-memory on 127.0.0.1. The token is read from the service's data
/// directory (mode 0600); it is never logged or shown.
public struct MemoryClient: Sendable {
    /// Which Pixl is asking (and paying, from its own `<pet>.<owner>` account). The app keeps it
    /// current with the Pixl on screen; nil means Frogg.
    /// Read from any task (each request reads it once); writes and reads go through a lock.
    public static var pet: String? {
        get { petLock.lock(); defer { petLock.unlock() }; return _pet }
        set { petLock.lock(); defer { petLock.unlock() }; _pet = newValue }
    }
    private static let petLock = NSLock()
    private nonisolated(unsafe) static var _pet: String?

    /// The wallet setup page for a Pixl (server.py `wallet_setup(pet=)`); nil pet means Frogg.
    public static func walletSetupURL(port: Int, pet: String?) -> URL {
        var c = URLComponents(string: "http://127.0.0.1:\(port)/wallet/setup")!
        if let pet, !pet.isEmpty { c.queryItems = [URLQueryItem(name: "pet", value: pet)] }
        return c.url!
    }

    /// A Pixl's wallet name from its skin id (the app's ids predate the names).
    public static func walletName(skinID: String) -> String {
        ["cat": "kiti", "shiba": "mochi", "ghost": "boo", "widow": "silky"][skinID] ?? skinID
    }

    var petQuery: String { Self.pet.map { "pet=\($0)" } ?? "" }

    /// The most highlights the service lists in one go (server.py `list_highlights` clamps to it).
    public static let highlightsMax = 500

    public var port: Int
    public var tokenURL: URL
    public var session: URLSession

    public init(port: Int = 7341,
                tokenURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: "Library/Application Support/PixlMemory/token"),
                session: URLSession = .shared) {
        self.port = port
        self.tokenURL = tokenURL
        self.session = session
    }

    func token() throws(MemoryError) -> String {
        guard let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { throw .noToken }
        return t
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws(MemoryError) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = method
        r.timeoutInterval = 180  // attestation + inference + signature
        r.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    public func polish(_ text: String, instruction: String?) async throws(MemoryError) -> PolishResult {
        var body = ["text": text]
        if let instruction { body["instruction"] = instruction }
        if let pet = Self.pet { body["pet"] = pet }
        let (data, status) = try await send(try request("/polish", method: "POST", body: body))
        return try Self.decodePolish(data: data, status: status)
    }

    /// Service, model and wallet lines for the mini menu and the menu bar.
    public func status() async -> ServiceStatus {
        struct Health: Decodable { let model: String; let has_api_key: Bool }
        struct Wallet: Decodable { let ready: Bool?; let account: String?; let balance_near: String?; let setup: String?; let spent_week_near: String? }
        guard let (hd, hs) = try? await send(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)), hs == 200,
              let h = try? JSONDecoder().decode(Health.self, from: hd) else {
            return ServiceStatus(service: "not running (make -C memory serve)")
        }
        var st = ServiceStatus(service: h.has_api_key ? "running" : "running, no NEAR AI key", model: h.model)
        if let r = try? request("/wallet?\(petQuery)"), let (wd, ws) = try? await send(r), ws == 200,
           let w = try? JSONDecoder().decode(Wallet.self, from: wd) {
            st.walletReady = w.ready == true
            st.wallet = w.ready == true ? "\(w.account ?? "your Pixl") · \(w.balance_near ?? "?") Ⓝ" : (w.setup ?? "not set up")
            st.balance = w.balance_near
            st.spentWeek = w.spent_week_near
        }
        // the service lists at most 500 (and has no count): a full page reads "500+"
        let n = await highlights(limit: Self.highlightsMax).count
        st.highlights = n
        st.highlightsAtLeast = n >= Self.highlightsMax
        return st
    }

    public func ask(_ question: String, name: String, personality: String, web: Bool = true) async throws(MemoryError) -> AskResult {
        let (data, status) = try await send(try request("/ask", method: "POST",
                                                        body: ["question": question, "name": name, "personality": personality, "web": web,
                                                               "pet": Self.pet ?? "frogg"]))
        if status == 200 {
            do { return try JSONDecoder().decode(AskResult.self, from: data) } catch { throw .upstream("Unreadable reply from the service") }
        }
        throw Self.error(data: data, status: status)
    }

    /// Saves a note (or an answer) into memory, encrypted like a highlight. No URL: it's yours.
    public func saveNote(_ text: String, title: String?, folder: String?, url: String? = nil, fragmentURL: String? = nil) async throws(MemoryError) -> HighlightItem {
        var body = ["text": text]
        if let fragmentURL { body["fragment_url"] = fragmentURL }
        if let title { body["title"] = title }
        if let url { body["url"] = url }
        if let folder { body["folder"] = folder }
        let (d, s) = try await send(try request("/highlights", method: "POST", body: body))
        if (200..<300).contains(s), let h = try? JSONDecoder().decode(HighlightItem.self, from: d) { return h }
        throw Self.error(data: d, status: s)
    }

    /// A fresh attestation of the private model's enclave (TDX + GPU), checked by the service.
    public func attestation() async -> Verification? {
        guard let r = try? request("/attestation"), let (d, s) = try? await send(r), s == 200 else { return nil }
        return try? JSONDecoder().decode(Verification.self, from: d)
    }

    public func highlights(limit: Int = 30) async -> [HighlightItem] {
        struct List: Decodable { let highlights: [HighlightItem] }
        guard let r = try? request("/highlights?limit=\(limit)"), let (d, s) = try? await send(r), s == 200 else { return [] }
        return (try? JSONDecoder().decode(List.self, from: d))?.highlights ?? []
    }

    /// POST /wallet/limits: the user's weekly limit and pause (inside the owner's ceilings).
    public func setLimits(perWeekNear: String? = nil, perDayNear: String? = nil, paused: Bool? = nil) async throws(MemoryError) -> WalletInfo {
        var r = try request("/wallet/limits", method: "POST")
        var body: [String: Any] = [:]
        if let pet = Self.pet { body["pet"] = pet }
        if let perWeekNear { body["per_week_near"] = perWeekNear }
        if let perDayNear { body["per_day_near"] = perDayNear }
        if let paused { body["paused"] = paused }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await send(r)
        if status == 200, let w = try? JSONDecoder().decode(WalletInfo.self, from: data) { return w }
        throw Self.error(data: data, status: status)
    }

    public func wallet() async -> WalletInfo? {
        guard let r = try? request("/wallet?\(petQuery)"), let (d, s) = try? await send(r), s == 200 else { return nil }
        return try? JSONDecoder().decode(WalletInfo.self, from: d)
    }

    public func payments(limit: Int = 5) async -> [Receipt] {
        struct List: Decodable { let payments: [Receipt] }
        guard let r = try? request("/wallet/payments?limit=\(limit)&\(petQuery)"), let (d, s) = try? await send(r), s == 200 else { return [] }
        return (try? JSONDecoder().decode(List.self, from: d))?.payments ?? []
    }

    public func markAccepted(draftId: String) async {
        guard let r = try? request("/drafts/\(draftId)/status", method: "POST", body: ["status": "accepted"]) else { return }
        _ = try? await session.data(for: r)
    }

    func send(_ r: URLRequest) async throws(MemoryError) -> (Data, Int) {
        do {
            let (data, resp) = try await session.data(for: r)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw .serviceDown
        }
    }

    /// Maps the service's responses (see server.py `do_polish`) to a result or an error.
    public static func decodePolish(data: Data, status: Int) throws(MemoryError) -> PolishResult {
        struct Err: Decodable { let error: String?; let message: String?; let verification: Verification? }
        if status == 200 {
            do { return try JSONDecoder().decode(PolishResult.self, from: data) } catch { throw .upstream("Unreadable reply from the service") }
        }
        throw error(data: data, status: status)
    }

    /// By the error's code (`error`), not just the status: 409 is an enclave that failed its
    /// checks only when it says so (`no_wallet` is 409 too). FastAPI's own errors carry `detail`.
    public static func error(data: Data, status: Int) -> MemoryError {
        struct Err: Decodable { let error: String?; let message: String?; let verification: Verification? }
        let e = try? JSONDecoder().decode(Err.self, from: data)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = e?.message ?? (o?["detail"] as? String) ?? "HTTP \(status)"
        switch (status, e?.error) {
        case (401, _): return .badToken
        case (_, "attestation_failed"): return .attestationFailed(msg, e?.verification)
        case (409, nil) where e?.verification != nil: return .attestationFailed(msg, e?.verification)
        case (_, "no_wallet"), (_, "bad_limit"): return .rejected(msg)
        case (_, "no_api_key"), (412, _): return .noApiKey(msg)
        case (_, "frogg_out_of_allowance"): return .outOfAllowance(msg)
        case (_, "no_credits"): return .noCredits(msg)
        case (_, "not_private"): return .notPrivate(msg)
        case (_, "offline"): return .offline(msg)
        case (402, _): return .noCredits(msg)
        case (400..<500, _): return .rejected(msg)
        default: return .upstream(msg)
        }
    }
}
