import Foundation
import PixlzCore

/// Runs PixlzCore's trip protocol (TravelNode) over a transport, on the main thread:
/// network messages in, outputs performed **in order** (a `.saved` is written to disk before
/// any later `.send`, which is what keeps at least one whole copy of the Pixl somewhere).
/// A save that fails stops everything after it: the node goes back to what's on disk.
@MainActor
public final class TripRunner {
    /// While a Pixl is pending arrival, ask every reachable device this often.
    public static let pendingCheckInterval: TimeInterval = 60
    /// After a status reply ended a trip or changed the record, ask once more this soon.
    public static let recheckDelay: TimeInterval = 2

    public private(set) var node: TravelNode
    public let transport: BonjourTransport
    let store: PetStore
    private var timer: Timer?
    private var pendingTimer: Timer?
    private var recheckTimer: Timer?
    /// Tests: capture sends instead of the network.
    var sender: ((Envelope, DeviceRef) -> Void)?

    /// The Pixl left (committed): play the exit toward this device.
    public var onExit: ((DeviceRef) -> Void)?
    /// Two copies met and the one here was older: it leaves for the device that has it.
    /// Falls back to `onExit` when unset.
    public var onGaveWay: ((DeviceRef) -> Void)?
    /// The Pixl arrived and is owned here now: play the entrance.
    public var onEntrance: ((PetState) -> Void)?
    /// The trip didn't happen; the Pixl stays.
    public var onShrug: ((String) -> Void)?
    /// Devices reachable right now.
    public var onPeers: (([DeviceRef]) -> Void)?
    /// An offer from a device we haven't trusted yet: answer with `consent(_:always:for:)`.
    public var onAsk: ((DeviceRef, String) -> Void)?
    /// The record changed (after it was saved), or was put back after a failed save.
    public var onRecord: ((StoredPet?) -> Void)?
    /// Something went wrong that the user should know about (a save failed, the file was unreadable).
    public var onProblem: ((String) -> Void)?
    /// Diagnostics.
    public var onLog: ((String) -> Void)?
    /// True for a device paired by code (a Mosaico): it may `call` the Pixl like a trusted one.
    public var isPaired: ((String) -> Bool)?
    /// Devices the user said "always" to (their offers go straight through, they may call).
    public var trusted: Set<String>
    private var heldOffers: [String: (Envelope, DeviceRef)] = [:]
    /// Why the saved Pixl couldn't be loaded at launch (the file was moved aside). Nil = fine.
    public private(set) var loadProblem: String?

    public internal(set) var peers: [DeviceRef] = []

    public init(me: DeviceRef, store: PetStore, knownSpecies: Set<String>, trusted: Set<String> = []) {
        self.store = store
        self.trusted = trusted
        var loaded: StoredPet?
        do {
            loaded = try store.load()
        } catch PetStoreError.unreadable(let kept, let why) {
            loadProblem = "pet.json couldn't be read (\(why)); kept as \(kept?.lastPathComponent ?? "it was")"
        } catch {
            loadProblem = "pet.json couldn't be read (\(error))"
        }
        var n = TravelNode(me: me, record: loaded)
        n.knownSpecies = knownSpecies
        node = n
        transport = BonjourTransport(me: me)
        transport.onPeers = { [weak self] list in
            MainActor.assumeIsolated {
                guard let self else { return }
                let new = list.filter { p in !self.peers.contains { $0.deviceId == p.deviceId } }
                self.peers = list
                self.onPeers?(list)
                for p in new { self.feed(.connected(p)) }   // reconcile ownership with anyone who just appeared
            }
        }
        transport.onEnvelope = { [weak self] env, peer in
            MainActor.assumeIsolated { self?.incoming(env, from: peer) }
        }
        if let loadProblem { log("travel: \(loadProblem)") }
    }

    public func start() throws { try transport.start(); schedule() }
    public func stop() {
        transport.stop()
        timer?.invalidate()
        pendingTimer?.invalidate(); pendingTimer = nil
        recheckTimer?.invalidate(); recheckTimer = nil
    }

    /// The Pixl this device holds, if it holds it.
    public var owned: PetState? { if case .owned(let s)? = node.record { s } else { nil } }
    public var record: StoredPet? { node.record }

    private func log(_ s: String) { onLog?(s) }

    /// First run on this device: it owns a brand-new Pixl. Never over a file that couldn't be read.
    public func adoptIfNeeded(species: String, name: String) {
        guard node.record == nil, loadProblem == nil else { return }
        let s = PetState(species: species, name: name, owner: transport.me, at: Date())
        do { try store.save(.owned(s)) } catch {
            problem("Couldn't save the new Pixl: \(error.localizedDescription)")
            return
        }
        var n = TravelNode(me: transport.me, record: .owned(s))
        n.knownSpecies = node.knownSpecies
        n.canHost = node.canHost
        node = n
        onRecord?(node.record)
    }

    public func send(to peer: DeviceRef) { feed(.send(to: peer)) }
    public func callBack(from owner: DeviceRef) { feed(.call(owner: owner)) }
    /// Brings the Pixl back from the safety copy while its holder is unreachable (SPEC §10.5).
    public func reclaim() { feed(.reclaim) }
    public var canReclaim: Bool { node.canReclaim }

    /// A swap or a rename: the Pixl here travels as `species`/`name` from now on. False when it
    /// isn't here, a trip is in progress, or the save failed (then nothing changed).
    @discardableResult
    public func restyle(species: String, name: String) -> Bool {
        guard owned != nil, !node.inTrip else { return false }
        var next = node
        guard case .saved(let rec)? = next.restyle(species: species, name: name, at: Date()).first else { return true }   // nothing to change
        do { try store.save(rec) } catch {
            problem("Couldn't save the change: \(error.localizedDescription)")
            return false
        }
        node = next
        onRecord?(rec)
        return true
    }

    func incoming(_ env: Envelope, from peer: DeviceRef) {
        // first contact: an offer from a device the user hasn't trusted waits for a yes
        if env.type == .offer, !trusted.contains(peer.deviceId) {
            heldOffers[peer.deviceId] = (env, peer)
            onAsk?(peer, env.payload.name ?? "A Pixl")
            return
        }
        // only a trusted or paired device may call the Pixl away
        if env.type == .call, !trusted.contains(peer.deviceId), !(isPaired?(peer.deviceId) ?? false) {
            log("travel: call from \(peer.deviceName) refused (not trusted or paired)")
            return
        }
        feed(.received(env, from: peer))
    }

    /// The user's answer to `onAsk`: yes once, yes always (trust it from now on), or no.
    public func consent(_ yes: Bool, always: Bool = false, for peer: DeviceRef) {
        guard let (env, p) = heldOffers.removeValue(forKey: peer.deviceId) else { return }
        if yes {
            if always { trusted.insert(peer.deviceId) }
            feed(.received(env, from: p))
        } else {
            let decline = Envelope(petId: env.petId, from: transport.me.deviceId, to: p.deviceId, type: .decline, epoch: env.epoch,
                                   payload: Payload(reason: DeclineReason.userDeclined.rawValue), sentAt: Date())
            deliver(decline, to: p)
        }
    }

    /// Stop trusting a device: its next offer asks again, and it can't call.
    public func untrust(_ deviceId: String) { trusted.remove(deviceId) }

    func feed(_ input: TravelNode.Input) {
        // Only a trusted or paired device's status can make the copy here give way (ids are
        // self-declared: anyone else on the network could otherwise talk it away).
        var mayGiveWayTo = trusted
        if case .received(_, let p) = input, isPaired?(p.deviceId) == true { mayGiveWayTo.insert(p.deviceId) }
        node.mayGiveWayTo = mayGiveWayTo
        let before = node
        let outs = node.handle(input, at: Date())
        let ok = perform(outs, before: before)
        // a status reply that ended a trip or changed the record: ask everyone once more soon
        if ok, case .received(let env, _) = input, env.type == .statusReply,
           (before.inTrip && !node.inTrip) || before.record != node.record {
            scheduleRecheck()
        }
        schedule()
    }

    /// Asks every reachable device where the Pixl is.
    func recheck() {
        for p in peers { feed(.connected(p)) }
    }

    /// Performs outputs in order. False when a save failed: nothing after it was done, the node
    /// is back to what's on disk and the trip (if any) was aborted.
    @discardableResult
    private func perform(_ outs: [TravelNode.Output], before: TravelNode) -> Bool {
        var lastSaved: StoredPet?
        for o in outs {
            switch o {
            case .saved(let rec):                                   // before anything after it
                do { try store.save(rec) } catch {
                    saveFailed(error, before: before)
                    return false
                }
                lastSaved = rec
                onRecord?(rec)
            case .send(let env, let to): deliver(env, to: to)
            case .playExit(let to):
                // a trip's safety copy is the receiver's; a copy that gave way keeps its own (or none)
                if case .away(_, _, _, _, let t)? = lastSaved, t == nil || t?.owner.deviceId == node.me.deviceId,
                   let onGaveWay { onGaveWay(to) } else { onExit?(to) }
            case .playEntrance: if let s = owned { onEntrance?(s) }
            case .shrug(let why): onShrug?(why)
            }
        }
        return true
    }

    private func saveFailed(_ error: Error, before: TravelNode) {
        node = before
        let disk: StoredPet?
        do { disk = try store.load() } catch { disk = before.record }
        for o in node.abandon(reload: disk, reason: "saveFailed", at: Date()) {
            if case .send(let env, let to) = o { deliver(env, to: to) }
        }
        onRecord?(node.record)
        problem("Couldn't save the Pixl (\(error.localizedDescription)); the trip was stopped.")
    }

    private func problem(_ s: String) {
        log("travel: problem: \(s)")
        onProblem?(s)
    }

    private func deliver(_ env: Envelope, to peer: DeviceRef) {
        if let sender { sender(env, peer) } else { transport.send(env, to: peer) }
    }

    // MARK: timers

    /// Tests: the 60 s pending check is running / a recheck is due soon.
    var pendingCheckActive: Bool { pendingTimer != nil }
    var recheckSoonScheduled: Bool { recheckTimer != nil }

    private func scheduleRecheck() {
        recheckTimer?.invalidate()
        recheckTimer = Timer.scheduledTimer(withTimeInterval: Self.recheckDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckTimer = nil
                self?.recheck()
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        if let d = node.nextDeadline {
            timer = Timer.scheduledTimer(withTimeInterval: max(d.timeIntervalSinceNow, 0.05), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.feed(.tick) }
            }
        }
        // pending arrival: keep asking until someone settles it
        if case .pendingArrival? = node.record {
            if pendingTimer == nil {
                pendingTimer = Timer.scheduledTimer(withTimeInterval: Self.pendingCheckInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recheck() }
                }
            }
        } else {
            pendingTimer?.invalidate()
            pendingTimer = nil
        }
    }
}
