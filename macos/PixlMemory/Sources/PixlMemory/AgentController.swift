import AppKit
import Darwin
import PixlAgents
import PixlMemoryKit

/// Agent mode (SPEC §16): Claude Code sessions on this Mac, reported by its hooks through
/// pixl-agent-hook over a private Unix socket. Lists them, answers permission requests with
/// Allow / Deny when "Answer from Pixlz" is on, and lets the Pixl call for you (alerts).
@MainActor
final class AgentController {
    unowned let app: AppController
    private(set) var hub = AgentHub()
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]
    private var held: [String: Int32] = [:]       // request id → the hook waiting for its answer
    private var heldStops: [String: (fd: Int32, since: Date)] = [:]   // session id → its Stop hook, waiting for a reply
    static let replyWindow: TimeInterval = 300
    private var timer: Timer?
    private var lastAlert = Date.distantPast
    private var snoozedUntil: Date?
    let path = AgentSocket.path()

    private let answerKey = "PixlMemory.agentAnswer", alertsKey = "PixlMemory.agentAlerts", replyKey = "PixlMemory.agentReply"
    /// Keep a finished session open (up to 5 min) so a reply from Pixlz continues it. While
    /// held, the terminal shows it as busy; Esc there takes it back.
    var replyHere: Bool {
        get { UserDefaults.standard.bool(forKey: replyKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: replyKey)
            Debug.log("agents: reply here \(newValue)")
            if !newValue { for id in Array(heldStops.keys) { release(id) } }
        }
    }
    /// Hold permission requests for an answer here (up to 55 s). Off: Pixlz only watches, and
    /// the terminal asks as usual, without waiting on Pixlz.
    var answerHere: Bool {
        get { UserDefaults.standard.bool(forKey: answerKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: answerKey)
            Debug.log("agents: answer here \(newValue)")
            if !newValue {   // let every waiting hook go now: the terminal asks
                for (id, fd) in held { finish(fd, reply: nil); hub.unmarkHeld(id) }
                held.removeAll()
                changed()
            }
        }
    }
    /// While a session waits on you, the Pixl keeps calling (every 20 s) in its own voice.
    var alertsOn: Bool {
        get { UserDefaults.standard.bool(forKey: alertsKey) }
        set { UserDefaults.standard.set(newValue, forKey: alertsKey); Debug.log("agents: alerts \(newValue)") }
    }

    init(app: AppController) { self.app = app }

    var hookPath: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appending(path: "pixl-agent-hook").path
    }
    var settingsURL: URL { HookSettings.url(home: FileManager.default.homeDirectoryForCurrentUser) }
    var hooksInstalled: Bool { (try? HookSettings.read(settingsURL)).map { HookSettings.installed(in: $0, hookPath: hookPath) } ?? false }

    /// The bubble's sub-label: nil hides the Agents bubble (nothing connected, nothing running).
    var bubbleSub: String? {
        if !hub.requests.isEmpty { return "\(hub.requests.count) waiting" }
        if !hub.sessions.isEmpty { return "\(hub.sessions.count)" }
        return hooksInstalled ? "none running" : nil
    }

    // MARK: socket

    func start() {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if Self.someoneListens(at: path) {
            Debug.log("agents: another Pixl Memory already listens at \(path); not taking it over")
            return
        }
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { Debug.log("agents: socket failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(s, 16) == 0 else { Debug.log("agents: bind/listen failed errno=\(errno)"); close(s); return }
        chmod(path, 0o600)
        listenFD = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        src.resume()
        listenSource = src
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        timer?.tolerance = 0.3
        Debug.log("agents: listening at \(path) (hooks \(hooksInstalled ? "installed" : "not installed"))")
    }

    /// Is another live process listening on that socket?
    static func someoneListens(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { buf in path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) } }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    private func accept() {
        let c = Darwin.accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        let peer = peerPath(c)
        guard let peer, peer == hookPath || (Debug.enabled && peer.hasSuffix("/pixl-agent-hook")) else {
            Debug.log("agents: refused a connection from \(peer ?? "unknown")")
            close(c)
            return
        }
        var nosigpipe: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(c) } }
        src.resume()
        clients[c] = (src, Data())
    }

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
        guard n > 0, var c = clients[fd] else {
            // The hook went away (answered in the terminal, or Claude Code gave up on it).
            if let id = held.first(where: { $0.value == fd })?.key { held[id] = nil; hub.resolve(id); changed() }
            if let sid = heldStops.first(where: { $0.value.fd == fd })?.key {
                heldStops[sid] = nil   // Esc in the terminal, or Claude Code gave up on the hook
                hub.setReplyOpen(sid, false)
                changed()
            }
            finish(fd, reply: nil)
            return
        }
        c.buffer.append(contentsOf: buf[0..<n])
        clients[fd] = c
        guard let nl = c.buffer.firstIndex(of: 0x0A) else {
            if c.buffer.count > 1 << 20 { finish(fd, reply: nil) }
            return
        }
        let line = c.buffer[..<nl]
        clients[fd]?.buffer = Data()
        guard let event = HookEvent(json: Data(line)) else { finish(fd, reply: nil); return }
        let had = hub.requests.count
        // It moved on without us (a prompt typed in the terminal, a tool call): let go. A
        // Notification ("waiting for your input", ~60 s after it finished) isn't moving on.
        if heldStops[event.sessionID] != nil, event.name != "Notification" { release(event.sessionID) }
        let request = hub.receive(event, at: Date())
        if event.name == "Stop", let waiting = queued.removeValue(forKey: event.sessionID) {
            releaseSettled()
            Debug.log("agents: \(hub.sessions[event.sessionID]?.project ?? "?") finished; queued reply delivered")
            hub.setReplyOpen(event.sessionID, false)
            finish(fd, reply: AgentHub.stopReply(waiting))
            app.notify(.agents("Delivered to \(hub.sessions[event.sessionID]?.project ?? "Claude"): \(waiting.prefix(40))"))
            onDelivered?(event.sessionID)
            changed()
            return
        }
        if event.name == "Stop", replyHere {
            releaseSettled()
            heldStops[event.sessionID] = (fd, Date())
            hub.setReplyOpen(event.sessionID, true)
            Debug.log("agents: \(hub.sessions[event.sessionID]?.project ?? "?") finished; open for a reply")
            changed()
            return
        }
        if let request, answerHere {
            held[request] = fd   // keep the hook waiting for Allow / Deny
            hub.markHeld(request)
            Debug.log("agents: \(event.name) from \(hub.sessions[event.sessionID]?.project ?? "?") held as \(request)")
        } else {
            finish(fd, reply: nil)   // watching only: it stays listed while the terminal asks
        }
        releaseSettled()
        if hub.requests.count > had { newRequest() }
        changed()
    }

    private func finish(_ fd: Int32, reply: Data?) {
        if let reply {
            _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, reply.count) }
        }
        if let c = clients.removeValue(forKey: fd) {
            c.source.cancel()
            close(fd)
        }
    }

    // MARK: answers

    func decide(_ requestID: String, _ decision: AgentDecision) {
        guard let fd = held.removeValue(forKey: requestID) else {
            Debug.log("agents: \(requestID) isn't held here (answer it in the terminal)")
            return
        }
        Debug.log("agents: \(requestID) \(decision.rawValue)")
        hub.resolve(requestID)
        finish(fd, reply: AgentHub.reply(decision))
        changed()
    }

    enum ReplyResult { case sent, queued, failed }
    /// Replies waiting for their session to finish (it was working, or its window had closed).
    private(set) var queued: [String: String] = [:]
    /// A queued reply just went to its session (session id): tell whoever sent it.
    var onDelivered: (@MainActor (String) -> Void)?

    /// Your next message for a session: now, if it's finished and held open; otherwise it waits
    /// here and goes the moment that session next finishes (its Stop hook answers it at once,
    /// whether or not Reply from Pixlz is on). A newer reply replaces a waiting one.
    @discardableResult
    func reply(_ sessionID: String, _ text: String) -> ReplyResult {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, hub.sessions[sessionID] != nil else { return .failed }
        let project = hub.sessions[sessionID]?.project ?? "?"
        guard let h = heldStops.removeValue(forKey: sessionID) else {
            queued[sessionID] = t
            Debug.log("agents: reply to \(project) queued until it finishes (\(t.count) chars)")
            changed()
            return .queued
        }
        Debug.log("agents: reply to \(project) (\(t.count) chars)")
        hub.setReplyOpen(sessionID, false)
        finish(h.fd, reply: AgentHub.stopReply(t))
        changed()
        return .sent
    }

    /// Let a held session finish normally.
    private func release(_ sessionID: String) {
        guard let h = heldStops.removeValue(forKey: sessionID) else { return }
        hub.setReplyOpen(sessionID, false)
        finish(h.fd, reply: nil)
    }

    /// The session's title and its last turns, from its transcript.
    func chat(_ sessionID: String, limit: Int = 30) -> (title: String?, lines: [ChatLine]) {
        guard let p = hub.sessions[sessionID]?.transcriptPath else { return (nil, []) }
        return Transcript.read(URL(fileURLWithPath: p), limit: limit)
    }

    /// Can Allow / Deny here answer it (Pixlz holds its hook)?
    func canAnswer(_ requestID: String) -> Bool { held[requestID] != nil }

    /// Held hooks whose request the hub settled (answered in the terminal, a new tool call):
    /// let them go without an answer.
    private func releaseSettled() {
        let live = Set(hub.requests.map(\.id))
        for (id, fd) in held where !live.contains(id) {
            held[id] = nil
            finish(fd, reply: nil)
        }
    }

    private func tick() {
        let gone = hub.expire(at: Date())
        for id in gone {
            if let fd = held.removeValue(forKey: id) {
                finish(fd, reply: nil)
                app.notify(.agentsError("A request waited too long here. Answer it in the terminal."))
            }
            Debug.log("agents: \(id) timed out; the terminal asks")
        }
        if !gone.isEmpty { changed() }
        let stale = heldStops.filter { Date().timeIntervalSince($0.value.since) >= Self.replyWindow }.map(\.key)
        for id in stale { release(id); Debug.log("agents: reply window closed") }
        if !stale.isEmpty { changed() }
        alertIfDue()
    }

    // MARK: the Pixl's side

    private func newRequest() {
        guard answerHere || alertsOn else { return }
        lastAlert = .distantPast
        alertIfDue()
    }

    /// "ribbit! ribbit!" + "pixlz needs you: Run swift test", every 20 s while anything waits, unless snoozed.
    private func alertIfDue() {
        guard alertsOn, let oldest = hub.requests.first, Date().timeIntervalSince(lastAlert) >= 20 else { return }
        if let s = snoozedUntil, s > Date() { return }
        lastAlert = Date()
        Debug.log("agents: alert for \(oldest.project)")
        // Its own call ("wan! wan!") leads a plain-English notice naming the session.
        app.notify(.agents("\(oldest.project) needs you: \(oldest.summary)"), voice: .alert, urgent: true)
    }

    func snooze(minutes: Double = 10) {
        snoozedUntil = Date().addingTimeInterval(minutes * 60)
        Debug.log("agents: alerts snoozed \(Int(minutes)) min")
    }

    /// The menu or a request is open: show what changed.
    var onChange: (@MainActor () -> Void)?
    /// More rows for the Agents list from elsewhere in the app (other devices), and their handler.
    var extraRows: (@MainActor () -> [ListMenuView.Row])?
    var onExtraRow: (@MainActor (String) -> Void)?
    /// Anything else showing the sessions (another screen): told on every change.
    var onHubChange: (@MainActor () -> Void)?
    private func changed() { onChange?(); onHubChange?() }

    // MARK: hooks in Claude Code's settings

    func installHooks() -> String? {
        guard FileManager.default.isExecutableFile(atPath: hookPath) else {
            return "Run Pixl Memory from its app (the hook helper isn't next to it)."
        }
        do {
            let s = try HookSettings.read(settingsURL)
            try HookSettings.write(HookSettings.adding(to: s, hookPath: hookPath), to: settingsURL)
            Debug.log("agents: hooks installed in \(settingsURL.path)")
            return nil
        } catch HookSettings.Failure.unreadable {
            return "~/.claude/settings.json isn't valid JSON, so Pixlz left it alone."
        } catch {
            return "Couldn't write ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    func removeHooks() -> String? {
        do {
            let s = try HookSettings.read(settingsURL)
            try HookSettings.write(HookSettings.removing(from: s), to: settingsURL)
            for (id, fd) in held { finish(fd, reply: nil); hub.resolve(id) }
            held.removeAll()
            for id in Array(heldStops.keys) { release(id) }
            Debug.log("agents: hooks removed")
            return nil
        } catch {
            return "Couldn't change ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    func stop() {
        for (_, fd) in held { finish(fd, reply: nil) }
        for (_, h) in heldStops { finish(h.fd, reply: nil) }
        unlink(path)
    }
}
