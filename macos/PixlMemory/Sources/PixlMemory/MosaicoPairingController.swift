import AppKit
import PixlMemoryKit
import PixlTravel
import PixlzCore
import Security

/// Pairing with a Mosaico (D20), from the Agents list: compare the 6-digit code on both screens.
/// Paired devices (key and the last decision number) live in the Keychain. A paired Mosaico can
/// Allow, with a decision signed over exactly what it showed.
@MainActor
final class MosaicoPairingController {
    unowned let travel: TravelController
    private var pairing: MosaicoPairing?
    private var pairingPeer: DeviceRef?
    /// Texts this Mac transcribed for a Mosaico: the only free text it may send as a reply.
    var dictated: Set<String> = []

    init(travel: TravelController) { self.travel = travel }

    var app: AppController { travel.app }

    // MARK: the Agents list

    func rows() -> [ListMenuView.Row] {
        let wanted = MosaicoFeed.devices()
        let paired = Self.all()
        // reachable feed devices not paired yet: Pair
        let pair = travel.peers.filter { wanted.contains($0.deviceId) && paired[$0.deviceId] == nil }.map { p in
            ListMenuView.Row(id: "pair.\(p.deviceId)", title: "Pair \(p.deviceName) so it can Allow", icon: "send")
        }
        // every paired device, reachable or not (a lost Mosaico can be unpaired too)
        let unpair = paired.sorted { $0.value.name < $1.value.name }.map { id, p in
            ListMenuView.Row(id: "unpair.\(id)", title: "Unpair \(p.name)", icon: nil,
                             trailing: travel.peers.contains { $0.deviceId == id } ? "Allow off" : "not nearby")
        }
        return pair + unpair
    }

    func chose(_ id: String) {
        if id.hasPrefix("pair."), let p = travel.peers.first(where: { $0.deviceId == String(id.dropFirst(5)) }) {
            app.menu.closeList()
            start(with: p)
        } else if id.hasPrefix("unpair.") {
            let deviceId = String(id.dropFirst(7))
            Self.delete(deviceId)
            app.menu.closeList()
            app.notify(.agents("Unpaired. That Mosaico can only Deny now."))
            Debug.log("pairing: unpaired \(deviceId)")
        }
    }

    // MARK: the exchange

    func start(with peer: DeviceRef) {
        let p = MosaicoPairing(me: travel.me, peer: peer)
        pairing = p
        pairingPeer = peer
        travel.runner?.transport.sendFrame(p.start(), to: peer)
        Debug.log("pairing: started with \(peer.deviceName)")
        app.notify(.agents("Pairing with \(peer.deviceName)… look at its screen."))
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.pairingPeer == peer, self.pairing?.finished == false else { return }
            self.pairing = nil
            self.pairingPeer = nil
            self.app.menu.closeList()
            self.app.notify(.agentsError("Pairing timed out."))
        }
    }

    /// A "pair" frame from a device. True when it was one.
    func frame(_ body: Data, from peer: DeviceRef) -> Bool {
        guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        if let state = o["pairState"] as? [String: Any] {
            checkState(state["paired"] as? Bool ?? false, peer: peer)
            return true
        }
        guard let pair = o["pair"] as? [String: Any] else { return false }
        if pair["step"] as? String == "request" {
            askToPair(peer)
            return true
        }
        guard var p = pairing, pairingPeer?.deviceId == peer.deviceId else { return true }
        let events = p.receive(body)
        pairing = p
        handle(events, peer: peer)
        return true
    }

    private func answer(_ yes: Bool) {
        guard var p = pairing, let peer = pairingPeer else { return }
        let events = p.user(yes)
        pairing = p
        handle(events, peer: peer)
        if yes, !p.finished { app.notify(.agents("Now tap green on \(peer.deviceName).")) }
    }

    private func handle(_ events: [MosaicoPairing.Event], peer: DeviceRef) {
        for e in events {
            switch e {
            case .send(let body):
                travel.runner?.transport.sendFrame(body, to: peer)
            case .showCode(let code):
                let spaced = String(code.prefix(3)) + " " + String(code.suffix(3))
                Debug.log("pairing: code shown")
                app.menu.showList([ListMenuView.Row(id: "q", title: "Does \(peer.deviceName) show \(spaced)?", icon: "info", enabled: false),
                                   ListMenuView.Row(id: "yes", title: "Yes, the same code", icon: "check", trailing: "↵"),
                                   ListMenuView.Row(id: "no", title: "No, cancel", icon: nil, trailing: "esc")], near: nil, onSelect: { [weak self] row in
                    guard row.id != "q" else { return }
                    self?.app.menu.closeList()
                    self?.answer(row.id == "yes")
                }, onDismiss: { [weak self] in self?.answer(false) })   // Esc or a click away: No
            case .paired(let key):
                Self.save(peer.deviceId, Paired(name: peer.deviceName, key: key, last: 0))
                pairing = nil
                pairingPeer = nil
                Debug.log("pairing: paired with \(peer.deviceName)")
                app.notify(.agents("Paired with \(peer.deviceName). It can Allow your agents now."))
                travel.pushAgents()
            case .cancelled(let why):
                pairing = nil
                pairingPeer = nil
                app.menu.closeList()
                Debug.log("pairing: cancelled (\(why))")
                app.notify(.agentsError(why))
            }
        }
    }

    // MARK: started from the Mosaico, and checked on connect

    private var lastAsk: [String: Date] = [:]

    /// The Mosaico asked to pair (its Pair bubble). The Mac's user says yes before any code shows.
    private func askToPair(_ peer: DeviceRef) {
        guard MosaicoFeed.devices().contains(peer.deviceId) else {
            Debug.log("pairing: request from \(peer.deviceName) ignored (not a feed device)")
            return
        }
        guard pairing == nil, Date().timeIntervalSince(lastAsk[peer.deviceId] ?? .distantPast) > 10 else { return }
        lastAsk[peer.deviceId] = Date()
        Debug.log("pairing: \(peer.deviceName) asked to pair")
        app.menu.showList([ListMenuView.Row(id: "q", title: "\(peer.deviceName) wants to pair. Compare codes?", icon: "info", enabled: false),
                           ListMenuView.Row(id: "yes", title: "Yes, show the code", icon: "check", trailing: "↵"),
                           ListMenuView.Row(id: "no", title: "Not now", icon: nil, trailing: "esc")], near: nil) { [weak self] row in
            guard row.id != "q" else { return }
            self?.app.menu.closeList()
            if row.id == "yes" { self?.start(with: peer) } else { Debug.log("pairing: request from \(peer.deviceName) declined") }
        }
    }

    /// What the Mosaico says on connect, against what this Mac keeps. A mismatch is told, not
    /// fixed silently: the user pairs again (from either side).
    private func checkState(_ mosaicoPaired: Bool, peer: DeviceRef) {
        let macPaired = Self.load(peer.deviceId) != nil
        Debug.log("pairing: \(peer.deviceName) says \(mosaicoPaired ? "paired" : "not paired"); this Mac \(macPaired ? "has" : "has no") key")
        guard mosaicoPaired != macPaired, pairing == nil else { return }
        if macPaired {
            app.notify(.agentsError("\(peer.deviceName) lost its pairing with this Mac. Pair again (from either side) to Allow from it."))
        } else {
            app.notify(.agentsError("\(peer.deviceName) thinks it's paired, but this Mac has no key for it. Pair again."))
        }
    }

    // MARK: decisions

    /// A signed decision from a paired device: verified against what this Mac sent for that
    /// request. Returns the decision, or nil (unsigned, not paired, or it doesn't check out).
    func verified(_ body: Data, from peer: DeviceRef) -> (id: String, behavior: String)? {
        guard var paired = Self.load(peer.deviceId),
              let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let d = o["agentDecision"] as? [String: Any], d["tag"] != nil, let id = d["id"] as? String,
              let req = app.agents.hub.requests.first(where: { $0.id == id }) else { return nil }
        // a request nobody can answer any more: don't use up the device's counter on it
        guard app.agents.canAnswer(id) else {
            Debug.log("pairing: a decision from \(peer.deviceName) for \(id) can't be answered; not checked")
            return nil
        }
        let summary = MosaicoFeed.ascii(req.summary, 60), detail = MosaicoFeed.ascii(req.detail, 140)
        guard let ok = MosaicoPairing.verifyDecision(body, deviceId: peer.deviceId, key: paired.key, lastCounter: paired.last,
                                                     summary: summary, detail: detail) else {
            Debug.log("pairing: a decision from \(peer.deviceName) didn't verify")
            return nil
        }
        paired.last = ok.n
        Self.save(peer.deviceId, paired)
        // The device only saw a shortened or cleaned-up copy of this command: it can't allow it.
        if ok.behavior == "allow" && !MosaicoFeed.answerableOnDevice(summary: req.summary, detail: req.detail) {
            Debug.log("pairing: \(peer.deviceName) tried to allow a command it couldn't show in full; ignored")
            return nil
        }
        return (ok.id, ok.behavior)
    }

    /// A signed quick reply from a paired device (only the known replies pass).
    func verifiedReply(_ body: Data, from peer: DeviceRef) -> (id: String, text: String)? {
        guard MosaicoFeed.devices().contains(peer.deviceId), var paired = Self.load(peer.deviceId),
              let ok = MosaicoPairing.verifyReply(body, deviceId: peer.deviceId, key: paired.key, lastCounter: paired.last,
                                                  dictated: dictated) else { return nil }
        dictated.remove(ok.text)   // once
        paired.last = ok.n
        Self.save(peer.deviceId, paired)
        return (ok.id, ok.text)
    }

    // MARK: Keychain

    struct Paired: Codable { var name: String; var key: Data; var last: UInt32 }
    static let service = "dev.pixlz.PixlMemory.pairing"

    static func load(_ deviceId: String) -> Paired? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: deviceId, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Paired.self, from: data)
    }

    /// Every paired device in the Keychain, by id.
    static func all() -> [String: Paired] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        guard s == errSecSuccess, let items = out as? [[String: Any]] else {
            if s != errSecItemNotFound { Debug.log("pairing: keychain list failed \(s)") }
            return [:]
        }
        var found: [String: Paired] = [:]
        for item in items {
            if let id = item[kSecAttrAccount as String] as? String, let p = load(id) { found[id] = p }
        }
        return found
    }

    static func save(_ deviceId: String, _ p: Paired) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: deviceId]
        let u = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if u == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            if s != errSecSuccess { Debug.log("pairing: keychain add failed \(s)") }
        } else if u != errSecSuccess {
            Debug.log("pairing: keychain update failed \(u)")
        }
    }

    static func delete(_ deviceId: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: deviceId]
        SecItemDelete(q as CFDictionary)
    }
}
