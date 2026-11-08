import Foundation
import Network
import PixlzCore

/// Finds the other devices running a Pixl on the local network and carries trip envelopes
/// between them (SPEC §10.3, D9). Bonjour service `_pixlz._tcp`: every device advertises
/// itself with its id and name and browses for the others, the way AirDrop finds devices.
/// Frames are PixlzCore's length-prefixed JSON envelopes.
///
/// What travels is only the Pixl's PetState (name, species, needs, stats): never memory,
/// highlights or wallet keys. First contact from an unknown device is confirmed by the user
/// in the app; code pairing with an encrypted channel (Pairing.deriveKey) is next.
public final class BonjourTransport: @unchecked Sendable {
    public static let serviceType = "_pixlz._tcp"

    public let me: DeviceRef
    /// Called on the main queue.
    public var onPeers: (([DeviceRef]) -> Void)?
    public var onEnvelope: ((Envelope, DeviceRef) -> Void)?
    /// Diagnostics: listener/browser state changes ("waiting: PolicyDenied" = Local Network not allowed yet).
    public var onState: ((String) -> Void)?

    private let queue = DispatchQueue(label: "pixl.travel")
    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Discovered services by device id (from the TXT record).
    private var found: [String: (ref: DeviceRef, endpoint: NWEndpoint)] = [:]
    /// Open connections by device id.
    private var conns: [String: NWConnection] = [:]
    private var decoders: [ObjectIdentifier: Framing.Decoder] = [:]
    /// Which device an inbound connection belongs to (learned from its first envelope).
    private var inboundPeer: [ObjectIdentifier: DeviceRef] = [:]

    public init(me: DeviceRef) { self.me = me }

    public var peers: [DeviceRef] { queue.sync { found.values.map(\.ref).sorted { $0.deviceName < $1.deviceName } } }

    // MARK: start / stop

    public func start() throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let l = try NWListener(using: params)
        var txt = NWTXTRecord()
        txt["id"] = me.deviceId
        txt["name"] = me.deviceName
        // the service name must be unique on the network: the device name plus a short id
        l.service = NWListener.Service(name: "\(me.deviceName) · \(me.deviceId.prefix(6))", type: Self.serviceType, txtRecord: txt)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] state in
            let text = "\(state)"
            DispatchQueue.main.async { self?.onState?("listener \(text)") }
        }
        l.start(queue: queue)
        listener = l

        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.stateUpdateHandler = { [weak self] state in
            let text = "\(state)"
            DispatchQueue.main.async { self?.onState?("browser \(text)") }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        queue.sync {
            listener?.cancel(); listener = nil
            browser?.cancel(); browser = nil
            conns.values.forEach { $0.cancel() }; conns.removeAll()
            found.removeAll()
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [String: (DeviceRef, NWEndpoint)] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = txt["id"], let name = txt["name"], id != me.deviceId else { continue }
            next[id] = (DeviceRef(deviceId: id, deviceName: name), r.endpoint)
        }
        found = next.mapValues { (ref: $0.0, endpoint: $0.1) }
        let list = found.values.map(\.ref).sorted { $0.deviceName < $1.deviceName }
        DispatchQueue.main.async { self.onPeers?(list) }
    }

    // MARK: sending

    /// Sends `envelope` to `peer`, opening a connection if needed.
    public func send(_ envelope: Envelope, to peer: DeviceRef) {
        queue.async {
            guard let data = try? Framing.encode(envelope) else { return }
            let c: NWConnection
            if let open = self.conns[peer.deviceId] {
                c = open
            } else if let f = self.found[peer.deviceId] {
                c = NWConnection(to: f.endpoint, using: .tcp)
                self.conns[peer.deviceId] = c
                self.inboundPeer[ObjectIdentifier(c)] = peer
                self.start(c)
            } else {
                return  // not reachable any more: the trip times out and the Pixl stays
            }
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: connections

    private func accept(_ c: NWConnection) { start(c) }

    private func start(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            if case .failed = state { self.drop(c) }
            if case .cancelled = state { self.drop(c) }
        }
        c.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, error in
            guard let self, let c else { return }
            if let data, !data.isEmpty {
                var d = self.decoders[ObjectIdentifier(c)] ?? Framing.Decoder()
                let envelopes = (try? d.feed(data)) ?? []
                self.decoders[ObjectIdentifier(c)] = d
                for env in envelopes { self.deliver(env, on: c) }
            }
            if done || error != nil { self.drop(c); return }
            self.receive(on: c)
        }
    }

    private func deliver(_ env: Envelope, on c: NWConnection) {
        guard env.to == me.deviceId else { return }
        // the sender is who it says it is only if we found it advertising that id (same network)
        guard let peer = found[env.from]?.ref ?? inboundPeer[ObjectIdentifier(c)] else { return }
        inboundPeer[ObjectIdentifier(c)] = peer
        if conns[peer.deviceId] == nil { conns[peer.deviceId] = c }
        DispatchQueue.main.async { self.onEnvelope?(env, peer) }
    }

    private func drop(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        decoders[id] = nil
        if let peer = inboundPeer.removeValue(forKey: id), conns[peer.deviceId] === c { conns[peer.deviceId] = nil }
        c.cancel()
    }
}

/// This device's identity for trips: a stable id and the computer's name.
public enum ThisDevice {
    public static func ref(defaults: UserDefaults = .standard, env: [String: String] = ProcessInfo.processInfo.environment) -> DeviceRef {
        // PIXL_DEVICE_ID / PIXL_DEVICE_NAME: a second copy of the app on one Mac (tests, demos)
        if let id = env["PIXL_DEVICE_ID"] { return DeviceRef(deviceId: id, deviceName: env["PIXL_DEVICE_NAME"] ?? id) }
        let key = "PixlMemory.deviceId"
        let id = defaults.string(forKey: key) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: key)
            return new
        }()
        return DeviceRef(deviceId: id, deviceName: Host.current().localizedName ?? "This Mac")
    }
}
