import Foundation
import PixlzCore

/// Runs PixlzCore's trip protocol (TravelNode) over a transport, on the main thread:
/// network messages in, outputs performed **in order** (a `.saved` is written to disk before
/// any later `.send`, which is what keeps at least one whole copy of the Pixl somewhere).
@MainActor
public final class TripRunner {
    public private(set) var node: TravelNode
    public let transport: BonjourTransport
    let store: PetStore
    private var timer: Timer?

    /// The Pixl left (committed): play the exit toward this device.
    public var onExit: ((DeviceRef) -> Void)?
    /// The Pixl arrived and is owned here now: play the entrance.
    public var onEntrance: ((PetState) -> Void)?
    /// The trip didn't happen; the Pixl stays.
    public var onShrug: ((String) -> Void)?
    /// Devices reachable right now.
    public var onPeers: (([DeviceRef]) -> Void)?
    /// An offer from a device we haven't trusted yet: answer with `consent(_:)`.
    public var onAsk: ((DeviceRef, String) -> Void)?
    /// Devices the user said yes to (their offers go straight through).
    public var trusted: Set<String>
    private var heldOffers: [String: (Envelope, DeviceRef)] = [:]

    public private(set) var peers: [DeviceRef] = []

    public init(me: DeviceRef, store: PetStore, knownSpecies: Set<String>, trusted: Set<String> = []) {
        self.store = store
        self.trusted = trusted
        var n = TravelNode(me: me, record: (try? store.load()) ?? nil)
        n.knownSpecies = knownSpecies
        node = n
        transport = BonjourTransport(me: me)
        transport.onPeers = { [weak self] list in
            MainActor.assumeIsolated {
                guard let self else { return }
                let new = list.filter { p in !self.peers.contains(p) }
                self.peers = list
                self.onPeers?(list)
                for p in new { self.feed(.connected(p)) }   // reconcile ownership with anyone who just appeared
            }
        }
        transport.onEnvelope = { [weak self] env, peer in
            MainActor.assumeIsolated { self?.incoming(env, from: peer) }
        }
    }

    public func start() throws { try transport.start() }
    public func stop() { transport.stop(); timer?.invalidate() }

    /// The Pixl this device holds, if it holds it.
    public var owned: PetState? { if case .owned(let s)? = node.record { s } else { nil } }
    public var record: StoredPet? { node.record }

    /// First run on this device: it owns a brand-new Pixl.
    public func adoptIfNeeded(species: String, name: String) {
        guard node.record == nil else { return }
        let s = PetState(species: species, name: name, owner: transport.me, at: Date())
        try? store.save(.owned(s))
        var n = TravelNode(me: transport.me, record: .owned(s))
        n.knownSpecies = node.knownSpecies
        node = n
    }

    public func send(to peer: DeviceRef) { feed(.send(to: peer)) }
    public func callBack(from owner: DeviceRef) { feed(.call(owner: owner)) }

    private func incoming(_ env: Envelope, from peer: DeviceRef) {
        // first contact: an offer from a device the user hasn't trusted waits for a yes
        if env.type == .offer, !trusted.contains(peer.deviceId) {
            heldOffers[peer.deviceId] = (env, peer)
            onAsk?(peer, env.payload.name ?? "A Pixl")
            return
        }
        feed(.received(env, from: peer))
    }

    /// The user's answer to `onAsk`.
    public func consent(_ yes: Bool, for peer: DeviceRef) {
        guard let (env, p) = heldOffers.removeValue(forKey: peer.deviceId) else { return }
        if yes {
            trusted.insert(peer.deviceId)
            feed(.received(env, from: p))
        } else {
            let decline = Envelope(petId: env.petId, from: transport.me.deviceId, to: p.deviceId, type: .decline, epoch: env.epoch,
                                   payload: Payload(reason: DeclineReason.userDeclined.rawValue), sentAt: Date())
            transport.send(decline, to: p)
        }
    }

    func feed(_ input: TravelNode.Input) {
        let outs = node.handle(input, at: Date())
        perform(outs)
        schedule()
    }

    private func perform(_ outs: [TravelNode.Output]) {
        for o in outs {
            switch o {
            case .saved(let rec): try? store.save(rec)          // before anything after it
            case .send(let env, let to): transport.send(env, to: to)
            case .playExit(let to): onExit?(to)
            case .playEntrance: if let s = owned { onEntrance?(s) }
            case .shrug(let why): onShrug?(why)
            }
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard let d = node.nextDeadline else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(d.timeIntervalSinceNow, 0.05), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.feed(.tick) }
        }
    }
}
