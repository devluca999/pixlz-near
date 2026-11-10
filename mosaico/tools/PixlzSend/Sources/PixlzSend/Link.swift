import Foundation
import Network
import PixlzCore

/// The spike's first frame each way (SPEC §10.3): who's on the other end, before any envelope.
struct Hello: Codable {
    struct Body: Codable {
        var deviceId: String
        var deviceName: String
    }

    var hello: Body
}

/// One TCP connection to a Mosaico, driving a `TravelNode` over PixlzCore's Framing.
/// Everything runs on `queue`.
final class Link: @unchecked Sendable {
    let queue = DispatchQueue(label: "pixlz.link")
    private let conn: NWConnection
    private let store: FilePetStore
    private(set) var node: TravelNode
    private(set) var peer: DeviceRef?
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var closed = false

    /// The Mosaico said hello.
    var onPeer: ((DeviceRef) -> Void)?
    /// Exit, entrance and shrug outputs, after saving and sending are done.
    var onOutput: ((TravelNode.Output) -> Void)?
    var onClosed: ((String) -> Void)?

    init(to endpoint: NWEndpoint, me: DeviceRef, store: FilePetStore) throws {
        self.store = store
        node = TravelNode(me: me, record: try store.load())
        conn = NWConnection(to: endpoint, using: .tcp)
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sayHello()
                self.receive()
            case .failed(let e): self.close("connection failed: \(e)")
            case .waiting(let e): self.close("can't reach the Mosaico: \(e)")
            case .cancelled: self.close("closed")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func cancel() { conn.cancel() }

    /// Feeds one input to the node and performs its outputs in order (a save before any later send).
    func feed(_ input: TravelNode.Input) {
        for output in node.handle(input, at: Date()) {
            switch output {
            case .saved(let record):
                do { try store.save(record) } catch {
                    log("couldn't save: \(error); stopping before anything else is sent")
                    close("save failed")
                    return
                }
            case .send(let env, _):
                do { sendFrame(try Framing.encode(env)) } catch { log("couldn't encode \(env.type): \(error)") }
            default:
                onOutput?(output)
            }
        }
        armTimer()
    }

    // MARK: Wire

    private func sayHello() {
        let me = node.me
        guard let body = try? JSONEncoder().encode(Hello(hello: .init(deviceId: me.deviceId, deviceName: me.deviceName))) else { return }
        var length = UInt32(body.count).bigEndian
        sendFrame(Data(bytes: &length, count: 4) + body)
    }

    private func sendFrame(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.close("send failed: \(error)") }
        })
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.take(data) }
            if let error { self.close("receive failed: \(error)"); return }
            if done { self.close("the Mosaico hung up"); return }
            self.receive()
        }
    }

    private func take(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
            guard length <= Framing.maxFrame else { close("frame too large"); return }
            guard buffer.count >= 4 + length else { return }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            handle(body)
        }
    }

    private func handle(_ body: Data) {
        guard let peer else {
            guard let hello = try? JSONDecoder().decode(Hello.self, from: body) else {
                close("the first frame wasn't a hello")
                return
            }
            let p = DeviceRef(deviceId: hello.hello.deviceId, deviceName: hello.hello.deviceName)
            self.peer = p
            onPeer?(p)
            return
        }
        do {
            let env = try PetState.decoder.decode(Envelope.self, from: body)
            log("← \(env.type.rawValue) epoch \(env.epoch)")
            feed(.received(env, from: peer))
        } catch {
            log("couldn't decode an envelope: \(error)")
        }
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard let deadline = node.nextDeadline else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow) + 0.05)
        t.setEventHandler { [weak self] in self?.feed(.tick) }
        t.resume()
        timer = t
    }

    private func close(_ why: String) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        conn.cancel()
        onClosed?(why)
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[pixlz] \(s)\n".utf8))
}
