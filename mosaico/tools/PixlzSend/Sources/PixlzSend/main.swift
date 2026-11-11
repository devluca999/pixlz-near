import Foundation
import Network
import PixlTravel
import PixlzCore

// pixlz-send: the Mac half of the Mosaico spike (D17). Plain TCP, no pairing: spike only.
//
//   PixlzSend send   [--host H] [--port P]   send Frogg to a Mosaico, exit when he's there
//   PixlzSend dock   [--host H] [--port P]   stay connected; catch Frogg when he comes home
//   PixlzSend call   [--host H] [--port P]   ask the Mosaico to send him home now
//   PixlzSend feed   [--host H] [--port P]   send sample Answers and Memory to the Mosaico
//   PixlzSend status                          what this Mac holds
//   PixlzSend fixtures <dir>                  write PixlzCore's bytes for the C host tests
//
// State lives in ~/Library/Application Support/PixlzDock (a FilePetStore), separate from the app.

let usage = """
usage: PixlzSend send|dock|call|feed [--host H] [--port P]
       PixlzSend status
       PixlzSend fixtures <dir>
"""

/// PIXLZ_DOCK_DIR overrides it (tests).
let supportDir = ProcessInfo.processInfo.environment["PIXLZ_DOCK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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

/// The last Mosaico address that answered, for networks that drop multicast (Bonjour).
let lastHostFile = supportDir.appendingPathComponent("last-mosaico.txt")

func rememberHost(_ endpoint: NWEndpoint) {
    guard case .hostPort(let host, let port) = endpoint else { return }
    let text = "\(host) \(port.rawValue)".replacingOccurrences(of: "%", with: " ").split(separator: " ")
    guard text.count >= 2 else { return }
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    try? "\(text[0]) \(text.last!)".write(to: lastHostFile, atomically: true, encoding: .utf8)
}

func lastHost() -> NWEndpoint? {
    guard let text = try? String(contentsOf: lastHostFile, encoding: .utf8) else { return nil }
    let parts = text.split(separator: " ")
    guard parts.count == 2, let port = UInt16(parts[1]), let p = NWEndpoint.Port(rawValue: port) else { return nil }
    return .hostPort(host: .init(String(parts[0])), port: p)
}

/// Resolves the endpoint (--host, Bonjour, then the last address that worked) and calls `then`.
func endpoint(_ args: [String], then: @escaping (NWEndpoint) -> Void) {
    if let host = option("--host", in: args) {
        let port = option("--port", in: args).flatMap(UInt16.init) ?? Discovery.defaultPort
        then(.hostPort(host: .init(host), port: .init(rawValue: port)!))
        return
    }
    log("looking for a Mosaico on the network…")
    Discovery.findMosaico(timeout: 6, queue: .main) { e in
        if let e { then(e); return }
        if let last = lastHost() {
            log("Bonjour found nothing (this Wi-Fi may drop multicast); trying the last address, \(last)")
            then(last)
            return
        }
        log("no Mosaico found (is it plugged in and on this Wi-Fi?). Try --host <its IP> once.")
        exit(2)
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

/// "Call Frogg": the owner (the Mosaico) starts the trip home; exits when he's here.
func runCall(_ args: [String], me: DeviceRef, store: FilePetStore) throws {
    guard case .away? = try store.load() else {
        log(describe(try store.load()))
        exit(1)
    }
    endpoint(args) { ep in
        guard let link = try? Link(to: ep, me: me, store: store) else { exit(1) }
        link.onPeer = { peer in
            log("connected to \(peer.deviceName); calling Frogg home")
            link.feed(.call(owner: peer))
        }
        link.onOutput = { out in
            switch out {
            case .playEntrance:
                log("Frogg is home! \(describe(link.node.record))")
                exit(0)
            case .shrug(let reason):
                log("Frogg stays (\(reason))")
                exit(1)
            default: break
            }
        }
        link.onClosed = { why in log(why); exit(1) }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in log("timed out"); exit(1) }
        link.start()
    }
    RunLoop.main.run()
}

/// Sample Answers and Memory pages, for trying the Mosaico's reader without the Mac app.
func runFeed(_ args: [String], me: DeviceRef, store: FilePetStore) {
    endpoint(args) { ep in
        guard let link = try? Link(to: ep, me: me, store: store) else { exit(1) }
        link.onPeer = { peer in
            let body = MosaicoFeed.body(
                answers: [("Why are glass frogs see-through?",
                           "Their skin and muscles let light pass, and they hide most of their red blood cells in the liver while they sleep, so from below they almost vanish against a leaf."),
                          ("What should I pack for Lisbon?", "Comfy shoes for the hills, a light jacket for the wind by the river, and a small bag for pastel de nata.")],
                highlights: [("Glass frogs - National Geographic", "Glass frogs stash nearly 90% of their red blood cells in their livers while they sleep."),
                             ("Pixl Memory notes", "Pixls travel between devices; the Mosaico only shows results the Mac sends it."),
                             ("Recipe: pastel de nata", "Bake hot and fast: 290C for 8-10 minutes until the tops blister.")],
                from: me)
            link.sendBody(body)
            log("sent \(body.count) bytes of feed to \(peer.deviceName)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
        link.onClosed = { why in log(why); exit(1) }
        link.start()
    }
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
    case "call":
        try runCall(args, me: thisMac(), store: FilePetStore(directory: supportDir))
    case "feed":
        runFeed(args, me: try thisMac(), store: FilePetStore(directory: supportDir))
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
