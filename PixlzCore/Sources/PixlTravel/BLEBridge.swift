#if os(macOS) || os(iOS)
@preconcurrency import CoreBluetooth
import Foundation
import Network
import PixlzCore

/// The Bluetooth LE link to a Mosaico (D21). It finds a Mosaico advertising the Pixlz service,
/// connects, and offers it as a local TCP port: the transport then reaches the Mosaico at
/// 127.0.0.1:port exactly as over Wi-Fi, so trips, the feed, agents and pairing don't change.
/// The first bytes sent are a hello with this Mac's id, name and clock (the Mosaico may have no
/// Wi-Fi, so no time server). Same service as mosaico/pixlz_dock/components/app_ble.
public final class BLEBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    nonisolated(unsafe) public static let service = CBUUID(string: "6E1B0001-8F3C-4C6A-9B1E-70697868C0DE")
    static let rxUUID = CBUUID(string: "6E1B0002-8F3C-4C6A-9B1E-70697868C0DE")
    static let txUUID = CBUUID(string: "6E1B0003-8F3C-4C6A-9B1E-70697868C0DE")
    static let infoUUID = CBUUID(string: "6E1B0004-8F3C-4C6A-9B1E-70697868C0DE")

    /// The Mosaico is reachable at 127.0.0.1:port (main queue).
    public var onLink: ((DeviceRef, UInt16) -> Void)?
    /// The link is gone (main queue).
    public var onUnlink: ((String) -> Void)?
    public var onState: ((String) -> Void)?

    private let me: DeviceRef
    private let queue = DispatchQueue(label: "pixl.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var device: DeviceRef?
    private var listener: NWListener?
    private var client: NWConnection?
    private var outbox = Data()        // bytes for the Mosaico, written one chunk at a time
    /// Bytes from the Mosaico while no transport connection is attached, sent on the next one.
    private var inbox = Data()
    static let inboxLimit = 64 * 1024
    private var writing = false
    private var said = false           // the hello went out on this link

    public init(me: DeviceRef) {
        self.me = me
        super.init()
    }

    public func start() {
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func log(_ s: String) { DispatchQueue.main.async { self.onState?(s) } }

    // MARK: finding and connecting

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("bluetooth \(c.state == .poweredOn ? "on" : "not available (\(c.state.rawValue))")")
        if c.state == .poweredOn { scan() }
    }

    private func scan() {
        guard peripheral == nil, central.state == .poweredOn else { return }
        // A Mosaico this Mac connected to before may already be known to the system.
        if let known = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            connect(known)
            return
        }
        central.scanForPeripherals(withServices: [Self.service])
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        log("bluetooth: found \(p.name ?? "a Mosaico") (\(rssi) dBm)")
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("bluetooth: connected to \(p.name ?? "?")")
        p.discoverServices([Self.service])
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        reset(retry: true)
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("bluetooth: link closed")
        reset(retry: true)
    }

    private func reset(retry: Bool) {
        let gone = device?.deviceId
        client?.cancel(); client = nil
        listener?.cancel(); listener = nil
        peripheral = nil; rx = nil; device = nil
        outbox.removeAll(); inbox.removeAll(); writing = false; said = false
        if let gone { DispatchQueue.main.async { self.onUnlink?(gone) } }
        if retry { queue.asyncAfter(deadline: .now() + 2) { self.scan() } }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { reset(retry: true); return }
        p.discoverCharacteristics([Self.rxUUID, Self.txUUID, Self.infoUUID], for: s)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            switch ch.uuid {
            case Self.rxUUID: rx = ch
            case Self.txUUID: p.setNotifyValue(true, for: ch)
            case Self.infoUUID: p.readValue(for: ch)
            default: break
            }
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        if ch.uuid == Self.infoUUID {
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: String], let id = o["id"] else { return }
            device = DeviceRef(deviceId: id, deviceName: o["name"] ?? id)
            openListener()
        } else if ch.uuid == Self.txUUID {
            if let client {
                client.send(content: data, completion: .contentProcessed { _ in })
            } else if inbox.count + data.count <= Self.inboxLimit {
                inbox.append(data)   // the transport reconnects soon: keep it for then
            } else {
                log("bluetooth: \(inbox.count + data.count) bytes waiting with no connection; dropping")
                inbox.removeAll()
            }
        }
    }

    // MARK: the local port

    private func openListener() {
        guard listener == nil, let device else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self] st in
            guard let self, case .ready = st, let port = l.port?.rawValue else { return }
            self.log("bluetooth: \(device.deviceName) reachable at 127.0.0.1:\(port)")
            DispatchQueue.main.async { self.onLink?(device, port) }
        }
        l.start(queue: queue)
        listener = l
    }

    /// The transport connected to the local port: its bytes go to the Mosaico, the Mosaico's
    /// come back. One connection at a time; a new one replaces the old.
    private func accept(_ c: NWConnection) {
        client?.cancel()
        // a previous connection's unsent bytes (maybe half a frame) would garble the new one's
        if said { outbox.removeAll() }
        client = c
        c.start(queue: queue)
        if !inbox.isEmpty {
            c.send(content: inbox, completion: .contentProcessed { _ in })
            inbox.removeAll()
        }
        if !said {
            said = true
            let hello: [String: Any] = ["hello": ["deviceId": me.deviceId, "deviceName": me.deviceName,
                                                  "unixMs": Int64(Date().timeIntervalSince1970 * 1000)]]
            if let body = try? JSONSerialization.data(withJSONObject: hello) {
                var n = UInt32(body.count).bigEndian
                write(Data(bytes: &n, count: 4) + body)
            }
        }
        pump(c)
    }

    private func pump(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, self.client === c else { return }
            if let data, !data.isEmpty { self.write(data) }
            if done || error != nil { c.cancel(); if self.client === c { self.client = nil }; return }
            self.pump(c)
        }
    }

    private func write(_ data: Data) {
        outbox.append(data)
        writeNext()
    }

    /// Writes with response, one chunk at a time: ordered and acknowledged.
    private func writeNext() {
        guard !writing, !outbox.isEmpty, let p = peripheral, let rx else { return }
        let n = min(outbox.count, max(20, p.maximumWriteValueLength(for: .withResponse)))
        writing = true
        p.writeValue(outbox.prefix(n), for: rx, type: .withResponse)
        outbox.removeFirst(n)
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        writing = false
        if let error {
            log("bluetooth: write failed (\(error.localizedDescription)); dropping the link")
            central.cancelPeripheralConnection(p)
            return
        }
        writeNext()
    }
}
#endif
