import AppKit
@_spi(DeviceInput) import PixlAgents
import PixlMemoryKit
import PixlTravel
import PixlzCore

/// Trips between devices (SPEC §10, D9), and between this Mac's own displays.
/// Nearby devices come from Bonjour (PixlTravel); the trip itself is PixlzCore's protocol,
/// which never loses or duplicates the Pixl.
@MainActor
final class TravelController {
    unowned let app: AppController
    var runner: TripRunner?
    private(set) var peers: [DeviceRef] = []
    /// macOS hasn't allowed "find devices on your local network" yet (System Settings ▸
    /// Privacy & Security ▸ Local Network): Pixl can be found but can't see other devices.
    private(set) var localNetworkBlocked = false

    func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
        app.notify(.localNetworkOff)
    }
    let trustedKey = "PixlMemory.trustedDevices"

    init(app: AppController) { self.app = app }

    // MARK: Mosaico feed (opt-in per device: MosaicoFeed.defaultsKey)

    /// The latest Ask answers, newest first, for a Mosaico's Answers page.
    private var recentAnswers: [(question: String, answer: String)] = []
    private var feedTimer: Timer?
    private var pingTimer: Timer?

    func noteAnswer(question: String, answer: String) {
        recentAnswers.insert((question, answer), at: 0)
        recentAnswers = Array(recentAnswers.prefix(MosaicoFeed.maxAnswers))
        pushFeed()
    }

    /// Sends the answers and the newest highlights to every reachable device that opted in.
    func pushFeed() {
        let wanted = MosaicoFeed.devices()
        let targets = peers.filter { wanted.contains($0.deviceId) }
        guard !targets.isEmpty, let r = runner else { return }
        let answers = recentAnswers, me = self.me
        Task { @MainActor [weak self] in
            guard let self else { return }
            let highlights = await self.app.client.highlights(limit: MosaicoFeed.maxHighlights)
            let body = MosaicoFeed.body(answers: answers,
                                        highlights: highlights.map { ($0.title ?? $0.url ?? "Highlight", $0.text) }, from: me)
            for p in targets { r.transport.sendFrame(body, to: p) }
            Debug.log("travel: feed to \(targets.map(\.deviceName)): \(answers.count) answers, \(highlights.count) highlights")
        }
    }

    // MARK: Agent mode on the Mosaico (SPEC §16.3): the session list out, Deny back

    private var agentsPushPending = false

    /// Sessions changed: send the list to the feed devices, at most about once a second.
    func scheduleAgentsPush() {
        guard !agentsPushPending else { return }
        agentsPushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.agentsPushPending = false
            self?.pushAgents()
        }
    }

    func pushAgents() {
        let wanted = MosaicoFeed.devices()
        let targets = peers.filter { wanted.contains($0.deviceId) }
        guard !targets.isEmpty, let r = runner else { return }
        let agents = app.agents
        let rows = agents.hub.list.map { s -> MosaicoFeed.AgentRow in
            let req = agents.hub.requests.first { $0.sessionID == s.id }
            return MosaicoFeed.AgentRow(id: s.id, project: s.project, doing: s.doing, request: req?.id,
                                        summary: req?.summary ?? "", detail: req?.detail ?? "",
                                        answerable: req.map { agents.canAnswer($0.id) } ?? false, replyOpen: s.replyOpen,
                                        queued: agents.queued[s.id])
        }
        let body = MosaicoFeed.agentsBody(rows, alerts: agents.alertsOn, from: me)
        for p in targets { r.transport.sendFrame(body, to: p) }
        Debug.log("travel: agents to \(targets.map(\.deviceName)): \(rows.count) sessions \(rows.map { "\($0.project)·\($0.id.prefix(8))" }), \(agents.hub.requests.count) waiting")
    }

    /// The last chat frame each device got, and when: live updates skip repeats and come at
    /// most every 1.5 s (Bluetooth is slow), the latest one sent once the gap is over.
    private var lastChat: [String: (body: Data, at: Date)] = [:]
    private var chatLater: Set<String> = []

    private func sendChat(_ sid: String, to peer: DeviceRef, live: Bool = false) {
        let (title, lines) = app.agents.chat(sid, limit: 12)
        let roles: [ChatLine.Role: String] = [.you: "y", .claude: "c", .tool: "t"]
        let out = MosaicoFeed.chatBody(id: sid, title: title, lines: lines.map { (roles[$0.role] ?? "t", $0.text) }, from: me)
        let last = lastChat[peer.deviceId]
        if live, last?.body == out { return }
        if live, let last, Date().timeIntervalSince(last.at) < 1.5 {
            guard chatLater.insert(peer.deviceId).inserted else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.chatLater.remove(peer.deviceId)
                self?.sendChat(sid, to: peer, live: true)
            }
            return
        }
        lastChat[peer.deviceId] = (out, Date())
        runner?.transport.sendFrame(out, to: peer)
        Debug.log("travel: chat for \(peer.deviceName)\(live ? " (live)" : ""): \(lines.count) lines, \(out.count) bytes")
    }

    /// A frame from a device that isn't a trip message: a Mosaico's answer to a request.
    /// Deny only: Allow from the Mosaico waits for pairing (D19), since the link isn't secured.
    func frame(_ body: Data, from peer: DeviceRef) {
        if pairingController.frame(body, from: peer) { return }
        if let sid = MosaicoFeed.chatRequest(body) {
            guard MosaicoFeed.devices().contains(peer.deviceId) else { return }
            lastChat[peer.deviceId] = nil
            sendChat(sid, to: peer)
            // Live: new turns follow while it's likely still open (it asks again on each open).
            app.agents.watchTranscript(sid, as: "mosaico.\(peer.deviceId)", for: 600) { [weak self] in
                self?.sendChat(sid, to: peer, live: true)
            }
            return
        }
        if MosaicoDictation.isDictation(body) {
            guard MosaicoFeed.devices().contains(peer.deviceId), let clip = dictation.receive(body) else { return }
            // How loud it is (silence or clipping means the microphone, not the recognizer), and
            // the last clip kept as a WAV next to the log for listening.
            let peak = clip.samples.map { abs(Int($0)) }.max() ?? 0
            let rms = sqrt(clip.samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, clip.samples.count)))
            Debug.log("travel: dictation from \(peer.deviceName): \(clip.samples.count / 16) ms, peak \(peak), rms \(Int(rms))")
            if Debug.enabled { Dictation.saveWAV(clip.samples, to: Debug.url.deletingLastPathComponent().appending(path: "last-dictation.wav")) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var out: Data
                do {
                    let text = try await Dictation.transcribe(clip.samples)
                    let sent = MosaicoFeed.ascii(text, 400)
                    self.pairingController.dictated.insert(sent)   // the only free text a Mosaico may send back
                    out = MosaicoDictation.transcriptBody(id: clip.id, session: clip.session, text: sent)
                    Debug.log("travel: heard \(sent.count) chars")
                } catch Dictation.Failure.notAllowed {
                    out = MosaicoDictation.transcriptBody(id: clip.id, session: clip.session, text: nil,
                                                          error: "Allow Speech Recognition for Pixl Memory on your Mac")
                    self.app.notify(.agentsError("Dictation needs Speech Recognition: System Settings → Privacy & Security."))
                } catch {
                    Debug.log("travel: dictation not understood: \(error)")
                    out = MosaicoDictation.transcriptBody(id: clip.id, session: clip.session, text: nil, error: "Didn't catch that. Try again?")
                }
                self.runner?.transport.sendFrame(out, to: peer)
            }
            return
        }
        if let r = pairingController.verifiedReply(body, from: peer) {
            let via = MosaicoFeed.quickReplies.contains(r.text) ? "quick reply on the Mosaico" : "dictated on the Mosaico"
            // your words, signed by the paired device: in through the device door (DeviceInput).
            // The Mosaico can't show "may still be open in a terminal", so from here a session
            // that might be open is never resumed: the message waits for its next step instead.
            let state: String
            if let m = TypedMessage.fromPairedDevice(r.text, via: via), app.agents.hub.sessions[r.id] != nil {
                let id = app.agents.send(m, to: r.id, mayResume: !app.agents.mayBeOpenElsewhere(r.id))
                let status = app.agents.hub.outbox[r.id]?.first { $0.id == id }?.status
                state = status == .delivered ? "sent" : status == .failed ? "failed" : "queued"
                if state == "queued" { queuedFrom[r.id] = peer }   // tell it when it's delivered
            } else {
                state = "failed"
            }
            Debug.log("travel: \(peer.deviceName) replied \"\(r.text.prefix(40))\" (\(state))")
            // Tell the Mosaico what became of it, so its banner is true.
            if let out = try? JSONSerialization.data(withJSONObject: ["replyResult": ["id": r.id, "state": state]]) {
                runner?.transport.sendFrame(out, to: peer)
            }
            return
        }
        guard let d = MosaicoFeed.agentDecision(body) else { return }
        guard MosaicoFeed.devices().contains(peer.deviceId) else {
            Debug.log("travel: agent decision from \(peer.deviceName) ignored (not a feed device)")
            return
        }
        // Signed by a paired device (D20): Allow or Deny, over what it showed.
        if let v = pairingController.verified(body, from: peer), v.behavior == "allow" || v.behavior == "deny" {
            Debug.log("travel: \(peer.deviceName) \(v.behavior == "allow" ? "allowed" : "denied") \(v.id) (signed)")
            app.agents.decide(v.id, v.behavior == "allow" ? .allow : .deny)
            return
        }
        guard d.behavior == "deny" else {
            Debug.log("travel: \(d.behavior) from \(peer.deviceName) refused: Allow needs a paired device and a valid signature")
            return
        }
        Debug.log("travel: \(peer.deviceName) denied \(d.id)")
        app.agents.decide(d.id, .deny)
    }

    lazy var pairingController = MosaicoPairingController(travel: self)
    private var dictation = MosaicoDictation()
    /// Which Mosaico sent each queued reply (session id), to say "delivered" back to it.
    private var queuedFrom: [String: DeviceRef] = [:]

    private var bluetooth: BLEBridge?

    var me: DeviceRef { ThisDevice.ref() }

    /// Where this device keeps its Pixl's state (a second copy of the app gets its own).
    var storeDir: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/PixlMemory")
        if let id = ProcessInfo.processInfo.environment["PIXL_DEVICE_ID"] { return base.appending(path: "devices/\(id)") }
        return base.appending(path: "pet")
    }

    func start() {
        let trusted = Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? [])
        let r = TripRunner(me: me, store: FilePetStore(directory: storeDir), knownSpecies: Set(PixlSkins.all.map(\.id)), trusted: trusted)
        r.onLog = { Debug.log($0) }
        r.onProblem = { [weak self] why in self?.app.notify(.travelProblem(why)) }
        r.isPaired = { MosaicoPairingController.load($0) != nil }
        if r.loadProblem != nil {
            // the saved Pixl couldn't be read: it was kept aside; never adopt a new one over it
            app.notify(.petUnreadable)
        } else if ProcessInfo.processInfo.environment["PIXL_DEVICE_ID"] == nil {
            // the first device adopts the Pixl; a second copy (PIXL_DEVICE_ID) starts empty and
            // waits for it to visit (one Pixl, one owner at a time: SPEC D9)
            r.adoptIfNeeded(species: PixlSkins.currentID, name: app.settings.name)
        }
        r.onRecord = { [weak self] rec in self?.recordChanged(rec) }
        r.onPeers = { [weak self] list in
            guard let self else { return }
            let fresh = list.contains { p in !self.peers.contains(p) }
            self.peers = list
            Debug.log("travel: nearby \(list.map(\.deviceName))")
            // after the trip runner's own hello (status), so the Mosaico knows who we are
            if fresh { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.pushFeed(); self?.pushAgents() } }
        }
        feedTimer?.invalidate()
        feedTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushFeed() }
        }
        // Heartbeat to the feed devices (Mosaicos): they answer "pong", so a dead link shows.
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.runner else { return }
                let wanted = MosaicoFeed.devices()
                for p in self.peers where wanted.contains(p.deviceId) { r.transport.sendFrame(Data(#"{"ping":1}"#.utf8), to: p) }
            }
        }
        r.transport.onFrame = { [weak self] body, peer in self?.frame(body, from: peer) }
        app.agents.onHubChange = { [weak self] in self?.scheduleAgentsPush() }
        app.agents.onDelivered = { [weak self] sid in
            guard let self, let peer = self.queuedFrom.removeValue(forKey: sid),
                  let out = try? JSONSerialization.data(withJSONObject: ["replyResult": ["id": sid, "state": "delivered"]]) else { return }
            self.runner?.transport.sendFrame(out, to: peer)
        }
        app.agents.extraRows = { [weak self] in self?.pairingController.rows() ?? [] }
        app.agents.onExtraRow = { [weak self] id in self?.pairingController.chose(id) }
        r.onAsk = { [weak self] peer, name in self?.ask(peer: peer, name: name) }
        r.onExit = { [weak self] to in self?.leave(to: to) }
        r.onGaveWay = { [weak self] to in self?.leave(to: to, gaveWay: true) }
        r.onEntrance = { [weak self] state in self?.arrive(state) }
        r.onShrug = { [weak self] why in
            Debug.log("travel: shrug \(why)")
            if why == "alreadyHere", let self {   // no annoyed shrug: it's there; the copies settle
                self.app.notify(.alreadyThere(self.app.settings.name))
                return
            }
            self?.app.show("emotion_annoyed", for: 2)
            self?.app.notify(why == "userDeclined" ? .tripDeclined : .tripFailed(why), voice: .sad)
        }
        r.transport.onState = { [weak self] s in
            Debug.log("travel: \(s)")
            if s.hasPrefix("browser") { self?.localNetworkBlocked = s.contains("PolicyDenied") }
        }
        do { try r.start() } catch { Debug.log("travel: couldn't start Bonjour: \(error)") }
        // Devices Bonjour can't see (a Wi-Fi that drops multicast), e.g. a Mosaico:
        // defaults write <app> PixlMemory.manualPeers -array "MOSAICO-D1199C|Mosaico 199C|10.0.30.13|47860"
        let manual = ManualPeer.fromDefaults()
        if !manual.isEmpty {
            r.transport.setManualPeers(manual)
            Debug.log("travel: manual peers \(manual.map { "\($0.ref.deviceName) @ \($0.host)" })")
        }
        runner = r
        // One source of truth: the Pixl that travels (the record) is the one on screen.
        if let s = r.owned, s.species != PixlSkins.currentID || s.name != app.settings.name {
            if PixlSkins.skin(s.species) != nil {
                Debug.log("travel: settings follow the record (\(s.species), \(s.name))")
                app.becomeSkin(id: s.species, name: s.name)
            } else {
                r.restyle(species: PixlSkins.currentID, name: app.settings.name)   // a species this app can't show
            }
        }
        Debug.log("travel: I'm \(me.deviceName) (\(me.deviceId.prefix(8)))")
        // Bluetooth to a Mosaico (D21): while linked, the transport reaches it through the
        // bridge's local port instead of Wi-Fi. Only for a Mosaico this Mac knows.
        let ble = BLEBridge(me: me)
        ble.onState = { Debug.log("travel: \($0)") }
        ble.onLink = { [weak r, weak self] ref, port in
            guard MosaicoFeed.devices().contains(ref.deviceId) || MosaicoPairingController.load(ref.deviceId) != nil else {
                Debug.log("travel: bluetooth link to \(ref.deviceName) not used (not a feed device or paired)")
                return
            }
            r?.transport.setRoute(ref, host: "127.0.0.1", port: port)
            // Say hello now (the first frame over the link is it), so the Mosaico knows this Mac
            // within a second instead of at the next routine update.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pushAgents()
                self?.pushFeed()
            }
        }
        ble.onUnlink = { [weak r] id in r?.transport.clearRoute(id) }
        // the self-test runs from a terminal: Bluetooth would ask the terminal for permission and wait
        if !CommandLine.arguments.contains("--selftest") { ble.start() }
        bluetooth = ble
        // away on another device since last time (or never had it): stay hidden until it comes
        recordChanged(r.record)
        if app.awayOn != nil { app.froggPanel.orderOut(nil) }
    }

    /// The record changed: where the Pixl is follows from it (owned = here). Leaving plays its
    /// exit first (onExit), which hides the panel when it lands.
    func recordChanged(_ rec: StoredPet?) {
        let wasAway = app.awayOn != nil
        app.awayOn = Whereabouts.awayOn(rec)
        Debug.log("travel: record \(rec.map { "\($0.isOwned ? "owned" : "not here") e\($0.epoch)" } ?? "none") → \(app.awayOn ?? "here")")
        // not here and no exit to play (it wasn't on screen): make sure nothing shows
        if wasAway, app.awayOn != nil {
            app.froggPanel.orderOut(nil)
            app.bubblePanel.orderOut(nil)
        }
    }

    /// The bubble's sub-line: one device by name, several as a list.
    var sendSlotName: String? { peers.count == 1 ? peers[0].deviceName : peers.isEmpty ? nil : "a device" }

    func send(to peer: DeviceRef) {
        guard let r = runner, r.owned != nil else { app.notify(.notHere(app.settings.name)); return }
        Debug.log("travel: send to \(peer.deviceName)")
        app.show("poke_1", for: 8)
        app.notify(.travelling(app.settings.name, to: peer.deviceName), voice: .happy)
        r.send(to: peer)
    }

    func ask(peer: DeviceRef, name: String) {
        Debug.log("travel: \(name) wants to come from \(peer.deviceName)")
        // the Pixl that would arrive here: show the question beside the menu bar.
        // Esc or a click away is "Not now".
        app.menu.showList([ListMenuView.Row(id: "q", title: "Catch \(name) from \(peer.deviceName)?", icon: "info", enabled: false),
                           ListMenuView.Row(id: "once", title: "Yes, just this time", icon: nil, trailing: "↵"),
                           ListMenuView.Row(id: "always", title: "Always accept from \(peer.deviceName)", icon: nil),
                           ListMenuView.Row(id: "no", title: "Not now", icon: nil, trailing: "esc")], near: nil, onSelect: { [weak self] row in
            guard let self, row.id != "q" else { return }
            self.app.menu.closeList()
            self.answer(row.id, peer: peer)
        }, onDismiss: { [weak self] in self?.answer("no", peer: peer) })
    }

    private func answer(_ id: String, peer: DeviceRef) {
        if id == "always" { trust(peer) }
        runner?.consent(id == "once" || id == "always", always: id == "always", for: peer)
    }

    // MARK: trusted devices (their offers come straight in; they may call the Pixl)

    let trustedNamesKey = "PixlMemory.trustedDeviceNames"

    func trust(_ peer: DeviceRef) {
        let ids = (runner?.trusted ?? []).union([peer.deviceId])
        UserDefaults.standard.set(Array(ids), forKey: trustedKey)
        var names = UserDefaults.standard.dictionary(forKey: trustedNamesKey) as? [String: String] ?? [:]
        names[peer.deviceId] = peer.deviceName
        UserDefaults.standard.set(names, forKey: trustedNamesKey)
    }

    func untrust(_ deviceId: String) {
        runner?.untrust(deviceId)
        UserDefaults.standard.set(Array(runner?.trusted ?? []), forKey: trustedKey)
        var names = UserDefaults.standard.dictionary(forKey: trustedNamesKey) as? [String: String] ?? [:]
        let name = names.removeValue(forKey: deviceId) ?? peers.first { $0.deviceId == deviceId }?.deviceName ?? deviceId
        UserDefaults.standard.set(names, forKey: trustedNamesKey)
        Debug.log("travel: untrusted \(deviceId.prefix(8))")
        app.notify(.trustRemoved(name))
    }

    /// Trusted devices by id and a name to show.
    var trustedDevices: [(id: String, name: String)] {
        let names = UserDefaults.standard.dictionary(forKey: trustedNamesKey) as? [String: String] ?? [:]
        return (runner?.trusted ?? []).sorted().map { id in
            (id, names[id] ?? peers.first { $0.deviceId == id }?.deviceName ?? String(id.prefix(8)))
        }
    }

    /// "Trusted devices…": each with Remove.
    func showTrusted() {
        let list = trustedDevices
        guard !list.isEmpty else {
            app.menu.showList([ListMenuView.Row(id: "none", title: "No trusted devices. Each one asks first.", icon: "info", enabled: false)],
                              near: nil) { _ in }
            return
        }
        app.menu.showList(list.map { ListMenuView.Row(id: $0.id, title: "Remove \($0.name)", icon: nil, trailing: "asks again") }, near: nil) { [weak self] row in
            guard let self else { return }
            self.app.menu.closeList()
            self.untrust(row.id)
        }
    }

    /// Committed (or this copy gave way to a newer one): leap up and away; this device only
    /// remembers where it went (the record already says so: see `recordChanged`).
    func leave(to peer: DeviceRef, gaveWay: Bool = false) {
        app.menu.close(reason: "travel")
        app.notify(gaveWay ? .alreadyHas(peer.deviceName, app.settings.name) : .left(app.settings.name, to: peer.deviceName))
        guard let foot = app.foot, app.froggPanel.isVisible else { app.froggPanel.orderOut(nil); return }
        app.puff(at: foot)
        app.run(Choreography.exit(from: foot, scale: app.scale), target: nil) { [weak self] in
            self?.app.froggPanel.orderOut(nil)
            self?.app.bubblePanel.orderOut(nil)
        }
    }

    /// Owned here now: become that Pixl (skin, name, the same way as a swap) and spring out of
    /// the menu bar. Pause and full-screen hiding stay as they were.
    func arrive(_ s: PetState) {
        Debug.log("travel: \(s.name) arrived (epoch \(s.epoch))")
        if PixlSkins.skin(s.species) != nil { app.becomeSkin(id: s.species, name: s.name) }
        app.userHidden = false
        app.springOut()
        app.notify(.arrived(app.settings.name), voice: .greet)
    }

    func callBack() {
        guard let r = runner, case .away(_, _, let ownerName, let ownerId, _)? = r.record else { return }
        // by id (a renamed device is the same device); by name for records from before ids were kept
        guard let owner = peers.first(where: { ownerId != nil && $0.deviceId == ownerId })
                ?? peers.first(where: { $0.deviceName == ownerName }) else {
            app.notify(.ownerAway(ownerName))
            return
        }
        r.callBack(from: owner)
        app.notify(.callingFrom(ownerName))
        // A device added by address is listed even when it's off: if no trip starts soon, say so
        // and offer to bring the Pixl back from the safety copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let r = self.runner, !r.node.inTrip, case .away? = r.record else { return }
            self.offerReclaim(because: "\(ownerName) didn't answer. It may be off or out of reach.")
        }
    }

    /// Bring the Pixl back here while its holder is unreachable (SPEC §10.5): from the copy this
    /// Mac kept when it left. When the holder comes back it gives way; its time there is lost.
    func reclaim() {
        guard let r = runner, r.canReclaim else { return }
        Debug.log("travel: reclaim (\(app.awayOn ?? "?") unreachable)")
        r.reclaim()
    }

    func offerReclaim(because why: String) {
        guard let r = runner, r.canReclaim, let away = app.awayOn else { return }
        let name = app.settings.name
        app.menu.showList([ListMenuView.Row(id: "info", title: why, icon: nil, trailing: nil, enabled: false),
                           ListMenuView.Row(id: "reclaim", title: "Bring \(name) back anyway (time on \(away) is lost)", icon: nil, trailing: "↵"),
                           ListMenuView.Row(id: "wait", title: "Wait for \(away)", icon: nil, trailing: "esc")], near: nil) { [weak self] row in
            guard let self else { return }
            if row.id == "info" { return }
            self.app.menu.closeList()
            if row.id == "reclaim" { self.reclaim() }
        }
    }

    // MARK: "what screens are available?" / "jump to my phone" (answered on the Mac, no AI)

    /// A screen this Pixl can go to: a display on this Mac or a nearby device.
    enum Place { case display(NSScreen), device(DeviceRef) }

    func places() -> [(String, Place)] {
        let displays = NSScreen.screens.map { ($0.localizedName, Place.display($0)) }
        return displays + peers.map { ($0.deviceName, Place.device($0)) }
    }

    /// True when `target` names a display or a nearby device ("the left screen", "my phone"), so
    /// "go to …" means a hop, not a website.
    func knowsPlace(_ target: String) -> Bool {
        let t = target.lowercased()
        if (t.contains("left") || t.contains("right")) && NSScreen.screens.count > 1 { return true }
        if t.range(of: #"\b(screen|display|monitor|phone|iphone|ipad|device)\b"#, options: .regularExpression) != nil { return true }
        let words = t.split(separator: " ").map(String.init)
        return places().contains { p in let n = p.0.lowercased(); return n.contains(t) || words.contains { $0.count > 2 && n.contains($0) } }
    }

    /// Answers questions about screens and devices, and "jump/go to <place>", without sending
    /// anything anywhere. Nil when it's a question for the model.
    func localAnswer(_ q: String) -> String? {
        let s = q.lowercased()
        if s.range(of: #"\b(screens?|displays?|monitors?|devices?)\b"#, options: .regularExpression) != nil,
           s.range(of: #"\b(what|which|how many|list|available|see|show)\b"#, options: .regularExpression) != nil {
            let d = NSScreen.screens.map(\.localizedName)
            var a = "\(d.count) \(d.count == 1 ? "display" : "displays") on this Mac: \(d.joined(separator: ", "))."
            a += localNetworkBlocked ? " I can't look for other devices until you allow Local Network (More ▸ Send to device)."
               : peers.isEmpty ? " No other devices nearby (they need Pixl open on the same Wi-Fi)."
                               : " Nearby: \(peers.map(\.deviceName).joined(separator: ", ")). Say “jump to …” and I'll go."
            return a
        }
        if let m = s.range(of: #"\b(jump|go|hop|travel|move|head)\b.*\bto\b\s+(my\s+|the\s+)?(.+)$"#, options: .regularExpression) {
            let target = String(s[m]).replacingOccurrences(of: #"^.*\bto\b\s+(my\s+|the\s+)?"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
            return go(to: target)
        }
        return nil
    }

    func go(to target: String) -> String {
        let t = target.lowercased()
        // "phone" matches "Luca's iPhone"; "left/right screen"; a device or display by name
        let words = t.split(separator: " ").map(String.init).filter { !["screen", "display", "monitor", "device"].contains($0) }
        if t.contains("left") || t.contains("right"), NSScreen.screens.count > 1 {
            let sorted = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
            return hop(to: t.contains("left") ? sorted.first! : sorted.last!)
        }
        for (name, place) in places() {
            let n = name.lowercased()
            if n.contains(t) || words.contains(where: { $0.count > 2 && n.contains($0) }) {
                switch place {
                case .display(let screen): return hop(to: screen)
                case .device(let peer): send(to: peer); return "Off to \(peer.deviceName)!"
                }
            }
        }
        let known = places().map(\.0)
        return "I don't see “\(target)”. I can go to: \(known.joined(separator: ", "))."
    }

    /// Another display on this Mac: hop there (an arc across, or out at the edge and in).
    func hop(to screen: NSScreen) -> String {
        let vis = app.topLeft(screen.visibleFrame)
        let spot = CGPoint(x: vis.midX, y: vis.maxY)
        guard let foot = app.foot else { return "I can't move right now." }
        if vis.contains(CGPoint(x: foot.x, y: foot.y - 1)) { return "I'm already on \(screen.localizedName)." }
        app.userPlaced = true   // stay there until the next window switch
        app.run(app.move(from: foot, to: spot), target: spot)
        return "Hopping to \(screen.localizedName)!"
    }
}
