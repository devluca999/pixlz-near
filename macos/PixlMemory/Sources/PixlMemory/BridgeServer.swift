import AppKit
import Darwin
import PixlBridge
import PixlMemoryKit

/// The app's end of the Chrome bridge: listens on a Unix socket for pixl-native-host (which
/// Chrome starts for the extension) and asks the browser for the page selection or to replace
/// it. Only our own host binary, next to this app's executable, may connect.
@MainActor
final class BridgeServer {
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, decoder: LineFraming.Decoder)] = [:]
    private var pending: [String: (BridgeMessage?) -> Void] = [:]
    private var nextID = 0
    private(set) var browser: String?
    let path = BridgeSocket.path()

    var connected: Bool { !clients.isEmpty }

    /// The host binary that may connect: shipped next to the app's own executable.
    var hostPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "pixl-native-host").path
    }

    // MARK: setup

    func start() {
        installManifests()
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { Debug.log("bridge: socket failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(s, 4) == 0 else { Debug.log("bridge: bind/listen failed errno=\(errno)"); close(s); return }
        chmod(path, 0o600)
        listenFD = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        src.resume()
        listenSource = src
        Debug.log("bridge: listening at \(path)")
    }

    /// Registers pixl-native-host with every installed Chromium browser (SPEC §6.7).
    func installManifests() {
        guard FileManager.default.isExecutableFile(atPath: hostPath) else {
            Debug.log("bridge: no host binary at \(hostPath) (run from the app bundle)")
            return
        }
        var ids = [NativeHostManifest.extensionID(publicKeyBase64: NativeHostManifest.extensionKey)].compactMap { $0 }
        if let extra = ProcessInfo.processInfo.environment["PIXL_EXTENSION_IDS"] {
            ids += extra.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { $0.count == 32 }
        }
        do {
            let files = try NativeHostManifest.install(hostPath: hostPath, extensionIDs: ids, home: FileManager.default.homeDirectoryForCurrentUser)
            Debug.log("bridge: native host registered for \(files.count) browser(s), extension \(ids.joined(separator: ","))")
        } catch {
            Debug.log("bridge: couldn't register the native host: \(error)")
        }
    }

    private func accept() {
        let c = Darwin.accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        guard let peer = peerPath(c), peer == hostPath || (Debug.enabled && peer.hasSuffix("/pixl-native-host")) else {
            Debug.log("bridge: refused a connection from \(peerPath(c) ?? "unknown")")
            close(c)
            return
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(c) } }
        src.setCancelHandler { close(c) }
        src.resume()
        clients[c] = (src, LineFraming.Decoder())
        Debug.log("bridge: browser host connected")
    }

    /// The executable of the process on the other end of the socket.
    private func peerPath(_ fd: Int32) -> String? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    private func read(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0, var c = clients[fd] else { drop(fd); return }
        let messages = c.decoder.feed(Data(buf[0..<n]))
        clients[fd] = c
        for m in messages { handle(m) }
    }

    private func drop(_ fd: Int32) {
        clients[fd]?.source.cancel()
        clients[fd] = nil
        if clients.isEmpty { browser = nil }
        Debug.log("bridge: browser host disconnected")
    }

    private func handle(_ m: BridgeMessage) {
        if m.type == BridgeMessage.Kind.hello { browser = m.app ?? "Chrome"; return }
        if let id = m.id, let done = pending.removeValue(forKey: id) { done(m) }
    }

    // MARK: requests

    func request(_ m: BridgeMessage, timeout: TimeInterval, completion: @escaping @MainActor (BridgeMessage?) -> Void) {
        guard let (fd, _) = clients.first else { completion(nil); return }
        nextID += 1
        var msg = m
        let id = "app-\(nextID)"
        msg.id = id
        pending[id] = completion
        guard let data = try? LineFraming.encode(msg) else { pending[id] = nil; completion(nil); return }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let done = self?.pending.removeValue(forKey: id) else { return }
                Debug.log("bridge: \(m.type) timed out")
                done(nil)
            }
        }
    }

    /// The selection in the browser's active tab (works where Accessibility can't read it:
    /// rich editors, Google Docs).
    func selection(timeout: TimeInterval = 0.4, completion: @escaping @MainActor (BridgeMessage?) -> Void) {
        request(BridgeMessage(type: BridgeMessage.Kind.getSelection), timeout: timeout) { reply in
            completion(reply?.ok == true && !(reply?.text ?? "").isEmpty ? reply : nil)
        }
    }

    /// "Save this": the extension saves the active tab's selection (or the page) to memory with a
    /// backlink, and replies with what it saved. `note` is the user's own words, kept in front.
    func savePage(note: String?, completion: @escaping @MainActor (BridgeMessage?) -> Void) {
        request(BridgeMessage(type: BridgeMessage.Kind.savePage, text: note), timeout: 5, completion: completion)
    }

    /// The active tab's readable text (paragraphs, headings, list items), for finding a passage.
    func pageText(completion: @escaping @MainActor (_ url: URL?, _ title: String?, _ blocks: [String]) -> Void) {
        request(BridgeMessage(type: BridgeMessage.Kind.pageText), timeout: 3) { reply in
            guard let r = reply, r.ok == true else { completion(nil, nil, []); return }
            completion(r.url.flatMap(URL.init(string:)), r.title, (r.text ?? "").components(separatedBy: "\n\n").filter { !$0.isEmpty })
        }
    }

    /// Replaces `original` with `text` in the page, the way typing would (input events fire).
    func replace(original: String, with text: String, completion: @escaping @MainActor (Bool) -> Void) {
        request(BridgeMessage(type: BridgeMessage.Kind.replace, text: text, original: original), timeout: 2) { reply in
            completion(reply?.ok == true)
        }
    }
}
