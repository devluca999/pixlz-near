import AppKit
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
                                        answerable: req.map { agents.canAnswer($0.id) } ?? false)
        }
        let body = MosaicoFeed.agentsBody(rows, alerts: agents.alertsOn, from: me)
        for p in targets { r.transport.sendFrame(body, to: p) }
        Debug.log("travel: agents to \(targets.map(\.deviceName)): \(rows.count) sessions \(rows.map { "\($0.project)·\($0.id.prefix(8))" }), \(agents.hub.requests.count) waiting")
    }

    /// A frame from a device that isn't a trip message: a Mosaico's answer to a request.
    /// Deny only: Allow from the Mosaico waits for pairing (D19), since the link isn't secured.
    func frame(_ body: Data, from peer: DeviceRef) {
        if pairingController.frame(body, from: peer) { return }
        guard let d = MosaicoFeed.agentDecision(body) else { return }
        guard MosaicoFeed.devices().contains(peer.deviceId) else {
            Debug.log("travel: agent decision from \(peer.deviceName) ignored (not a feed device)")
            return
        }
        // Signed by a paired device (D20): Allow or Deny, over what it showed.
        if let v = pairingController.verified(body, from: peer) {
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
        // the first device adopts the Pixl; a second copy (PIXL_DEVICE_ID) starts empty and
        // waits for it to visit (one Pixl, one owner at a time: SPEC D9)
        if ProcessInfo.processInfo.environment["PIXL_DEVICE_ID"] == nil {
            r.adoptIfNeeded(species: PixlSkins.currentID, name: app.settings.name)
        }
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
        r.transport.onFrame = { [weak self] body, peer in self?.frame(body, from: peer) }
        app.agents.onHubChange = { [weak self] in self?.scheduleAgentsPush() }
        app.agents.extraRows = { [weak self] in self?.pairingController.rows() ?? [] }
        app.agents.onExtraRow = { [weak self] id in self?.pairingController.chose(id) }
        r.onAsk = { [weak self] peer, name in self?.ask(peer: peer, name: name) }
        r.onExit = { [weak self] to in self?.leave(to: to) }
        r.onEntrance = { [weak self] state in self?.arrive(state) }
        r.onShrug = { [weak self] why in
            Debug.log("travel: shrug \(why)")
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
        Debug.log("travel: I'm \(me.deviceName) (\(me.deviceId.prefix(8)))")
        // away on another device since last time (or never had it): stay hidden until it comes
        if case .away(_, _, let owner, _)? = r.record {
            app.awayOn = owner
            app.froggPanel.orderOut(nil)
        } else if r.record == nil {
            app.awayOn = "another device"
            app.froggPanel.orderOut(nil)
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
        // the Pixl that would arrive here: show the question beside the menu bar
        app.menu.showList([ListMenuView.Row(id: "yes", title: "Catch \(name) from \(peer.deviceName)", icon: nil, trailing: "↵"),
                           ListMenuView.Row(id: "no", title: "Not now", icon: nil, trailing: "esc")], near: nil) { [weak self] row in
            guard let self else { return }
            self.app.menu.closeList()
            if row.id == "yes" { UserDefaults.standard.set(Array((self.runner?.trusted ?? []).union([peer.deviceId])), forKey: self.trustedKey) }
            self.runner?.consent(row.id == "yes", for: peer)
        }
    }

    /// Committed: leap up and away, then this device only remembers where it went.
    func leave(to peer: DeviceRef) {
        app.awayOn = peer.deviceName
        app.menu.close(reason: "travel")
        guard let foot = app.foot else { app.froggPanel.orderOut(nil); return }
        app.notify(.left(app.settings.name, to: peer.deviceName))
        app.puff(at: foot)
        app.run(Choreography.exit(from: foot, scale: app.scale), target: nil) { [weak self] in
            self?.app.froggPanel.orderOut(nil)
            self?.app.bubblePanel.orderOut(nil)
        }
    }

    /// Owned here now: become that Pixl (skin, name) and spring out of the menu bar.
    func arrive(_ s: PetState) {
        Debug.log("travel: \(s.name) arrived (epoch \(s.epoch))")
        app.awayOn = nil
        if PixlSkins.skin(s.species) != nil, s.species != PixlSkins.currentID {
            PixlSkins.currentID = s.species
            app.settings.skin = s.species
            app.buildFrogg()
        }
        app.settings.name = s.name
        app.settings.save()
        app.userHidden = true   // so summon() plays the entrance from the icon
        app.summon()
        app.notify(.arrived(app.settings.name), voice: .greet)
    }

    func callBack() {
        guard let r = runner, case .away(_, _, let ownerName, _)? = r.record else { return }
        guard let owner = peers.first(where: { $0.deviceName == ownerName }) else {
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
        app.menu.showList([ListMenuView.Row(id: "info", title: why, icon: nil, trailing: nil),
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
