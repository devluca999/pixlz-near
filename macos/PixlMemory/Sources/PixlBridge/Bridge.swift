import CryptoKit
import Foundation

// The Chrome extension ↔ Mac app bridge (SPEC §6.7). Three hops:
//
//   extension ──native messaging (stdin/stdout)──▶ pixl-native-host ──HTTP + token──▶ pixl-memory
//                                                          │
//                                                          └──Unix socket (JSON lines)──▶ Pixl Memory.app
//
// The extension never holds the service token: the host reads it from the service's data dir
// and only forwards an allowlist of routes. The app asks the extension for the page selection
// (and to replace it) through the same host.

/// A JSON value, so messages can carry arbitrary request and response bodies.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { o[key] } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
}

/// One message on any hop. `type` says what it is; the other fields depend on it.
public struct BridgeMessage: Codable, Equatable, Sendable {
    public var id: String?
    public var type: String
    // api (extension → host → service)
    public var method: String?
    public var path: String?
    public var body: JSONValue?
    // replies
    public var ok: Bool?
    public var status: Int?
    public var error: String?
    // selection (app ↔ extension)
    public var text: String?
    public var original: String?
    public var url: String?
    public var title: String?
    public var app: String?

    public init(id: String? = nil, type: String, method: String? = nil, path: String? = nil, body: JSONValue? = nil,
                ok: Bool? = nil, status: Int? = nil, error: String? = nil, text: String? = nil, original: String? = nil,
                url: String? = nil, title: String? = nil, app: String? = nil) {
        self.id = id; self.type = type; self.method = method; self.path = path; self.body = body
        self.ok = ok; self.status = status; self.error = error; self.text = text; self.original = original
        self.url = url; self.title = title; self.app = app
    }

    /// Message types.
    public enum Kind {
        public static let api = "api"                    // extension → host: call the service
        public static let apiResult = "api_result"       // host → extension
        public static let hello = "hello"                // extension → host → app: a browser is connected
        public static let getSelection = "get_selection" // app → extension
        public static let selection = "selection"        // extension → app
        public static let replace = "replace_selection"  // app → extension
        public static let replaced = "replaced"          // extension → app
        public static let status = "status"              // host → extension: is the app connected?
    }
}

// MARK: - Chrome native messaging framing

/// Chrome's native messaging framing: a 32-bit length in native byte order (little-endian on
/// every Mac), then that many bytes of UTF-8 JSON.
public enum NativeFraming {
    /// Chrome refuses messages from a host larger than 1 MB.
    public static let maxToChrome = 1024 * 1024
    /// Chrome sends at most 64 MB; we accept far less (a highlight or a page selection).
    public static let maxFromChrome = 4 * 1024 * 1024

    public enum Failure: Error, Equatable { case tooLarge(Int), notJSON }

    public static func encode(_ message: BridgeMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        guard json.count <= maxToChrome else { throw Failure.tooLarge(json.count) }
        var length = UInt32(json.count).littleEndian
        return Data(bytes: &length, count: 4) + json
    }

    /// Accumulates bytes from stdin and yields whole messages, however the reads split them.
    public struct Decoder {
        var buffer = Data()
        public init() {}

        public mutating func feed(_ data: Data) throws -> [BridgeMessage] {
            buffer.append(data)
            var out: [BridgeMessage] = []
            while buffer.count >= 4 {
                let b = [UInt8](buffer.prefix(4))
                let length = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
                guard length <= maxFromChrome else { buffer.removeAll(); throw Failure.tooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer.removeFirst(4 + length)
                guard let m = try? JSONDecoder().decode(BridgeMessage.self, from: body) else { throw Failure.notJSON }
                out.append(m)
            }
            return out
        }
    }
}

/// JSON lines on the Unix socket between the host and the app.
public enum LineFraming {
    public static func encode(_ message: BridgeMessage) throws -> Data {
        var d = try JSONEncoder().encode(message)   // JSONEncoder never emits raw newlines
        d.append(0x0A)
        return d
    }

    public struct Decoder {
        var buffer = Data()
        public init() {}
        public mutating func feed(_ data: Data) -> [BridgeMessage] {
            buffer.append(data)
            var out: [BridgeMessage] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex ..< nl)
                buffer.removeSubrange(buffer.startIndex ... nl)
                if let m = try? JSONDecoder().decode(BridgeMessage.self, from: line) { out.append(m) }
            }
            if buffer.count > NativeFraming.maxFromChrome { buffer.removeAll() }  // a runaway line: drop it
            return out
        }
    }
}

// MARK: - What the extension may call

/// The service routes the extension may reach through the host. Anything else (drafts,
/// wallet setup, attestation internals) is refused before it leaves the host.
public enum ServiceRoutes {
    static let exact: Set<String> = ["GET /health", "GET /highlights", "POST /highlights", "POST /ask", "POST /polish", "GET /wallet"]

    public static func allowed(method: String, path: String) -> Bool {
        let m = method.uppercased()
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("//"), path.count < 512 else { return false }
        let bare = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        if exact.contains("\(m) \(bare)") { return true }
        // DELETE /highlights/<id>: one opaque id segment
        if m == "DELETE", bare.hasPrefix("/highlights/") {
            let id = bare.dropFirst("/highlights/".count)
            return !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        return false
    }
}

// MARK: - Routing inside the host

/// The host's routing decisions, kept free of I/O so they can be tested.
public enum HostRouting {
    public enum Action: Equatable {
        case callService(method: String, path: String, body: JSONValue?, id: String?)
        case toApp(BridgeMessage)
        case toExtension(BridgeMessage)
    }

    /// A message from the extension.
    public static func fromExtension(_ m: BridgeMessage, appConnected: Bool) -> Action {
        switch m.type {
        case BridgeMessage.Kind.api:
            guard let method = m.method, let path = m.path, ServiceRoutes.allowed(method: method, path: path) else {
                return .toExtension(BridgeMessage(id: m.id, type: BridgeMessage.Kind.apiResult, ok: false, status: 403,
                                                  error: "route not allowed through the native host"))
            }
            return .callService(method: method.uppercased(), path: path, body: m.body, id: m.id)
        case BridgeMessage.Kind.selection, BridgeMessage.Kind.replaced, BridgeMessage.Kind.hello:
            guard appConnected else {
                return .toExtension(BridgeMessage(id: m.id, type: BridgeMessage.Kind.status, ok: false, error: "Pixl Memory app isn't running"))
            }
            return .toApp(m)
        default:
            return .toExtension(BridgeMessage(id: m.id, type: BridgeMessage.Kind.apiResult, ok: false, status: 400,
                                              error: "unknown message type \(m.type)"))
        }
    }

    /// A message from the app: only selection requests go on to the extension.
    public static func fromApp(_ m: BridgeMessage) -> Action? {
        [BridgeMessage.Kind.getSelection, BridgeMessage.Kind.replace].contains(m.type) ? .toExtension(m) : nil
    }
}

// MARK: - Installing the host for Chromium browsers

public enum NativeHostManifest {
    public static let name = "dev.pixlz.pixl_memory"

    /// The extension's public key (manifest.json `key`), which pins its ID to
    /// chmeigilhkkegiaabjlcidbkgahemceh. Public by design; no private key is kept (unpacked
    /// extensions don't need one).
    public static let extensionKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1jEYkQQMAvyoczbU6jOkzhUYjrqEN4U4h1umPz6grbsxNv/4MZidFACMZJlG4s8xmiMyTO/rLP4EqHWWP5ELaIVR8EPon0sVBi4jG/K0Sy8JQO9ER8NCbaL8pT3wF14jP2ApYyl8mtG+hE+2++flyamV54lWPOHLnc3x1i/nrUZ7jdezM2A9HyDgcXUZ6WO49VbCyp+Lnjx9/XEMv7x7eg7EvlZGyZ0aa1MWN50DpRd7lQNkAX0pzEes4jVxuzPzTrF56F9hYAt7FuRkea6rJqPsSaGZ+Pg+TK8tWXj8u5A/USu1rPjGAf5WLQFZHN1nqF8gc4geP2zzupN0+jU5+QIDAQAB"

    /// Chrome's extension ID for a public key: the first 128 bits of SHA-256 over the key's
    /// DER bytes, written with the letters a–p instead of hex digits.
    public static func extensionID(publicKeyBase64: String) -> String? {
        guard let der = Data(base64Encoded: publicKeyBase64) else { return nil }
        let digest = SHA256.hash(data: der)
        return digest.prefix(16).map { b in
            let hi = Character(UnicodeScalar(UInt8(ascii: "a") + (b >> 4)))
            let lo = Character(UnicodeScalar(UInt8(ascii: "a") + (b & 0x0F)))
            return String([hi, lo])
        }.joined()
    }

    public static func manifest(hostPath: String, extensionIDs: [String]) throws -> Data {
        let obj: [String: Any] = [
            "name": name,
            "description": "Pixl Memory: saves highlights and polishes text privately on this Mac",
            "path": hostPath,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Per-browser NativeMessagingHosts folders, for browsers that are installed (their
    /// Application Support folder exists).
    public static func folders(home: URL, fileManager fm: FileManager = .default) -> [URL] {
        let support = home.appending(path: "Library/Application Support")
        let browsers = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium",
                        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Vivaldi"]
        return browsers.compactMap { b in
            let dir = support.appending(path: b)
            return fm.fileExists(atPath: dir.path) ? dir.appending(path: "NativeMessagingHosts") : nil
        }
    }

    /// Writes the manifest into every installed browser's folder. Returns the files written.
    @discardableResult
    public static func install(hostPath: String, extensionIDs: [String], home: URL, fileManager fm: FileManager = .default) throws -> [URL] {
        let data = try manifest(hostPath: hostPath, extensionIDs: extensionIDs)
        var written: [URL] = []
        for dir in folders(home: home, fileManager: fm) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: "\(name).json")
            if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
            written.append(file)
        }
        return written
    }
}

/// Where the app listens for the host.
public enum BridgeSocket {
    public static func path(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appending(path: "Library/Application Support/PixlMemory/bridge.sock").path
    }
}
