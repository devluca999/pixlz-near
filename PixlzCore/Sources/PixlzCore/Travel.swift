import Foundation

/// The trip protocol for one device (SPEC §10.4–§10.5), as a pure state machine.
///
/// `record` is what's on disk; `session` is in memory and lost on a crash. The platform layer feeds
/// inputs and performs the outputs **in order**: a `.saved` output must be persisted before any
/// `.send` after it, which is what keeps at least one complete copy of the Pixl on some device.
/// Devices are always compared by `deviceId` (a renamed device is the same device).
public struct TravelNode: Sendable {
    /// From `offer` to `ack` (SPEC §10.4).
    public static let senderTimeout: TimeInterval = 8
    /// A little longer than the sender's, so the sender's `abort` normally arrives first.
    public static let receiverTimeout: TimeInterval = 10
    /// A `statusReply` is accepted only from a device we sent `status` to this recently.
    public static let askWindow: TimeInterval = 60

    public enum Input: Sendable {
        /// "Send to <device>" or the portal hole.
        case send(to: DeviceRef)
        /// "Call Frogg" from a device that doesn't have it.
        case call(owner: DeviceRef)
        case received(Envelope, from: DeviceRef)
        /// A paired peer became reachable (or it's time to check again): ask it with `status`.
        case connected(DeviceRef)
        /// The timer for `nextDeadline` fired.
        case tick
        /// The user brings the Pixl back while the device holding it is off or out of reach: restore
        /// the safety copy (the tombstone) here, two epochs up. When that device returns, the status
        /// exchange makes it give way (higher epoch wins, SPEC §10.5). Time it spent there is lost.
        case reclaim
    }

    public enum Output: Equatable, Sendable {
        case send(Envelope, to: DeviceRef)
        /// Persist this before performing any later output.
        case saved(StoredPet)
        /// Committed (or this copy gave way): play the exit toward `to`.
        case playExit(to: DeviceRef)
        /// The Pixl is now owned here: play the entrance.
        case playEntrance
        /// The trip didn't happen; the Pixl stays (annoyed shrug).
        case shrug(reason: String)
    }

    enum SendPhase: Sendable, Equatable {
        case offered(epoch: Int)
        case transferred(PetState, checksum: String)
        case committed(epoch: Int)
    }

    enum Session: Sendable, Equatable {
        case sending(peer: DeviceRef, phase: SendPhase, deadline: Date)
        case receiving(peer: DeviceRef, petId: UUID, epoch: Int, deadline: Date)

        var peer: DeviceRef {
            switch self {
            case .sending(let p, _, _), .receiving(let p, _, _, _): p
            }
        }
    }

    public let me: DeviceRef
    public private(set) var record: StoredPet?
    /// iOS: the app is in the foreground. The Mac can always host.
    public var canHost = true
    public var knownSpecies: Set<String> = ["frogg"]
    private(set) var session: Session?
    /// When we last sent `status` to each device (by id): only those may answer.
    private var asked: [String: Date] = [:]
    /// Devices that asked while we were mid-trip: ask them back once the trip ends.
    private var askAfterTrip: [DeviceRef] = []

    public init(me: DeviceRef, record: StoredPet?) {
        self.me = me
        self.record = record
    }

    /// True while a trip is in progress (drives the "…" bubble and, after 1.5 s, the silhouette).
    public var inTrip: Bool { session != nil }

    /// The device on the other end of the trip in progress.
    public var sessionPeer: DeviceRef? { session?.peer }

    /// When to deliver the next `.tick`. Nil = no timer needed.
    public var nextDeadline: Date? {
        switch session {
        case .sending(_, _, let d), .receiving(_, _, _, let d): d
        case nil: nil
        }
    }

    /// The process died: everything in memory is gone, the record on disk stays.
    public mutating func crash() {
        session = nil
        asked = [:]
        askAfterTrip = []
    }

    /// A save failed: drop the trip in progress (send its peer `abort` with `reason`) and go back
    /// to `reload`, the record that's actually on disk.
    public mutating func abandon(reload: StoredPet?, reason: String, at now: Date) -> [Output] {
        var out: [Output] = []
        switch session {
        case .sending(let p, let phase, _):
            let id: UUID?, e: Int
            switch phase {
            case .offered(let ep), .committed(let ep): id = record?.petId ?? reload?.petId; e = ep
            case .transferred(let next, _): id = next.petId; e = next.epoch
            }
            if let id {
                out.append(.send(envelope(.abort, to: p, petId: id, epoch: e, payload: Payload(reason: reason), at: now), to: p))
            }
        case .receiving(let p, let id, let e, _):
            out.append(.send(envelope(.abort, to: p, petId: id, epoch: e, payload: Payload(reason: reason), at: now), to: p))
        case nil:
            break
        }
        session = nil
        askAfterTrip = []
        record = reload
        return out
    }

    public mutating func handle(_ input: Input, at now: Date) -> [Output] {
        let wasInTrip = session != nil
        var out = handleInput(input, at: now)
        // the trip just ended: ask the devices that asked meanwhile
        if wasInTrip, session == nil, !askAfterTrip.isEmpty {
            let waiting = askAfterTrip
            askAfterTrip = []
            if let r = record {
                for p in waiting { out.append(ask(p, petId: r.petId, epoch: r.epoch, at: now)) }
            }
        }
        return out
    }

    private func same(_ a: DeviceRef, _ b: DeviceRef) -> Bool { a.deviceId == b.deviceId }

    /// `status` to `peer`, remembered so its reply is accepted.
    private mutating func ask(_ peer: DeviceRef, petId: UUID, epoch: Int, at now: Date) -> Output {
        asked[peer.deviceId] = now
        return .send(envelope(.status, to: peer, petId: petId, epoch: epoch, at: now), to: peer)
    }

    private func recentlyAsked(_ peer: DeviceRef, at now: Date) -> Bool {
        guard let t = asked[peer.deviceId] else { return false }
        return now >= t && now.timeIntervalSince(t) <= Self.askWindow
    }

    private mutating func handleInput(_ input: Input, at now: Date) -> [Output] {
        switch input {
        case .send(let peer): return startTrip(to: peer, at: now)
        case .call(let owner):
            guard let r = record, !r.isOwned else { return [] }
            return [.send(envelope(.call, to: owner, petId: r.petId, epoch: r.epoch, at: now), to: owner)]
        case .received(let env, let peer):
            guard env.v == Envelope.version, env.to == me.deviceId, env.from == peer.deviceId else { return [] }
            return receive(env, from: peer, at: now)
        case .connected(let peer):
            guard let r = record else { return [] }
            return [ask(peer, petId: r.petId, epoch: r.epoch, at: now)]
        case .tick: return tick(at: now)
        case .reclaim: return reclaim(at: now)
        }
    }

    // MARK: Sender

    private mutating func startTrip(to peer: DeviceRef, at now: Date) -> [Output] {
        guard case .owned(let s) = record else { return [] }
        guard session == nil else { return [.shrug(reason: "busy")] }
        session = .sending(peer: peer, phase: .offered(epoch: s.epoch), deadline: now.addingTimeInterval(Self.senderTimeout))
        return [.send(envelope(.offer, to: peer, petId: s.petId, epoch: s.epoch,
                               payload: Payload(species: s.species, name: s.name), at: now), to: peer)]
    }

    private mutating func abortTrip(_ peer: DeviceRef, petId: UUID, epoch: Int, reason: String, at now: Date) -> [Output] {
        session = nil
        return [.send(envelope(.abort, to: peer, petId: petId, epoch: epoch, payload: Payload(reason: reason), at: now), to: peer),
                .shrug(reason: reason)]
    }

    // MARK: Messages

    private mutating func receive(_ env: Envelope, from peer: DeviceRef, at now: Date) -> [Output] {
        switch env.type {
        case .call:
            guard case .owned(let s) = record, s.petId == env.petId else { return [] }
            return startTrip(to: peer, at: now)

        case .offer:
            if let reason = declineReason(env) {
                return [.send(envelope(.decline, to: peer, petId: env.petId, epoch: env.epoch,
                                       payload: Payload(reason: reason.rawValue), at: now), to: peer)]
            }
            session = .receiving(peer: peer, petId: env.petId, epoch: env.epoch + 1, deadline: now.addingTimeInterval(Self.receiverTimeout))
            return [.send(envelope(.accept, to: peer, petId: env.petId, epoch: env.epoch, at: now), to: peer)]

        case .accept:
            guard case .sending(let p, .offered(let e), let deadline) = session, same(p, peer), env.epoch == e,
                  case .owned(let s) = record, s.petId == env.petId else { return [] }
            var next = s
            next.epoch = e + 1
            next.owner = peer
            next.stats.trips += 1
            next.savedAt = now
            guard let sum = try? next.checksum() else {
                return abortTrip(peer, petId: s.petId, epoch: e, reason: "encodingFailed", at: now)
            }
            session = .sending(peer: peer, phase: .transferred(next, checksum: sum), deadline: deadline)
            return [.send(envelope(.transfer, to: peer, petId: s.petId, epoch: next.epoch, payload: Payload(state: next), at: now), to: peer)]

        case .decline:
            guard case .sending(let p, .offered(let e), _) = session, same(p, peer), env.epoch == e else { return [] }
            let reason = env.payload.reason ?? DeclineReason.userDeclined.rawValue
            var out = abortTrip(peer, petId: env.petId, epoch: e, reason: reason, at: now)
            // It's already there: two copies. Ask, so the older one steps aside (here or there).
            if reason == DeclineReason.alreadyHere.rawValue, let r = record {
                out.append(ask(peer, petId: r.petId, epoch: r.epoch, at: now))
            }
            return out

        case .transfer:
            guard case .receiving(let p, _, let e, _) = session, same(p, peer), env.epoch == e else { return [] }
            guard let st = env.payload.state, st.petId == env.petId, st.epoch == e, st.owner.deviceId == me.deviceId,
                  let sum = try? st.checksum() else {
                session = nil
                return [.send(envelope(.abort, to: peer, petId: env.petId, epoch: env.epoch, payload: Payload(reason: "badTransfer"), at: now), to: peer)]
            }
            // a Pixl this device can't show (the offer named another species)
            guard knownSpecies.contains(st.species) else {
                session = nil
                return [.send(envelope(.abort, to: peer, petId: env.petId, epoch: env.epoch,
                                       payload: Payload(reason: DeclineReason.unsupportedSpecies.rawValue), at: now), to: peer)]
            }
            record = .pendingArrival(st, from: peer)
            return [.saved(record!),
                    .send(envelope(.ack, to: peer, petId: st.petId, epoch: e, payload: Payload(checksum: sum), at: now), to: peer)]

        case .ack:
            guard case .sending(let p, .transferred(let next, let sum), let deadline) = session, same(p, peer),
                  env.epoch == next.epoch else { return [] }
            guard env.payload.checksum == sum else {
                return abortTrip(peer, petId: next.petId, epoch: next.epoch, reason: "checksumMismatch", at: now)
            }
            record = .away(petId: next.petId, epoch: next.epoch, ownerName: peer.deviceName, ownerId: peer.deviceId, tombstone: next)
            session = .sending(peer: peer, phase: .committed(epoch: next.epoch), deadline: deadline.addingTimeInterval(Self.senderTimeout))
            return [.saved(record!),
                    .send(envelope(.commit, to: peer, petId: next.petId, epoch: next.epoch, at: now), to: peer),
                    .playExit(to: peer)]

        case .commit:
            // only from the device we're receiving from
            guard case .receiving(let p, _, _, _) = session, same(p, peer) else { return [] }
            return promote(epoch: env.epoch, petId: env.petId, from: peer, at: now)

        case .commitAck:
            if case .sending(let p, .committed(let e), _) = session, same(p, peer), e == env.epoch { session = nil }
            return []

        case .abort:
            // only from the device we're in a trip with
            guard let s = session, same(s.peer, peer) else { return [] }
            switch s {
            case .receiving:
                session = nil
                if case .pendingArrival(let st, _) = record, st.petId == env.petId, st.epoch == env.epoch || st.epoch == env.epoch + 1 {
                    return discardPending(st, from: peer)
                }
                return []
            case .sending(_, .committed, _):
                return []
            case .sending:
                session = nil
                return [.shrug(reason: env.payload.reason ?? "aborted")]
            }

        case .status:
            var reply = Payload(held: HeldKind.none, inTrip: inTrip)
            var epoch = 0
            if let r = record, r.petId == env.petId {
                epoch = r.epoch
                switch r {
                case .owned: reply.held = .owned
                case .pendingArrival: reply.held = .pending
                case .away(_, _, let name, let id, _):
                    reply.held = .away
                    reply.holderId = id
                    reply.holderName = name
                }
            }
            var out: [Output] = [.send(envelope(.statusReply, to: peer, petId: env.petId, epoch: epoch, payload: reply, at: now), to: peer)]
            // The asker's copy is as new as ours or newer: ask back, so its answer can settle who
            // has the Pixl here too (a device that only answers would never tell us). Not when we
            // just asked it (no ping-pong); mid-trip, as soon as the trip ends.
            if let r = record, r.petId == env.petId, env.epoch >= r.epoch, !recentlyAsked(peer, at: now) {
                if session == nil {
                    out.append(ask(peer, petId: r.petId, epoch: r.epoch, at: now))
                } else if !askAfterTrip.contains(where: { same($0, peer) }) {
                    askAfterTrip.append(peer)
                }
            }
            return out

        case .statusReply:
            return reconcile(env, from: peer, at: now)
        }
    }

    private func declineReason(_ env: Envelope) -> DeclineReason? {
        if !canHost || session != nil { return .busy }
        if !knownSpecies.contains(env.payload.species ?? "") { return .unsupportedSpecies }
        switch record {
        case nil: return nil
        case .owned(let s): return s.petId == env.petId ? .alreadyHere : .hasOtherPet
        case .pendingArrival: return .busy
        case .away(let id, let e, _, _, _):
            if id != env.petId { return .hasOtherPet }
            return env.epoch < e ? .busy : nil   // a stale offer; status will sort it out
        }
    }

    /// pending → owned, on `commit` or on a status reply showing the sender committed.
    private mutating func promote(epoch: Int, petId: UUID, from peer: DeviceRef, at now: Date) -> [Output] {
        let ack = Output.send(envelope(.commitAck, to: peer, petId: petId, epoch: epoch, at: now), to: peer)
        switch record {
        case .pendingArrival(let st, _) where st.petId == petId && st.epoch == epoch:
            var s = st
            s.needs.record(.travel, at: now)
            s.needs.record(.callOrReceive, at: now)
            s.emotion = EmotionState(kind: .happy, until: now.addingTimeInterval(Emotion.happy.duration!))
            s.savedAt = now
            record = .owned(s)
            if case .receiving(let p, _, _, _) = session, same(p, peer) { session = nil }
            return [.saved(record!), ack, .playEntrance]
        case .owned(let s) where s.petId == petId && s.epoch == epoch:
            return [ack]   // duplicate commit
        default:
            return []
        }
    }

    private mutating func discardPending(_ st: PetState, from peer: DeviceRef) -> [Output] {
        record = .away(petId: st.petId, epoch: st.epoch - 1, ownerName: peer.deviceName, ownerId: peer.deviceId, tombstone: nil)
        return [.saved(record!)]
    }

    /// Status reconciliation (SPEC §10.4 failure table, §10.5 conflicts).
    private mutating func reconcile(_ env: Envelope, from peer: DeviceRef, at now: Date) -> [Output] {
        // only answers to our own asks
        guard recentlyAsked(peer, at: now) else { return [] }
        guard let r = record, r.petId == env.petId, let held = env.payload.held else { return [] }
        let peerEpoch = env.epoch, peerInTrip = env.payload.inTrip ?? false
        switch r {
        case .pendingArrival(let st, let from):
            // only the device it came from can settle it
            if let from, !same(from, peer) { return [] }
            switch held {
            case .away where peerEpoch == st.epoch:
                return promote(epoch: st.epoch, petId: st.petId, from: peer, at: now)
            case .owned where peerEpoch < st.epoch && !peerInTrip:
                if case .receiving(let p, _, _, _) = session, same(p, peer) { session = nil }
                return discardPending(st, from: peer)
            case .none:
                // The sender has nothing: ours is the only copy.
                if case .receiving(let p, _, _, _) = session, same(p, peer) { session = nil }
                record = .owned(st)
                return [.saved(record!), .playEntrance]
            default:
                return []
            }

        case .away(let id, let e, _, _, let tombstone):
            guard let t = tombstone, same(t.owner, peer) else { return [] }
            switch held {
            case .pending where peerEpoch == e:
                return [.send(envelope(.commit, to: peer, petId: id, epoch: e, at: now), to: peer)]
            case .none, .away:
                // The receiver never got it (it holds nothing, or only an older away record):
                // come home from the safety copy.
                guard held == .none || peerEpoch <= e else { return [] }
                var restored = t
                restored.epoch = e + 1
                restored.owner = me
                restored.savedAt = now
                record = .owned(restored)
                session = nil
                return [.saved(record!), .playEntrance]
            default:
                return []
            }

        case .owned(let s):
            let newer = (held == .owned || held == .away) && peerEpoch > s.epoch
            let tie = held == .owned && peerEpoch == s.epoch && peer.deviceId < me.deviceId
            guard newer || tie else { return [] }
            // where it is: the device the peer says it went to, or the peer itself
            var holder = peer
            if held == .away, let hid = env.payload.holderId, !hid.isEmpty {
                holder = DeviceRef(deviceId: hid, deviceName: env.payload.holderName ?? hid)
            }
            guard !same(holder, me) else { return [] }
            // the copy that lost is stale: no tombstone, so it can never be brought back
            record = .away(petId: s.petId, epoch: peerEpoch, ownerName: holder.deviceName, ownerId: holder.deviceId, tombstone: nil)
            session = nil
            return [.saved(record!), .playExit(to: holder)]   // it's there, not here: leave the screen
        }
    }

    // MARK: Reclaim

    /// Whether `reclaim` can bring the Pixl back: it's away and this device kept its safety copy.
    public var canReclaim: Bool {
        if case .away(_, _, _, _, _?)? = record, session == nil { return true }
        return false
    }

    /// The Pixl here becomes another species (a swap): it travels as that one from now on.
    /// Only while it's here and not mid-trip.
    public mutating func restyle(species: String, name: String, at now: Date) -> [Output] {
        guard session == nil, case .owned(var s)? = record, s.species != species || s.name != name else { return [] }
        s.species = species
        s.name = name
        s.savedAt = now
        record = .owned(s)
        return [.saved(record!)]
    }

    private mutating func reclaim(at now: Date) -> [Output] {
        guard session == nil, case .away(_, let e, _, _, let tombstone?)? = record else { return [] }
        var restored = tombstone
        restored.epoch = e + 2       // above the holder's epoch, even after one more hop it made
        restored.owner = me
        restored.savedAt = now
        record = .owned(restored)
        return [.saved(record!), .playEntrance]
    }

    // MARK: Timers

    private mutating func tick(at now: Date) -> [Output] {
        guard let deadline = nextDeadline, now >= deadline, let session else { return [] }
        switch session {
        case .sending(let peer, .offered(let e), _):
            guard let id = record?.petId else { self.session = nil; return [] }
            return abortTrip(peer, petId: id, epoch: e, reason: "timeout", at: now)
        case .sending(let peer, .transferred(let next, _), _):
            return abortTrip(peer, petId: next.petId, epoch: next.epoch, reason: "timeout", at: now)
        case .sending(_, .committed, _):
            // No commitAck: stay away; the next status exchange settles it.
            self.session = nil
            return []
        case .receiving(let peer, _, _, _):
            self.session = nil
            if case .pendingArrival(let st, _) = record {
                return [ask(peer, petId: st.petId, epoch: st.epoch, at: now)]
            }
            return []
        }
    }

    private func envelope(_ type: EnvelopeType, to peer: DeviceRef, petId: UUID, epoch: Int,
                          payload: Payload = Payload(), at now: Date) -> Envelope {
        Envelope(petId: petId, from: me.deviceId, to: peer.deviceId, type: type, epoch: epoch, payload: payload, sentAt: now)
    }
}
