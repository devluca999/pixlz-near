import Foundation
import Network
import PixlzCore

// pixlz-send: the Mac half of the Mosaico spike (D17). Plain TCP, no pairing: spike only.
//
//   PixlzSend send   [--host H] [--port P]   send Frogg to a Mosaico, exit when he's there
//   PixlzSend dock   [--host H] [--port P]   stay connected; catch Frogg when he comes home
//   PixlzSend status                          what this Mac holds
//   PixlzSend fixtures <dir>                  write PixlzCore's bytes for the C host tests
//
// State lives in ~/Library/Application Support/PixlzDock (a FilePetStore), separate from the app.

let usage = """
usage: PixlzSend send|dock [--host H] [--port P]
       PixlzSend status
       PixlzSend fixtures <dir>
"""

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("PixlzDock", isDirectory: true)

func thisMac() throws -> DeviceRef {
    let env = ProcessInfo.processInfo.environment
    if let id = env["PIXL_DEVICE_ID"] { return DeviceRef(deviceId: id, deviceName: env["PIXL_DEVICE_NAME"] ?? id) }
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    let file = supportDir.appendingPathComponent("device.json")
    if let data = try? Data(contentsOf: file), let ref = try? JSONDecoder().decode(DeviceRef.self, from: data) { return ref }
    let ref = DeviceRef(deviceId: UUID().uuidString, deviceName: Host.current().localizedName ?? "Mac")
    try JSONEncoder().encode(ref).write(to: file, options: .atomic)
    return ref
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func describe(_ record: StoredPet?) -> String {
    switch record {
    case nil: "no Pixl yet"
    case .owned(let s)?: "\(s.name) is here (epoch \(s.epoch), \(s.stats.trips) trips)"
    case .pendingArrival(let s)?: "\(s.name) is arriving (epoch \(s.epoch))"
    case .away(_, let e, let name, _)?: "away on \(name) (epoch \(e))"
    }
}

/// Resolves the endpoint (fixed or by Bonjour), then calls `then` on the main queue.
func endpoint(_ args: [String], then: @escaping (NWEndpoint) -> Void) {
    if let host = option("--host", in: args) {
        let port = option("--port", in: args).flatMap(UInt16.init) ?? Discovery.defaultPort
        then(.hostPort(host: .init(host), port: .init(rawValue: port)!))
        return
    }
    log("looking for a Mosaico on the network…")
    Discovery.findMosaico(timeout: 10, queue: .main) { e in
        guard let e else { log("no Mosaico found (is it plugged in and on this Wi-Fi?)"); exit(2) }
        then(e)
    }
}

// MARK: Commands

func runSend(_ args: [String], me: DeviceRef, store: FilePetStore) throws {
    if try store.load() == nil {
        try store.save(.owned(PetState(species: "frogg", name: "Frogg", owner: me, at: Date())))
        log("adopted Frogg on this Mac")
    }
    guard case .owned? = try store.load() else {
        log(describe(try store.load()))
        exit(1)
    }
    endpoint(args) { ep in
        guard let link = try? Link(to: ep, me: me, store: store) else { exit(1) }
        var exited = false
        link.onPeer = { peer in
            log("connected to \(peer.deviceName); sending Frogg")
            link.feed(.send(to: peer))
        }
        link.onOutput = { out in
            switch out {
            case .playExit(let to):
                exited = true
                log("committed: Frogg hops off toward \(to.deviceName)")
            case .shrug(let reason):
                log("Frogg stays (\(reason))")
                exit(1)
            default: break
            }
            if exited, !link.node.inTrip { done(link) }
        }
        link.onClosed = { why in
            log(why)
            exit(exited ? 0 : 1)
        }
        // commitAck clears the trip; poll the node briefly after the exit.
        func done(_ link: Link) {
            log(describe(link.node.record))
            exit(0)
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            link.queue.async { if exited, !link.node.inTrip { DispatchQueue.main.async { done(link) } } }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in log("timed out"); exit(1) }
        link.start()
    }
    RunLoop.main.run()
}

func runDock(_ args: [String], me: DeviceRef, store: FilePetStore) {
    func connect() {
        endpoint(args) { ep in
            guard let link = try? Link(to: ep, me: me, store: store) else { exit(1) }
            link.onPeer = { peer in
                log("docked with \(peer.deviceName). \(describe(link.node.record))")
                link.feed(.connected(peer))
            }
            link.onOutput = { out in
                switch out {
                case .playEntrance: log("Frogg is home! \(describe(link.node.record))")
                case .playExit(let to): log("Frogg left for \(to.deviceName)")
                case .shrug(let r): log("trip didn't happen (\(r))")
                default: break
                }
            }
            link.onClosed = { why in
                log("\(why); reconnecting in 3 s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { connect() }
            }
            link.start()
            current = link
        }
    }
    connect()
    RunLoop.main.run()
}

nonisolated(unsafe) var current: Link?

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "send":
        try runSend(args, me: thisMac(), store: FilePetStore(directory: supportDir))
    case "dock":
        runDock(args, me: try thisMac(), store: FilePetStore(directory: supportDir))
    case "status":
        print(describe(try FilePetStore(directory: supportDir).load()))
    case "fixtures":
        guard args.count == 2 else { print(usage); exit(64) }
        try Fixtures.write(to: URL(fileURLWithPath: args[1]))
        print("wrote fixtures to \(args[1])")
    default:
        print(usage)
        exit(64)
    }
} catch {
    log("\(error)")
    exit(1)
}
