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
        app.say("Turn on Pixl Memory under Local Network, so I can see your other devices.", for: 4)
    }
    let trustedKey = "PixlMemory.trustedDevices"

    init(app: AppController) { self.app = app }

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
            self?.peers = list
            Debug.log("travel: nearby \(list.map(\.deviceName))")
        }
        r.onAsk = { [weak self] peer, name in self?.ask(peer: peer, name: name) }
        r.onExit = { [weak self] to in self?.leave(to: to) }
        r.onEntrance = { [weak self] state in self?.arrive(state) }
        r.onShrug = { [weak self] why in
            Debug.log("travel: shrug \(why)")
            self?.app.show("emotion_annoyed", for: 2)
            self?.app.say(why == "userDeclined" ? "They said not now." : "Couldn't get there (\(why)). I'm staying.", for: 3)
        }
        r.transport.onState = { [weak self] s in
            Debug.log("travel: \(s)")
            if s.hasPrefix("browser") { self?.localNetworkBlocked = s.contains("PolicyDenied") }
        }
        do { try r.start() } catch { Debug.log("travel: couldn't start Bonjour: \(error)") }
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
        guard let r = runner, r.owned != nil else { app.say("I'm not here to send.", for: 2); return }
        Debug.log("travel: send to \(peer.deviceName)")
        app.show("poke_1", for: 8)
        app.say("Off to \(peer.deviceName)…", for: 8)
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
        app.say("Bye! See you on \(peer.deviceName).", for: 1.6)
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
        app.chatter("Hi! I came over from another device.")
    }

    func callBack() {
        guard let r = runner, case .away(_, _, let ownerName, _)? = r.record else { return }
        guard let owner = peers.first(where: { $0.deviceName == ownerName }) else {
            app.say("\(ownerName) isn't nearby right now.", for: 2.5)
            return
        }
        r.callBack(from: owner)
        app.say("Calling from \(ownerName)…", for: 3)
    }

    // MARK: "what screens are available?" / "jump to my phone" (answered on the Mac, no AI)

    /// A screen this Pixl can go to: a display on this Mac or a nearby device.
    enum Place { case display(NSScreen), device(DeviceRef) }

    func places() -> [(String, Place)] {
        let displays = NSScreen.screens.map { ($0.localizedName, Place.display($0)) }
        return displays + peers.map { ($0.deviceName, Place.device($0)) }
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
        app.run(Choreography.hop(app.route(from: foot, to: spot)), target: spot)
        return "Hopping to \(screen.localizedName)!"
    }
}
