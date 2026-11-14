import Darwin
import Foundation
import Testing
@testable import PixlBridge

struct FramingTests {
    func frame(_ json: String) -> Data {
        var n = UInt32(json.utf8.count).littleEndian
        return Data(bytes: &n, count: 4) + Data(json.utf8)
    }

    @Test func roundTripsThroughChromesFraming() throws {
        let m = BridgeMessage(id: "7", type: "api", method: "POST", path: "/highlights",
                              body: .object(["text": .string("ünïcode ✓ \"quoted\"\nline"), "n": .number(3), "ok": .bool(true), "x": .null]))
        let data = try NativeFraming.encode(m)
        let len = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(Int(UInt32(littleEndian: len)) == data.count - 4)       // 32-bit little-endian length
        var d = NativeFraming.Decoder()
        #expect(try d.feed(data) == [m])
    }

    @Test func messagesSplitAcrossReadsAndPackedTogether() throws {
        let a = frame(#"{"type":"api","id":"1","method":"GET","path":"/health"}"#)
        let b = frame(#"{"type":"selection","id":"app-2","text":"hello","ok":true}"#)
        let all = a + b
        var d = NativeFraming.Decoder()
        var got: [BridgeMessage] = []
        for byte in all { got += try d.feed(Data([byte])) }               // one byte at a time
        #expect(got.map(\.id) == ["1", "app-2"] && got[1].text == "hello")
        var d2 = NativeFraming.Decoder()
        #expect(try d2.feed(all).count == 2)                              // both in one read
        var d3 = NativeFraming.Decoder()
        #expect(try d3.feed(a.prefix(3)).isEmpty)                         // partial length
        #expect(try d3.feed(a.dropFirst(3)).count == 1)
    }

    @Test func rejectsOversizeAndGarbage() {
        var huge = UInt32(NativeFraming.maxFromChrome + 1).littleEndian
        var d = NativeFraming.Decoder()
        #expect(throws: NativeFraming.Failure.tooLarge(NativeFraming.maxFromChrome + 1)) { try d.feed(Data(bytes: &huge, count: 4)) }
        var d2 = NativeFraming.Decoder()
        #expect(throws: NativeFraming.Failure.notJSON) { try d2.feed(frame("not json")) }
        let big = BridgeMessage(type: "api_result", text: String(repeating: "x", count: NativeFraming.maxToChrome))
        #expect(throws: NativeFraming.Failure.tooLarge(NativeFraming.maxToChrome + 31)) { try NativeFraming.encode(big) }
    }

    @Test func socketLinesSurviveNewlinesInsideText() throws {
        let m = BridgeMessage(id: "app-1", type: "replace_selection", text: "two\nlines", original: "a\nb")
        let data = try LineFraming.encode(m) + LineFraming.encode(BridgeMessage(type: "hello", app: "Chrome"))
        var d = LineFraming.Decoder()
        let got = d.feed(data.prefix(10)) + d.feed(data.dropFirst(10))
        #expect(got.count == 2 && got[0] == m && got[1].app == "Chrome")
    }
}

struct RoutingTests {
    @Test func onlyAllowlistedServiceRoutesPass() {
        for (m, p) in [("GET", "/health"), ("GET", "/highlights?limit=5&q=frog"), ("POST", "/highlights"), ("post", "/ask"),
                       ("POST", "/polish"), ("GET", "/wallet"), ("DELETE", "/highlights/h_01J9ZK-x"), ("GET", "/folders"),
                       ("PATCH", "/highlights/h_01J9ZK-x")] {
            #expect(ServiceRoutes.allowed(method: m, path: p), "\(m) \(p)")
        }
        for (m, p) in [("GET", "/drafts"), ("GET", "/wallet/setup"), ("POST", "/wallet/setup"), ("GET", "/attestation"),
                       ("DELETE", "/highlights/../drafts"), ("DELETE", "/highlights/"), ("DELETE", "/highlights/a/b"),
                       ("GET", "highlights"), ("GET", "//evil.example/highlights"), ("PUT", "/highlights"),
                       ("GET", "/highlights/../../token"), ("DELETE", "/highlights/a%2Fb"), ("POST", "/wallet/limits"),
                       ("PATCH", "/folders")] {
            #expect(!ServiceRoutes.allowed(method: m, path: p), "\(m) \(p)")
        }
    }

    @Test func extensionMessagesRouteToServiceAppOrBack() {
        let api = BridgeMessage(id: "1", type: "api", method: "post", path: "/ask", body: .object(["question": .string("hi")]))
        #expect(HostRouting.fromExtension(api, appConnected: false) == .callService(method: "POST", path: "/ask", body: api.body, id: "1"))

        guard case .toExtension(let refused) = HostRouting.fromExtension(BridgeMessage(id: "2", type: "api", method: "GET", path: "/drafts"), appConnected: true)
        else { Issue.record("expected a refusal"); return }
        #expect(refused.id == "2" && refused.ok == false && refused.status == 403)

        let sel = BridgeMessage(id: "app-3", type: "selection", ok: true, text: "the passage")
        #expect(HostRouting.fromExtension(sel, appConnected: true) == .toApp(sel))
        guard case .toExtension(let noApp) = HostRouting.fromExtension(sel, appConnected: false) else { Issue.record("expected status"); return }
        #expect(noApp.type == "status" && noApp.ok == false)

        guard case .toExtension(let unknown) = HostRouting.fromExtension(BridgeMessage(id: "4", type: "shell"), appConnected: true)
        else { Issue.record("expected a refusal"); return }
        #expect(unknown.status == 400)
    }

    @Test func theAppMayOnlyAskForTheSelectionOrAReplace() {
        let get = BridgeMessage(id: "app-1", type: "get_selection")
        let rep = BridgeMessage(id: "app-2", type: "replace_selection", text: "new", original: "old")
        #expect(HostRouting.fromApp(get) == .toExtension(get))
        #expect(HostRouting.fromApp(rep) == .toExtension(rep))
        #expect(HostRouting.fromApp(BridgeMessage(type: "api", method: "DELETE", path: "/highlights/x")) == nil)
        #expect(HostRouting.fromApp(BridgeMessage(type: "api_result")) == nil)
    }

    @Test func saveThisAndPageTextGoBothWays() {
        let save = BridgeMessage(id: "app-3", type: "save_page", text: "my note")
        let text = BridgeMessage(id: "app-4", type: "page_text")
        #expect(HostRouting.fromApp(save) == .toExtension(save))
        #expect(HostRouting.fromApp(text) == .toExtension(text))
        let saved = BridgeMessage(id: "app-3", type: "saved", ok: true)
        let page = BridgeMessage(id: "app-4", type: "page", ok: true, text: "a\n\nb")
        #expect(HostRouting.fromExtension(saved, appConnected: true) == .toApp(saved))
        #expect(HostRouting.fromExtension(page, appConnected: true) == .toApp(page))
        guard case .toExtension(let noApp) = HostRouting.fromExtension(page, appConnected: false) else { Issue.record("expected status"); return }
        #expect(noApp.type == "status" && noApp.ok == false)
    }
}

struct ManifestTests {
    @Test func extensionIDComesFromThePublicKey() throws {
        // Matches Chrome's rule (and our Python cross-check when the key was made).
        #expect(NativeHostManifest.extensionID(publicKeyBase64: NativeHostManifest.extensionKey) == "chmeigilhkkegiaabjlcidbkgahemceh")
        // …and extension/manifest.json carries the same key.
        let manifest = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../extension/manifest.json").standardized
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        #expect(json?["key"] as? String == NativeHostManifest.extensionKey)
        #expect((json?["permissions"] as? [String])?.contains("nativeMessaging") == true)
    }

    @Test func hostManifestIsWhatChromeExpects() throws {
        let data = try NativeHostManifest.manifest(hostPath: "/Users/x/Applications/Pixl Memory.app/Contents/MacOS/pixl-native-host",
                                                   extensionIDs: ["chmeigilhkkegiaabjlcidbkgahemceh"])
        let j = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(j["name"] as? String == "dev.pixlz.pixl_memory")             // lowercase, dots, underscores only
        #expect(j["type"] as? String == "stdio")
        #expect((j["path"] as? String)?.hasPrefix("/") == true)              // absolute on macOS
        #expect(j["allowed_origins"] as? [String] == ["chrome-extension://chmeigilhkkegiaabjlcidbkgahemceh/"])  // no wildcards
    }

    @Test func installsOnlyForBrowsersThatExist() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "pixl-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "Library/Application Support")
        try FileManager.default.createDirectory(at: support.appending(path: "Google/Chrome"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appending(path: "BraveSoftware/Brave-Browser"), withIntermediateDirectories: true)
        let files = try NativeHostManifest.install(hostPath: "/Applications/Pixl Memory.app/Contents/MacOS/pixl-native-host",
                                                   extensionIDs: ["chmeigilhkkegiaabjlcidbkgahemceh"], home: home)
        #expect(Set(files.map { $0.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent }) == ["Chrome", "Brave-Browser"])
        #expect(files.allSatisfy { $0.lastPathComponent == "dev.pixlz.pixl_memory.json" && FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: support.appending(path: "Microsoft Edge").path))   // not created
    }
}

/// Runs the real pixl-native-host binary: Chrome's side on stdin/stdout, the app's side on a
/// Unix socket in a temporary home folder.
struct HostProcessTests {
    var hostBinary: URL? {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../.build/debug/pixl-native-host").standardized
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    final class Host: @unchecked Sendable {  // state guarded by `lock`
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        var decoder = NativeFraming.Decoder(), received: [BridgeMessage] = []
        let lock = NSLock()
        init(binary: URL, home: URL) throws {
            process.executableURL = binary
            process.environment = ["PIXL_HOME": home.path, "PIXL_MEMORY_PORT": "1"]   // nothing listens on port 1
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
                guard let self else { return }
                let d = h.availableData
                self.lock.lock(); defer { self.lock.unlock() }
                if let ms = try? self.decoder.feed(d) { self.received += ms }
            }
            try process.run()
        }
        func send(_ m: BridgeMessage) throws { stdin.fileHandleForWriting.write(try NativeFraming.encode(m)) }
        func wait(for pred: (BridgeMessage) -> Bool, timeout: Double = 5) -> BridgeMessage? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                lock.lock(); let hit = received.first(where: pred); lock.unlock()
                if let hit { return hit }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return nil
        }
    }

    @Test func hostRefusesRoutesReportsMissingServiceAndRelaysTheApp() throws {
        guard let bin = hostBinary else { return }  // built by `swift build` before `swift test`
        let home = URL(fileURLWithPath: "/tmp/ph-\(UInt32.random(in: 0...UInt32.max))")  // short: socket paths max 104 bytes
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appending(path: "Library/Application Support/PixlMemory")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // the app's side: listen before the host starts
        let path = BridgeSocket.path(home: home)
        let ls = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) } }
        #expect(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ls, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0)
        #expect(listen(ls, 1) == 0)
        defer { close(ls) }

        let host = try Host(binary: bin, home: home)
        defer { if host.process.isRunning { host.process.terminate() } }

        // the host connects to the app and says so to the extension
        let c = accept(ls, nil, nil)
        #expect(c >= 0)
        defer { close(c) }
        #expect(host.wait { $0.type == "status" && $0.ok == true } != nil)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(c, &buf, buf.count)
        var lines = LineFraming.Decoder()
        #expect(lines.feed(Data(buf[0..<max(n, 0)])).first?.type == "hello")

        // a route outside the allowlist never reaches the service
        try host.send(BridgeMessage(id: "x1", type: "api", method: "GET", path: "/drafts"))
        #expect(host.wait { $0.id == "x1" }?.status == 403)
        // no token in this home: an allowed route says the service isn't set up (and the token never leaves the host)
        try host.send(BridgeMessage(id: "x2", type: "api", method: "GET", path: "/health"))
        let noToken = host.wait { $0.id == "x2" }
        #expect(noToken?.ok == false && noToken?.status == 503)
        // with a token but nothing listening: "isn't running"
        try "0123".write(to: dir.appending(path: "token"), atomically: true, encoding: .utf8)
        try host.send(BridgeMessage(id: "x3", type: "api", method: "GET", path: "/health"))
        #expect(host.wait { $0.id == "x3" }?.error?.contains("isn't running") == true)

        // the app asks for the selection; the extension's answer comes back to the app
        let ask = try LineFraming.encode(BridgeMessage(id: "app-1", type: "get_selection"))
        _ = ask.withUnsafeBytes { write(c, $0.baseAddress, ask.count) }
        #expect(host.wait { $0.id == "app-1" && $0.type == "get_selection" } != nil)
        try host.send(BridgeMessage(id: "app-1", type: "selection", ok: true, text: "the passage", url: "https://example.com/"))
        var got: BridgeMessage?
        for _ in 0..<100 where got == nil {
            let k = read(c, &buf, buf.count)
            if k > 0 { got = lines.feed(Data(buf[0..<k])).first { $0.id == "app-1" } } else { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(got?.text == "the passage" && got?.url == "https://example.com/")

        // the app can't use the host to reach the service
        let sneaky = try LineFraming.encode(BridgeMessage(id: "app-2", type: "api", method: "DELETE", path: "/highlights/abc"))
        _ = sneaky.withUnsafeBytes { write(c, $0.baseAddress, sneaky.count) }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(host.wait(for: { $0.id == "app-2" }, timeout: 0.2) == nil)

        // Chrome closing the port ends the host
        host.stdin.fileHandleForWriting.closeFile()
        host.process.waitUntilExit()
        #expect(host.process.terminationStatus == 0)
    }
}
