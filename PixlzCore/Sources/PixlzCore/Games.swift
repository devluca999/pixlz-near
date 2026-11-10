import CoreGraphics
import Foundation

// The pet mini-games (Direction C16 · Games): the pet is the actor, you respond. Pure rules and
// timing, no drawing: the app feeds the clock and the cursor, and draws what these report.
// Coordinates are world points (top-left origin, y down). Timings follow the C16 timing sheet.

/// How a round ended, and its score.
public struct GameScore: Equatable, Sendable, Codable {
    public var seconds: Double
    public var count: Int          // bonks (Inevitable) or dodges (Snap)
    public init(seconds: Double, count: Int) { self.seconds = seconds; self.count = count }
}

// MARK: - Slugg · Inevitable

/// Slugg crawls toward the cursor without ever stopping; you keep moving, bonk him into his
/// shell, and try to last the round. He wins by touching the cursor.
public struct ChaseGame: Sendable {
    /// The timing sheet (art pixels at 1×; the app multiplies by the pet's scale).
    public struct Tuning: Sendable, Equatable {
        public var crawlStart = 14.0, crawlEnd = 22.0          // px/s, linear over the round
        public var closeBoost = 0.20                           // within `closeBodies` body lengths
        public var closeBodies = 2.0
        public var turnStart = 45.0, turnEnd = 70.0            // °/s; the body turns before it moves
        public var turnBeforeMove = 35.0                       // ° off target: barely moves until turned
        public var parkedAfter = 1.5, parkedSlow = 0.15        // cursor still: a smug, slower crawl
        public var shellStart = 3.0, shellEnd = 2.2            // s in the shell after a bonk
        public var wobble = 0.4                                // s coming back out
        public var cooldown = 1.5                              // s after coming out before another bonk counts
        public var bonkSpeedUp = 0.08                          // per bonk
        public var dangerBodies = 1.0                          // vignette radius
        public var gotchaRadius = 4.0                          // px from the cursor tip
        public var invite = 2.0, inviteCancel = 200.0          // s; pt the cursor may move away
        public var corner = 48.0                               // pt: a cursor this close to two edges is "parked in a corner"
        public var strideLength = 10.0                         // px per crawl cycle (8 frames)
        public var openSpeed = 0.5                             // off any surface: on his own slime strand
        public var surfaceGrip = 8.0                           // px: this close to an edge, he's on it
        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        case invite(until: TimeInterval)
        case chase
        case shell(until: TimeInterval)
        case wobble(until: TimeInterval)
        case won, survived, interrupted, declined
        public var isOver: Bool { [.won, .survived, .interrupted, .declined].contains(self) }
    }

    public enum Event: Equatable, Sendable {
        case started, bonked(Int), cameOut, gotcha, survived, interrupted, declined
    }

    /// What he's crawling on: an edge (the screen's or a window's), or nothing (his slime strand).
    public enum Contact: Equatable, Sendable { case floor, ceiling, leftWall, rightWall }

    public let tuning: Tuning
    public let round: TimeInterval
    public let scale: Double
    public let body: Double
    public let bounds: CGRect
    public private(set) var phase: Phase
    public private(set) var head: CGPoint
    /// Radians, 0 = right, y down.
    public private(set) var heading: Double
    public private(set) var startedAt: TimeInterval?
    public private(set) var bonks = 0
    public private(set) var waiting = false
    public private(set) var parked = false
    /// 0…1 through the two-step crawl cycle (8 frames).
    public private(set) var stride = 0.0
    public private(set) var speed = 0.0
    var last: TimeInterval
    var bonkReadyAt: TimeInterval = 0
    var lastCursor: CGPoint?
    var cursorStillSince: TimeInterval
    var inviteCursor: CGPoint?
    public private(set) var endedAt: TimeInterval?
    /// Window frames: their edges are surfaces too.
    public let windows: [CGRect]
    /// The slime strand he lays across open desktop (no surface under him), oldest first.
    public private(set) var strand: [CGPoint] = []

    public init(head: CGPoint, heading: Double = 0, bounds: CGRect, windows: [CGRect] = [], scale: Double, body: Double,
                round: TimeInterval = 60, invite: Bool = false, now: TimeInterval, tuning: Tuning = Tuning()) {
        self.head = head; self.heading = heading; self.bounds = bounds; self.windows = windows
        self.scale = scale; self.body = body; self.round = round; self.tuning = tuning
        self.last = now
        self.cursorStillSince = now
        if invite { phase = .invite(until: now + tuning.invite) } else { phase = .chase; startedAt = now }
    }

    /// Seconds into the round (0 before it starts).
    public func elapsed(_ now: TimeInterval) -> Double { startedAt.map { min(max(0, (endedAt ?? now) - $0), round) } ?? 0 }
    public func progress(_ now: TimeInterval) -> Double { round > 0 ? elapsed(now) / round : 1 }
    public func remaining(_ now: TimeInterval) -> Double { max(0, round - elapsed(now)) }
    public func score(_ now: TimeInterval) -> GameScore { GameScore(seconds: elapsed(now), count: bonks) }

    func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * min(max(t, 0), 1) }

    /// Crawl speed now, in points per second (before turning costs).
    public func crawlSpeed(_ now: TimeInterval, cursor: CGPoint) -> Double {
        var v = lerp(tuning.crawlStart, tuning.crawlEnd, progress(now)) * scale
        v *= 1 + tuning.bonkSpeedUp * Double(bonks)
        if distance(head, cursor) <= tuning.closeBodies * body { v *= 1 + tuning.closeBoost }
        if parked { v *= 1 - tuning.parkedSlow }
        return v
    }

    /// The surface under `p`: the screen's edges and every window's edges. Nil in open desktop.
    public func contact(at p: CGPoint) -> (contact: Contact, on: CGPoint)? {
        let g = tuning.surfaceGrip * scale
        var best: (Contact, CGPoint, Double)?
        func consider(_ c: Contact, _ q: CGPoint) {
            let d = Double(hypot(q.x - p.x, q.y - p.y))
            if d <= g, best == nil || d < best!.2 { best = (c, q, d) }
        }
        let b = bounds
        consider(.floor, CGPoint(x: p.x, y: b.maxY))
        consider(.ceiling, CGPoint(x: p.x, y: b.minY))
        consider(.leftWall, CGPoint(x: b.minX, y: p.y))
        consider(.rightWall, CGPoint(x: b.maxX, y: p.y))
        for r in windows {
            if p.x >= r.minX - g, p.x <= r.maxX + g {
                consider(.floor, CGPoint(x: p.x, y: r.minY))          // on its top
                consider(.ceiling, CGPoint(x: p.x, y: r.maxY))        // under its bottom
            }
            if p.y >= r.minY - g, p.y <= r.maxY + g {
                consider(.rightWall, CGPoint(x: r.minX, y: p.y))      // its left side: the wall on his right
                consider(.leftWall, CGPoint(x: r.maxX, y: p.y))
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// 0 far away … 1 touching: within one body length, for the edge vignette.
    public func danger(cursor: CGPoint) -> Double {
        guard !phase.isOver, case .chase = phase else { return 0 }
        let d = distance(head, cursor), r = tuning.dangerBodies * body
        return d >= r ? 0 : 1 - d / r
    }

    /// The cursor in the menu bar (above the bounds) or parked in a corner: Slugg can't reach it
    /// and waits at the edge nearest it.
    public func unreachable(_ c: CGPoint) -> Bool {
        if !bounds.contains(c) { return true }
        let k = tuning.corner
        let nearX = c.x - bounds.minX < k || bounds.maxX - c.x < k
        let nearY = c.y - bounds.minY < k || bounds.maxY - c.y < k
        return nearX && nearY
    }

    /// Where he heads: the cursor, or the nearest point he can wait at.
    public func goal(for c: CGPoint) -> CGPoint {
        guard unreachable(c) else { return c }
        let m = tuning.corner + body * 0.5
        return CGPoint(x: min(max(c.x, bounds.minX + m), bounds.maxX - m), y: min(max(c.y, bounds.minY + m), bounds.maxY - m))
    }

    /// Advances to `now` with the cursor at `cursor`.
    public mutating func step(now: TimeInterval, cursor: CGPoint) -> [Event] {
        let dt = min(max(now - last, 0), 0.05)
        last = now
        if let l = lastCursor, distance(l, cursor) > 0.5 { cursorStillSince = now }
        lastCursor = cursor
        parked = now - cursorStillSince >= tuning.parkedAfter
        var events: [Event] = []
        switch phase {
        case .won, .survived, .interrupted, .declined:
            return []
        case .invite(let until):
            if inviteCursor == nil { inviteCursor = cursor }
            if let c0 = inviteCursor, distance(c0, cursor) > tuning.inviteCancel { phase = .declined; endedAt = now; return [.declined] }
            if now >= until { phase = .declined; endedAt = now; return [.declined] }   // not accepted in time
            return []
        case .shell(let until):
            if now >= until { phase = .wobble(until: now + tuning.wobble) }
        case .wobble(let until):
            if now >= until { phase = .chase; bonkReadyAt = now + tuning.cooldown; events.append(.cameOut) }
        case .chase:
            break
        }
        if let s = startedAt, now - s >= round {
            phase = .survived; endedAt = s + round; speed = 0
            return events + [.survived]
        }
        guard phase == .chase else { speed = 0; return events }

        let target = goal(for: cursor)
        let dx = target.x - head.x, dy = target.y - head.y
        let d = (dx * dx + dy * dy).squareRoot()
        // turn first
        let want = atan2(dy, dx)
        var diff = remainder(want - heading, 2 * .pi)
        let turn = lerp(tuning.turnStart, tuning.turnEnd, progress(now)) * .pi / 180 * dt
        if abs(diff) <= turn { heading = want; diff = 0 } else { heading = remainder(heading + (diff > 0 ? turn : -turn), 2 * .pi); diff -= diff > 0 ? turn : -turn }
        let aligned = abs(diff) * 180 / .pi <= tuning.turnBeforeMove
        waiting = unreachable(cursor) && d < body * 0.25
        var v = crawlSpeed(now, cursor: cursor) * (aligned ? 1 : 0.15)
        // across open desktop he crawls on a strand of his own slime: half speed
        let onSurface = contact(at: head) != nil
        if !onSurface { v *= tuning.openSpeed }
        if waiting { v = 0 }
        // the two-step: two pushes per cycle, averaging `v`
        let push = 1 - 0.6 * cos(4 * .pi * stride)
        let move = min(v * push * dt, d)
        if move > 0 {
            head.x += cos(heading) * move
            head.y += sin(heading) * move
            stride = (stride + move / (tuning.strideLength * scale)).truncatingRemainder(dividingBy: 1)
            if !onSurface, strand.last.map({ hypot($0.x - head.x, $0.y - head.y) >= 3 * scale }) ?? true { strand.append(head) }
            if strand.count > 2000 { strand.removeFirst(strand.count - 2000) }
        }
        speed = v
        if !unreachable(cursor), distance(head, cursor) <= tuning.gotchaRadius * scale {
            phase = .won; endedAt = now; speed = 0
            events.append(.gotcha)
        }
        return events
    }

    /// A click on Slugg: into the shell, unless he's cooling down. Returns whether it counted.
    public mutating func bonk(now: TimeInterval) -> Bool {
        if case .invite = phase { phase = .chase; startedAt = now; last = now; return false }   // a click accepts the invite
        guard phase == .chase, now >= bonkReadyAt else { return false }
        bonks += 1
        phase = .shell(until: now + lerp(tuning.shellStart, tuning.shellEnd, progress(now)))
        speed = 0
        return true
    }

    /// Accepts an invite (a click on him or on his "…").
    public mutating func accept(now: TimeInterval) {
        if case .invite = phase { phase = .chase; startedAt = now; last = now }
    }

    /// Real work (typing, a click in another app): over at once, no score.
    public mutating func interrupt(now: TimeInterval) -> Event? {
        guard !phase.isOver else { return nil }
        phase = .interrupted; endedAt = now; speed = 0
        return .interrupted
    }
}

// MARK: - Frogg · Snap

/// A drawn fly rides the cursor. Frogg tracks it, shows a tell (throat puff, eyes narrow, coil),
/// then strikes where the fly was when the tell ended. Dodge by moving in time.
public struct SnapGame: Sendable {
    public struct Tuning: Sendable, Equatable {
        /// Per 10 s of the round (the escalation chart).
        public var tell: [Double] = [0.70, 0.60, 0.50, 0.42, 0.34, 0.28]
        public var strike: [Double] = [0.090, 0.090, 0.080, 0.080, 0.070, 0.070]
        public var recovery: [Double] = [0.60, 0.55, 0.50, 0.45, 0.40, 0.35]
        public var feint: [Double] = [0, 0, 0.10, 0.20, 0.25, 0.30]
        public var gapStart = 2.2, gapEnd = 1.1, gapJitter = 0.3
        public var hitStop = 0.060
        public var hitRadius = 10.0                 // px at 1×
        public var feintFollow = 0.40               // the strike after a feint
        public var feintsFrom = 20.0                // s
        public var invite = 2.0
        public init() {}
    }

    public enum Phase: Equatable, Sendable {
        case invite(until: TimeInterval)
        case track(next: TimeInterval)
        case tell(start: TimeInterval, end: TimeInterval, feint: Bool)
        case feinted(strikeAt: TimeInterval)
        case strike(start: TimeInterval, end: TimeInterval, aim: CGPoint)
        case hitStop(until: TimeInterval, aim: CGPoint)
        case recover(until: TimeInterval)
        case caught(aim: CGPoint), survived, interrupted, declined
        public var isOver: Bool {
            switch self { case .caught, .survived, .interrupted, .declined: true; default: false }
        }
    }

    public enum Event: Equatable, Sendable {
        case started, tell(feint: Bool), feinted, strike(aim: CGPoint), dodged(Int), caught, survived, interrupted, declined
    }

    public let tuning: Tuning
    public let round: TimeInterval
    public let scale: Double
    public private(set) var phase: Phase
    public private(set) var startedAt: TimeInterval?
    public private(set) var dodges = 0
    public private(set) var strikes = 0
    public private(set) var feints = 0
    public private(set) var endedAt: TimeInterval?
    var rng: SeededRandom

    public init(seed: UInt64, scale: Double, round: TimeInterval = 60, invite: Bool = false, now: TimeInterval, tuning: Tuning = Tuning()) {
        self.rng = SeededRandom(seed: seed)
        self.scale = scale; self.round = round; self.tuning = tuning
        if invite { phase = .invite(until: now + tuning.invite) } else {
            phase = .track(next: now + tuning.gapStart)
            startedAt = now
        }
    }

    public func elapsed(_ now: TimeInterval) -> Double { startedAt.map { min(max(0, (endedAt ?? now) - $0), round) } ?? 0 }
    public func remaining(_ now: TimeInterval) -> Double { max(0, round - elapsed(now)) }
    public func score(_ now: TimeInterval) -> GameScore { GameScore(seconds: elapsed(now), count: dodges) }

    /// The row of the escalation chart for `elapsed` seconds in.
    public func row(_ elapsed: Double) -> Int { min(max(Int(elapsed / 10), 0), tuning.tell.count - 1) }
    public func tellLength(at elapsed: Double) -> Double { tuning.tell[row(elapsed)] }
    public func strikeLength(at elapsed: Double) -> Double { tuning.strike[row(elapsed)] }
    public func recoveryLength(at elapsed: Double) -> Double { tuning.recovery[row(elapsed)] }
    public func feintChance(at elapsed: Double) -> Double { elapsed < tuning.feintsFrom ? 0 : tuning.feint[row(elapsed)] }
    /// The gap between strikes, before jitter: 2.2 s → 1.1 s over the round.
    public func gap(at elapsed: Double) -> Double {
        let t = min(max(elapsed / max(round, 1), 0), 1)
        return tuning.gapStart + (tuning.gapEnd - tuning.gapStart) * t
    }

    /// Where the fly is drawn: up and right of the cursor tip, never over it.
    public static func fly(cursor: CGPoint, scale: Double) -> CGPoint {
        CGPoint(x: cursor.x + 8 * scale / 2, y: cursor.y - 8 * scale / 2)
    }

    /// Whether the tongue at `aim` touches the fly at `fly`.
    public func hits(aim: CGPoint, fly: CGPoint) -> Bool { distance(aim, fly) <= tuning.hitRadius * scale }

    mutating func random() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }

    public mutating func accept(now: TimeInterval) {
        if case .invite = phase { phase = .track(next: now + tuning.gapStart); startedAt = now }
    }

    /// Advances to `now`; `fly` is where the fly is now.
    public mutating func step(now: TimeInterval, fly: CGPoint) -> [Event] {
        if phase.isOver { return [] }
        if case .invite(let until) = phase {
            if now >= until { phase = .declined; endedAt = now; return [.declined] }
            return []
        }
        guard let s = startedAt else { return [] }
        var events: [Event] = []
        // the round's end lands only between strikes (a strike in flight is judged first)
        var guardLoop = 0
        while guardLoop < 8 {
            guardLoop += 1
            let el = now - s
            switch phase {
            case .track(let next):
                if el >= round { phase = .survived; endedAt = s + round; return events + [.survived] }
                guard now >= next else { return events }
                let tEl = next - s
                let feint = random() < feintChance(at: tEl)
                if feint { feints += 1 }
                phase = .tell(start: next, end: next + tellLength(at: tEl), feint: feint)
                events.append(.tell(feint: feint))
            case .tell(_, let end, let feint):
                guard now >= end else { return events }
                if feint {
                    phase = .feinted(strikeAt: end + tuning.feintFollow)
                    events.append(.feinted)
                } else {
                    beginStrike(at: end, aim: fly, events: &events)
                }
            case .feinted(let at):
                guard now >= at else { return events }
                beginStrike(at: at, aim: fly, events: &events)
            case .strike(_, let end, let aim):
                guard now >= end else { return events }
                // full reach: judged now
                if hits(aim: aim, fly: fly) {
                    phase = .caught(aim: aim); endedAt = now
                    return events + [.caught]
                }
                phase = .hitStop(until: end + tuning.hitStop, aim: aim)
            case .hitStop(let until, _):
                guard now >= until else { return events }
                dodges += 1
                events.append(.dodged(dodges))
                phase = .recover(until: until + recoveryLength(at: until - s))
            case .recover(let until):
                guard now >= until else { return events }
                let el2 = until - s
                let jitter = (random() * 2 - 1) * tuning.gapJitter
                // the gap counts from the start of the last tell; never shorter than a breath
                phase = .track(next: until + max(0.25, gap(at: el2) - tellLength(at: el2) - strikeLength(at: el2) - recoveryLength(at: el2) + jitter))
            default:
                return events
            }
        }
        return events
    }

    mutating func beginStrike(at t: TimeInterval, aim: CGPoint, events: inout [Event]) {
        strikes += 1
        let el = t - (startedAt ?? t)
        phase = .strike(start: t, end: t + strikeLength(at: el), aim: aim)
        events.append(.strike(aim: aim))
    }

    public mutating func interrupt(now: TimeInterval) -> Event? {
        guard !phase.isOver else { return nil }
        phase = .interrupted; endedAt = now
        return .interrupted
    }
}

/// Best scores per pet ("slugg" → longest survival; "frogg" → most dodges), as stored data.
public struct GameRecords: Codable, Equatable, Sendable {
    public var best: [String: GameScore] = [:]
    public init() {}
    /// Keeps `s` if it beats the pet's best (more seconds, then more count). Returns whether it did.
    @discardableResult
    public mutating func offer(_ s: GameScore, for pet: String, byCount: Bool) -> Bool {
        guard let b = best[pet] else { best[pet] = s; return true }
        let better = byCount ? (s.count, s.seconds) > (b.count, b.seconds) : (s.seconds, s.count) > (b.seconds, b.count)
        if better { best[pet] = s }
        return better
    }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
