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
    private var heldStop: [String: Int32] = [:]   // session id → its Stop hook, held for your reply
    /// Sessions Pixlz is running with `claude -p --resume` right now (no terminal behind them).
    private(set) var resuming: [String: Process] = [:]
    /// What a resumed run has said so far (its reply streams in before the transcript catches up).
    private(set) var resumeLog: [String: [String]] = [:]
    /// The chat panels and anything else showing a session's messages: told when they change.
    var onChat: (@MainActor (String) -> Void)?
    private var timer: Timer?
    private var lastAlert = Date.distantPast
    private var snoozedUntil: Date?
    let path = AgentSocket.path()

    private let answerKey = "PixlMemory.agentAnswer", alertsKey = "PixlMemory.agentAlerts", windowKey = "PixlMemory.agentReplyWindow"
    /// How long a finished turn waits for your reply ("done. Anything else?"), 15–300 s.
    var replyWindow: TimeInterval {
        get { let v = UserDefaults.standard.double(forKey: windowKey); return v == 0 ? 60 : min(max(v, 15), Double(HookSettings.maxReplyWindow)) }
        set { UserDefaults.standard.set(min(max(newValue, 15), Double(HookSettings.maxReplyWindow)), forKey: windowKey) }
    }
    /// Hold permission requests for an answer here (up to 55 s). Off: Pixlz only watches, and
    /// the terminal asks as usual, without waiting on Pixlz.
    var answerHere: Bool {
        get { UserDefaults.standard.bool(forKey: answerKey) }
        set { UserDefaults.standard.set(newValue, forKey: answerKey); Debug.log("agents: answer here \(newValue)") }
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
    var hooksInstalled: Bool { (try? HookSettings.read(settingsURL)).map(HookSettings.installed) ?? false }
    /// Connected by an older Pixlz: Stop can't wait for your reply until the hooks are updated.
    var hooksOutdated: Bool { (try? HookSettings.read(settingsURL)).map(HookSettings.outdated) ?? false }

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
            if let sid = heldStop.first(where: { $0.value == fd })?.key { heldStop[sid] = nil; hub.releaseStop(sid); doneAsked = nil; onChat?(sid) }
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
        let sid = event.sessionID
        let request = hub.receive(event, at: Date())
        if let request {
            // a resumed run has no terminal to ask in: Pixlz always holds its requests
            if answerHere || resuming[sid] != nil {
                held[request] = fd   // keep the hook waiting for Allow / Deny
                hub.markHeld(request)
                Debug.log("agents: \(event.name) from \(hub.sessions[sid]?.project ?? "?") held as \(request)")
            } else {
                finish(fd, reply: nil)   // watching only: it stays listed while the terminal asks
            }
        } else if event.name == "PostToolUse" {
            // its next step: your message as context, or nothing, at once
            let reply = hub.answerPostToolUse(sid)
            if reply != nil { Debug.log("agents: message delivered to \(hub.sessions[sid]?.project ?? "?") at its next step") }
            finish(fd, reply: reply)
            if reply != nil { onChat?(sid) }
        } else if event.name == "Stop" {
            answerStop(event, fd: fd)
        } else {
            finish(fd, reply: nil)
        }
        if event.name == "SessionEnd" || event.name == "UserPromptSubmit" { letStopGo(sid) }
        releaseSettled()
        if hub.requests.count > had { newRequest() }
        changed()
        onChat?(sid)
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
            if let fd = held.removeValue(forKey: id) { finish(fd, reply: nil) }
            Debug.log("agents: \(id) timed out; the terminal asks")
        }
        if !gone.isEmpty { changed() }
        for sid in hub.expireStops(at: Date(), window: replyWindow) {
            Debug.log("agents: no reply in \(Int(replyWindow)) s; \(hub.sessions[sid]?.project ?? "?") stops")
            if let fd = heldStop.removeValue(forKey: sid) { finish(fd, reply: nil) }
            if doneAsked == sid { doneAsked = nil; onDoneAsk?(nil) }
            onChat?(sid)
        }
        alertIfDue()
    }

    // MARK: two-way: your messages to a session

    /// The session that last finished a turn and is waiting for a reply (the pet asks).
    private(set) var doneAsked: String?
    /// Show (a session id) or clear (nil) the pet's "<project>: done. Anything else?".
    var onDoneAsk: (@MainActor (String?) -> Void)?

    private func answerStop(_ e: HookEvent, fd: Int32) {
        let sid = e.sessionID
        // a run Pixlz resumed: never wait on it (it would sit out the reply window); carry on
        // only with something you typed for it
        if resuming[sid] != nil {
            if let text = hub.take(for: sid, note: "when it finished its turn") { finish(fd, reply: AgentHub.stopReply(text)) }
            else { finish(fd, reply: nil) }
            return
        }
        switch hub.answerStop(e, at: Date()) {
        case .block(let reply):
            Debug.log("agents: \(hub.sessions[sid]?.project ?? "?") finished a turn; your message sent")
            finish(fd, reply: reply)
        case .release:
            finish(fd, reply: nil)
        case .hold:
            if let old = heldStop[sid] { finish(old, reply: nil) }
            heldStop[sid] = fd
            doneAsked = sid
            Debug.log("agents: \(hub.sessions[sid]?.project ?? "?") finished a turn; holding \(Int(replyWindow)) s for a reply")
            onDoneAsk?(sid)
        }
    }

    /// Dismissed (or it moved on): let its held stop go now.
    func letStopGo(_ sid: String) {
        hub.releaseStop(sid)
        if let fd = heldStop.removeValue(forKey: sid) { finish(fd, reply: nil) }
        if doneAsked == sid { doneAsked = nil; onDoneAsk?(nil) }
        onChat?(sid)
    }

    /// How a message to this session would go right now.
    func route(_ sid: String) -> DeliveryRoute { hub.route(for: sid, at: Date()) }
    func mayBeOpenElsewhere(_ sid: String) -> Bool { hub.mayBeOpenElsewhere(sid, at: Date()) }

    /// Your message (only ever from the chat panel's field): into the outbox, then out the first
    /// way that's open. Returns its id.
    @discardableResult
    func send(_ message: TypedMessage, to sid: String) -> String {
        let id = hub.queue(message, for: sid, at: Date())
        switch hub.route(for: sid, at: Date()) {
        case .now:
            if let reply = hub.replyToHeldStop(sid), let fd = heldStop.removeValue(forKey: sid) {
                Debug.log("agents: reply sent to \(hub.sessions[sid]?.project ?? "?") (its stop was held)")
                finish(fd, reply: reply)
                if doneAsked == sid { doneAsked = nil; onDoneAsk?(nil) }
            }
        case .nextStep:
            Debug.log("agents: message queued for \(hub.sessions[sid]?.project ?? "?") (next step)")
        case .resume:
            resume(sid)
        }
        onChat?(sid)
        changed()
        return id
    }

    // MARK: resuming a session (`claude -p --resume`)

    private var resumeBuffer: [String: Data] = [:]
    private var claudePath: String??          // looked up once, in your login shell
    private var loginPATH: String?

    /// `claude`, found through your login shell's PATH (an app's own PATH is minimal).
    func findClaude() -> String? {
        if let c = claudePath { return c }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf '%s\\n' \"$PATH\"; command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { claudePath = .some(nil); return nil }
        p.waitUntilExit()
        let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
        loginPATH = lines.first
        let found = lines.dropFirst().last.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        claudePath = .some(found)
        Debug.log("agents: claude \(found != nil ? "found" : "not found") in the login shell")
        return found
    }

    /// The next step of the reply-window setting.
    func nextReplyWindow(_ steps: [Double]) {
        replyWindow = steps.first { $0 > replyWindow } ?? steps[0]
        Debug.log("agents: reply window \(Int(replyWindow)) s")
    }

    /// The lookup's result so far: nil = not looked up yet; .some(nil) = not installed.
    var findClaudeCached: String?? { claudePath }

    /// What to run to get `claude` when it's missing.
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// Runs `claude -p --resume <id> --output-format stream-json --verbose "<message>"` in the
    /// session's folder, streaming its reply into the chat panel.
    private func resume(_ sid: String) {
        guard resuming[sid] == nil else { return }   // the run in progress takes it at its next step
        guard let claude = findClaude() else {
            hub.fail(sid, note: "Claude Code isn't installed (or not on your PATH). Install it: \(Self.installCommand)")
            return
        }
        guard let text = hub.take(for: sid, note: "resumed the session") else { return }
        let cwd = hub.sessions[sid]?.cwd ?? ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = AgentHub.resumeArguments(sessionID: sid, message: text)
        if !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        if let path = loginPATH { env["PATH"] = path }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        resumeLog[sid] = []
        resumeBuffer[sid] = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var buffer = self.resumeBuffer[sid] ?? Data()
                    buffer.append(chunk)
                    defer { self.resumeBuffer[sid] = buffer }
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<nl]
                        buffer = Data(buffer[buffer.index(after: nl)...])
                        if let said = AgentHub.streamText(Data(line)) { self.resumeLog[sid, default: []].append(said); self.onChat?(sid) }
                    }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    out.fileHandleForReading.readabilityHandler = nil
                    self.resuming[sid] = nil
                    if status != 0 {
                        let why = errText.split(whereSeparator: \.isNewline).first.map(String.init) ?? "exit \(status)"
                        self.resumeLog[sid, default: []].append("⚠︎ The resumed run stopped: \(why)")
                    }
                    Debug.log("agents: resumed run ended (\(status))")
                    // anything you typed while it ran and it didn't take: resume again with it
                    if self.hub.hasQueued(sid), self.hub.route(for: sid, at: Date()) == .resume { self.resume(sid) }
                    self.onChat?(sid)
                    self.changed()
                }
            }
        }
        do {
            try p.run()
            resuming[sid] = p
            Debug.log("agents: resuming \(hub.sessions[sid]?.project ?? "?") with claude -p")
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            resumeLog[sid, default: []].append("⚠︎ Couldn't start claude: \(error.localizedDescription)")
        }
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
        app.notify(.agents("\(oldest.project) needs you: \(oldest.summary)"), voice: .alert)
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
            Debug.log("agents: hooks removed")
            return nil
        } catch {
            return "Couldn't change ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    func stop() {
        for (_, fd) in held { finish(fd, reply: nil) }
        unlink(path)
    }
}
