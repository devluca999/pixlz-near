import CoreGraphics
import Foundation
import PixlzCore

/// SPEC §11.1: a click is press + release under 250 ms with under 4 pt of movement;
/// moving 4 pt starts a grab. Double-click comes from the event's click count.
public struct PointerGesture: Sendable {
    public static let clickTime: TimeInterval = 0.25
    public static let dragDistance: CGFloat = 4

    public let start: CGPoint
    public let startTime: TimeInterval
    public private(set) var dragging = false

    public init(at p: CGPoint, time: TimeInterval) {
        start = p
        startTime = time
    }

    /// Returns true when this move turns the press into a drag.
    public mutating func moved(to p: CGPoint) -> Bool {
        guard !dragging, hypot(p.x - start.x, p.y - start.y) >= Self.dragDistance else { return false }
        dragging = true
        return true
    }

    public func isClick(releasedAt p: CGPoint, time: TimeInterval) -> Bool {
        !dragging && time - startTime < Self.clickTime && hypot(p.x - start.x, p.y - start.y) < Self.dragDistance
    }
}

/// "3 pokes within 4 s → annoyed" (SPEC §11.1).
public struct PokeCounter: Sendable {
    private var times: [TimeInterval] = []
    public init() {}

    /// Records a poke; true when it makes Frogg annoyed.
    public mutating func poke(at t: TimeInterval) -> Bool {
        times = times.filter { t - $0 < 4 } + [t]
        if times.count >= 3 {
            times.removeAll()
            return true
        }
        return false
    }
}

/// A slot animation: frame names and how many 12 fps ticks each is held (SPEC §4.4).
public struct SlotAnimation: Sendable, Equatable {
    public let frames: [String]
    public let holds: [Int]
    public static let tick: TimeInterval = 1.0 / 12

    public var duration: TimeInterval { Double(holds.reduce(0, +)) * Self.tick }

    /// Holds from assets/frogg/pixl.json.
    public static let poke = SlotAnimation(frames: ["poke_0", "poke_1", "poke_2"], holds: [2, 4, 6])
    public static let signature = SlotAnimation(frames: ["signature_0", "signature_1", "signature_2"], holds: [4, 2, 8])
    public static let rest = SlotAnimation(frames: ["rest_0", "rest_1", "rest_2"], holds: [6, 6, 12])
    public static let nudge = SlotAnimation(frames: ["poke_1", "poke_2"], holds: [4, 6])

    /// (frame, start offset in seconds) for scheduling frame changes only.
    public var schedule: [(String, TimeInterval)] {
        var t: TimeInterval = 0
        return zip(frames, holds).map { f, h in
            defer { t += Double(h) * Self.tick }
            return (f, t)
        }
    }
}

/// Frogg thrown by the user: PixlzCore physics (bounces off screen edges and the menu bar,
/// SPEC §4.5) until it lands on the first window top or the ground below (WorldMap.landing).
public struct ThrowFlight: Sendable {
    public private(set) var body: Body
    let config: PhysicsConfig
    let world: WorldMap
    let bounds: CGRect

    /// Frogg's species physics (assets/frogg/pixl.json).
    static let frogg: SpeciesPhysics = {
        let json = #"{"gravity":900,"hopApex":[18,30],"hopDistance":[40,90],"walkSpeed":0}"#
        return try! JSONDecoder().decode(SpeciesPhysics.self, from: Data(json.utf8))
    }()

    /// - Parameters (all top-left global coordinates, y down):
    ///   - foot: Frogg's feet when released; velocity in pt/s.
    ///   - screens: (frame, visibleFrame) per display; window: the active window, a platform.
    ///   - halfWidth: half Frogg's width, so it bounces off edges instead of leaving the screen.
    public init(foot: CGPoint, velocity: CGVector, scale: CGFloat, screens: [(frame: CGRect, visible: CGRect)],
                window: CGRect?, halfWidth: CGFloat) {
        var cfg = PhysicsConfig(species: Self.frogg, scale: Double(scale))
        let speed = hypot(velocity.dx, velocity.dy)
        var v = velocity
        if speed > cfg.maxThrowSpeed { v = CGVector(dx: v.dx * cfg.maxThrowSpeed / speed, dy: v.dy * cfg.maxThrowSpeed / speed) }
        cfg.restitution = 0.4
        config = cfg
        body = Body(position: foot, velocity: v)
        let displays = screens.enumerated().map { i, s in DisplayInfo(id: i, frame: s.frame, visibleFrame: s.visible) }
        world = WorldMap(WorldInput(displays: displays, windows: window.map { [WindowInfo(id: 1, frame: $0)] } ?? []))
        let screen = screens.first { $0.visible.contains(foot) }?.visible ?? screens.first?.visible ?? .zero
        bounds = screen.insetBy(dx: halfWidth, dy: 0)
    }

    /// Advances one step; returns the landing spot once Frogg touches a platform.
    public mutating func step(dt: TimeInterval) -> CGPoint? {
        let before = body.position
        body.stepAirborne(dt: dt, config: config, bounds: bounds)
        if let spot = world.landing(from: before, to: body.position) {
            body.position = spot.point
            return spot.point
        }
        // Never fall out of the world: the screen bottom is the floor of last resort.
        if body.position.y >= bounds.maxY {
            body.position.y = bounds.maxY
            return body.position
        }
        return nil
    }
}
