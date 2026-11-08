// pixl-native-host: Chrome starts this when the Pixl Memory extension connects
// (chrome.runtime.connectNative). It lives as long as the extension's port is open.
//
// stdin/stdout: Chrome native messaging (32-bit length + JSON).
// To the service: HTTP on 127.0.0.1 with the token from the service's data dir (the extension
// never sees it), allowlisted routes only.
// To the app: a Unix socket in ~/Library/Application Support/PixlMemory (JSON lines).

import Darwin
import Foundation
import PixlBridge

// PIXL_HOME: tests run the host against a temporary home folder
let home = ProcessInfo.processInfo.environment["PIXL_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
let port = Int(ProcessInfo.processInfo.environment["PIXL_MEMORY_PORT"] ?? "") ?? 7341
let tokenURL = home.appending(path: "Library/Application Support/PixlMemory/token")
let out = FileHandle.standardOutput
let writeLock = NSLock()
let queue = DispatchQueue(label: "pixl.host")

func log(_ s: String) { FileHandle.standardError.write(Data("pixl-native-host: \(s)\n".utf8)) }

func toExtension(_ m: BridgeMessage) {
    do {
        let data = try NativeFraming.encode(m)
        writeLock.lock(); out.write(data); writeLock.unlock()
    } catch {
        let e = BridgeMessage(id: m.id, type: m.type, ok: false, error: "reply too large for Chrome")
        if let d = try? NativeFraming.encode(e) { writeLock.lock(); out.write(d); writeLock.unlock() }
    }
}

// MARK: service

func callService(method: String, path: String, body: JSONValue?, id: String?) {
    guard let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
        toExtension(BridgeMessage(id: id, type: BridgeMessage.Kind.apiResult, ok: false, status: 503,
                                  error: "Pixl Memory's service hasn't been set up on this Mac yet"))
        return
    }
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 120  // polish/ask wait on attestation + inference
    if let body {
        req.httpBody = try? JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    URLSession.shared.dataTask(with: req) { data, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if error != nil || status == 0 {
            toExtension(BridgeMessage(id: id, type: BridgeMessage.Kind.apiResult, ok: false, status: 503,
                                      error: "Pixl Memory isn't running (start the service)"))
            return
        }
        let json = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        toExtension(BridgeMessage(id: id, type: BridgeMessage.Kind.apiResult, body: json, ok: (200..<300).contains(status), status: status,
                                  error: (200..<300).contains(status) ? nil : json?["message"]?.string ?? json?["detail"]?.string ?? "service returned \(status)"))
    }.resume()
}

// MARK: app socket

final class AppLink {
    var fd: Int32 = -1
    var source: DispatchSourceRead?
    var decoder = LineFraming.Decoder()
    var connected: Bool { fd >= 0 }

    func connect() {
        guard fd < 0 else { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = BridgeSocket.path(home: home)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) } }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(s); return }
        fd = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.read() }
        src.setCancelHandler { close(s) }
        src.resume()
        source = src
        toExtension(BridgeMessage(type: BridgeMessage.Kind.status, ok: true, app: "Pixl Memory"))
        send(BridgeMessage(type: BridgeMessage.Kind.hello, app: "Chrome"))
    }

    func read() {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { drop(); return }
        for m in decoder.feed(Data(buf[0..<n])) {
            if case .toExtension(let msg)? = HostRouting.fromApp(m) { toExtension(msg) }
        }
    }

    func send(_ m: BridgeMessage) {
        guard fd >= 0, let d = try? LineFraming.encode(m) else { return }
        _ = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, d.count) }
    }

    func drop() {
        source?.cancel(); source = nil; fd = -1
        decoder = LineFraming.Decoder()
        toExtension(BridgeMessage(type: BridgeMessage.Kind.status, ok: false, error: "Pixl Memory app isn't running"))
    }
}

let app = AppLink()
signal(SIGPIPE, SIG_IGN)
queue.async { app.connect() }
let retry = DispatchSource.makeTimerSource(queue: queue)
retry.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
retry.setEventHandler { if !app.connected { app.connect() } }
retry.resume()

// MARK: stdin (the extension)

Thread.detachNewThread {
    var decoder = NativeFraming.Decoder()
    while true {
        let data = FileHandle.standardInput.availableData
        if data.isEmpty { exit(0) }  // the extension closed the port
        do {
            for m in try decoder.feed(data) {
                queue.async {
                    switch HostRouting.fromExtension(m, appConnected: app.connected) {
                    case .callService(let method, let path, let body, let id): callService(method: method, path: path, body: body, id: id)
                    case .toApp(let msg): app.send(msg)
                    case .toExtension(let msg): toExtension(msg)
                    }
                }
            }
        } catch {
            log("bad message from Chrome: \(error)")
            exit(1)
        }
    }
}

dispatchMain()
