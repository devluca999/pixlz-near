import Foundation

/// Talks to pixl-memory on 127.0.0.1. The token is read from the service's data
/// directory (mode 0600); it is never logged or shown.
public struct MemoryClient: Sendable {
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

    func request(_ path: String, method: String = "GET", body: [String: String]? = nil) throws(MemoryError) -> URLRequest {
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
        let (data, status) = try await send(try request("/polish", method: "POST", body: body))
        return try Self.decodePolish(data: data, status: status)
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
        let e = try? JSONDecoder().decode(Err.self, from: data)
        let msg = e?.message ?? "HTTP \(status)"
        switch (status, e?.error) {
        case (401, _): throw .badToken
        case (409, _): throw .attestationFailed(msg, e?.verification)
        case (412, _): throw .noApiKey(msg)
        case (402, "frogg_out_of_allowance"): throw .outOfAllowance(msg)
        case (402, _): throw .noCredits(msg)
        case (400, "not_private"): throw .notPrivate(msg)
        default: throw .upstream(msg)
        }
    }
}
