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
/// in the app. Device ids here are self-declared and frames are not authenticated: only trusted
/// or code-paired (MosaicoPairing, D20) devices may call the Pixl or make it give way.
public final class BonjourTransport: @unchecked Sendable {
    public static let serviceType = "_pixlz._tcp"

    public let me: DeviceRef
    /// Called on the main queue.
    public var onPeers: (([DeviceRef]) -> Void)?
    public var onEnvelope: ((Envelope, DeviceRef) -> Void)?
    /// A frame that isn't an envelope (a Mosaico's agent decision), with the device it came from.
    public var onFrame: ((Data, DeviceRef) -> Void)?
    /// Diagnostics: listener/browser state changes ("waiting: PolicyDenied" = Local Network not allowed yet).
    public var onState: ((String) -> Void)?

    private let queue = DispatchQueue(label: "pixl.travel")
    private var listener: NWListener?
    private var browser: NWBrowser?
    /// Reachable devices by id: Bonjour results, plus manual peers Bonjour doesn't see.
    private var found: [String: (ref: DeviceRef, endpoint: NWEndpoint)] = [:]
    private var bonjour: [String: (ref: DeviceRef, endpoint: NWEndpoint)] = [:]
    private var manual: [String: (ref: DeviceRef, endpoint: NWEndpoint)] = [:]
    /// A better route to a device than Wi-Fi (the Bluetooth bridge's local port): wins while set.
    private var routes: [String: (ref: DeviceRef, endpoint: NWEndpoint)] = [:]
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
            found.removeAll(); bonjour.removeAll(); manual.removeAll(); routes.removeAll()
            decoders.removeAll(); inboundPeer.removeAll()
        }
        DispatchQueue.main.async { self.onPeers?([]) }   // nobody is reachable any more
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var next: [String: (DeviceRef, NWEndpoint)] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = txt["id"], let name = txt["name"], id != me.deviceId else { continue }
            next[id] = (DeviceRef(deviceId: id, deviceName: name), r.endpoint)
        }
        bonjour = next.mapValues { (ref: $0.0, endpoint: $0.1) }
        publish()
    }

    /// Devices to reach by address when Bonjour can't see them, e.g. on a Wi-Fi that drops
    /// multicast. Bonjour wins when it finds the same device id.
    public func setManualPeers(_ peers: [ManualPeer]) {
        queue.async {
            self.manual = Dictionary(peers.filter { $0.ref.deviceId != self.me.deviceId }.map {
                ($0.ref.deviceId, (ref: $0.ref, endpoint: NWEndpoint.hostPort(host: .init($0.host), port: .init(rawValue: $0.port)!)))
            }, uniquingKeysWith: { a, _ in a })
            self.publish()
        }
    }

    private func publish() {
        found = manual.merging(bonjour) { _, b in b }.merging(routes) { _, r in r }
        let list = found.values.map(\.ref).sorted { $0.deviceName < $1.deviceName }
        DispatchQueue.main.async { self.onPeers?(list) }
    }

    /// Reach `ref` at `host:port` instead (a local bridge), until `clearRoute`. The open
    /// connection to it is dropped, so the next message takes the new way.
    public func setRoute(_ ref: DeviceRef, host: String, port: UInt16) {
        queue.async {
            self.routes[ref.deviceId] = (ref, .hostPort(host: .init(host), port: .init(rawValue: port)!))
            if let c = self.conns.removeValue(forKey: ref.deviceId) { self.drop(c) }
            self.publish()
            DispatchQueue.main.async { self.onState?("route \(ref.deviceName) via \(host):\(port)") }
        }
    }

    public func clearRoute(_ deviceId: String) {
        queue.async {
            guard self.routes.removeValue(forKey: deviceId) != nil else { return }
            if let c = self.conns.removeValue(forKey: deviceId) { self.drop(c) }
            self.publish()
            DispatchQueue.main.async { self.onState?("route for \(deviceId.prefix(14)) cleared") }
        }
    }

    // MARK: sending

    /// Sends `envelope` to `peer`, opening a connection if needed.
    public func send(_ envelope: Envelope, to peer: DeviceRef) {
        var envelope = envelope
        envelope.payload.fromName = me.deviceName   // so a peer that can't browse still knows who we are
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

    /// Sends one framed JSON body that isn't a trip envelope (the Mosaico feed) on the open
    /// connection to `peer`, opening one if needed.
    public func sendFrame(_ body: Data, to peer: DeviceRef) {
        queue.async {
            var length = UInt32(body.count).bigEndian
            let data = Data(bytes: &length, count: 4) + body
            let c: NWConnection
            if let open = self.conns[peer.deviceId] {
                c = open
            } else if let f = self.found[peer.deviceId] {
                c = NWConnection(to: f.endpoint, using: .tcp)
                self.conns[peer.deviceId] = c
                self.inboundPeer[ObjectIdentifier(c)] = peer
                self.start(c)
            } else {
                return
            }
            c.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    // MARK: connections

    private func accept(_ c: NWConnection) { start(c) }

    private func start(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            let who = self.inboundPeer[ObjectIdentifier(c)]?.deviceName ?? "\(c.endpoint)"
            let text = "connection \(who): \(state)"
            DispatchQueue.main.async { self.onState?(text) }
            if case .failed = state { self.drop(c) }
            if case .cancelled = state { self.drop(c) }
            // `waiting` (refused, unreachable: the other device restarted) never fails on its own,
            // and everything sent on it would queue forever: drop it so the next send reconnects.
            if case .waiting = state { self.drop(c) }
        }
        c.start(queue: queue)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, error in
            guard let self, let c else { return }
            if let data, !data.isEmpty {
                var d = self.decoders[ObjectIdentifier(c)] ?? Framing.Decoder()
                guard let frames = try? d.frames(data) else {
                    // a broken stream: the rest can't be trusted to line up
                    let text = "connection \(self.inboundPeer[ObjectIdentifier(c)]?.deviceName ?? "?"): framing error, dropped"
                    DispatchQueue.main.async { self.onState?(text) }
                    self.drop(c)
                    return
                }
                self.decoders[ObjectIdentifier(c)] = d
                for body in frames {
                    if let env = try? PetState.decoder.decode(Envelope.self, from: body) {
                        self.deliver(env, on: c)
                    } else {
                        self.deliverFrame(body, on: c)
                    }
                }
            }
            if done || error != nil { self.drop(c); return }
            self.receive(on: c)
        }
    }

    private func deliver(_ env: Envelope, on c: NWConnection) {
        guard env.to == me.deviceId else { return }
        // A connection belongs to one device: the one we opened it for, or the first one that
        // spoke on it. An envelope claiming another sender is ignored (never relabelled).
        if let known = inboundPeer[ObjectIdentifier(c)], known.deviceId != env.from { return }
        // who sent it: a device we found advertising that id, or (if our own browsing is held
        // back, e.g. Local Network not allowed yet) the name it advertised in the envelope
        let advertised = env.payload.fromName.map { DeviceRef(deviceId: env.from, deviceName: $0) }
        guard let peer = found[env.from]?.ref ?? inboundPeer[ObjectIdentifier(c)] ?? advertised else { return }
        inboundPeer[ObjectIdentifier(c)] = peer
        if conns[peer.deviceId] == nil { conns[peer.deviceId] = c }
        DispatchQueue.main.async { self.onEnvelope?(env, peer) }
    }

    private func deliverFrame(_ body: Data, on c: NWConnection) {
        let id = ObjectIdentifier(c)
        let peer = inboundPeer[id] ?? conns.first(where: { $0.value === c }).flatMap { found[$0.key]?.ref ?? manual[$0.key]?.ref }
        guard let peer else { return }
        DispatchQueue.main.async { self.onFrame?(body, peer) }
    }

    private func drop(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        decoders[id] = nil
        if let peer = inboundPeer.removeValue(forKey: id), conns[peer.deviceId] === c { conns[peer.deviceId] = nil }
        c.cancel()
    }
}

/// A device reached by address instead of Bonjour.
public struct ManualPeer: Equatable, Sendable {
    public var ref: DeviceRef
    public var host: String
    public var port: UInt16

    public init(ref: DeviceRef, host: String, port: UInt16) {
        self.ref = ref
        self.host = host
        self.port = port
    }

    /// `id|name|host|port`, e.g. `MOSAICO-D1199C|Mosaico 199C|10.0.30.13|47860`. Nil if malformed.
    public init?(_ text: String) {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4, !parts[0].isEmpty, !parts[2].isEmpty, let port = UInt16(parts[3]), port > 0 else { return nil }
        self.init(ref: DeviceRef(deviceId: parts[0], deviceName: parts[1].isEmpty ? parts[0] : parts[1]), host: parts[2], port: port)
    }

    /// The defaults key the apps read: an array of `id|name|host|port` strings.
    public static let defaultsKey = "PixlMemory.manualPeers"

    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> [ManualPeer] {
        (defaults.stringArray(forKey: defaultsKey) ?? []).compactMap(ManualPeer.init)
    }
}

/// This device's identity for trips: a stable id and the computer's name.
public enum ThisDevice {
    /// - Parameter name: the device's name (the iPhone app passes UIDevice's; the Mac uses its
    ///   computer name).
    public static func ref(name: String? = nil, defaults: UserDefaults = .standard,
                           env: [String: String] = ProcessInfo.processInfo.environment) -> DeviceRef {
        // PIXL_DEVICE_ID / PIXL_DEVICE_NAME: a second copy of the app on one Mac (tests, demos)
        if let id = env["PIXL_DEVICE_ID"] { return DeviceRef(deviceId: id, deviceName: env["PIXL_DEVICE_NAME"] ?? id) }
        let key = "PixlMemory.deviceId"
        let id = defaults.string(forKey: key) ?? {
            let new = UUID().uuidString
            defaults.set(new, forKey: key)
            return new
        }()
        #if os(macOS)
        let fallback = Host.current().localizedName ?? "This Mac"
        #else
        let fallback = "iPhone"
        #endif
        return DeviceRef(deviceId: id, deviceName: name ?? fallback)
    }
}
