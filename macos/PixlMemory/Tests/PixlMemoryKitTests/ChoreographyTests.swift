import CoreGraphics
import Foundation
import PixlzCore
import Testing
@testable import PixlMemoryKit

struct ChoreographyTests {
    let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)
    let sprite = CGSize(width: 140, height: 100)

    func route(_ a: CGPoint, _ b: CGPoint) -> HopRoute {
        HopRoute.plan(from: a, to: b, bounds: screen, sprite: sprite, scale: 2)
    }

    func samples(_ c: Choreography, step: Double = 1.0 / 120) -> [Pose] {
        stride(from: 0.0, through: c.duration + step, by: step).map { c.pose(at: $0).pose }
    }

    @Test func beatsRunInOrderAndEndAtTheTarget() {
        let a = CGPoint(x: 300, y: 600), b = CGPoint(x: 700, y: 500)
        let c = Choreography.hop(route(a, b))
        let frames = samples(c).map(\.frame)
        var order: [String] = []
        for f in frames where order.last != f { order.append(f) }
        #expect(order == [MotionFrames.notice, MotionFrames.coil, MotionFrames.rise, MotionFrames.land, MotionFrames.settle]
                || order == [MotionFrames.notice, MotionFrames.coil, MotionFrames.rise, MotionFrames.fall, MotionFrames.land, MotionFrames.settle])
        let end = c.pose(at: c.duration + 1)
        #expect(end.done && end.pose.foot == b && end.pose.squash == CGSize(width: 1, height: 1))
        #expect(c.pose(at: 0).pose.foot == a)
        // notice beat is 120–250 ms
        #expect((0.12...0.25).contains(Choreography.noticeTime))
    }

    @Test func motionIsContinuousNoSnapping() {
        let c = Choreography.hop(route(CGPoint(x: 100, y: 800), CGPoint(x: 1300, y: 300)))  // chained
        let feet = samples(c).map(\.foot)
        for (p, q) in zip(feet, feet.dropFirst()) {
            #expect(hypot(q.x - p.x, q.y - p.y) < 60, "jump from \(p) to \(q)")
        }
    }

    @Test func squashAndStretchThroughTheHop() {
        let c = Choreography.hop(route(CGPoint(x: 300, y: 600), CGPoint(x: 700, y: 600)))
        let poses = samples(c)
        let coil = poses.filter { $0.frame == MotionFrames.coil }.map(\.squash.height)
        #expect(coil.min()! < 0.9)                                         // crouch
        let air = poses.filter { $0.frame == MotionFrames.rise || $0.frame == MotionFrames.fall }.map(\.squash.height)
        #expect(air.first! > 1.08)                                         // stretched at take-off
        let land = poses.filter { $0.frame == MotionFrames.land }.map(\.squash.height)
        #expect(land.min()! < 0.85)                                        // squash on landing
        let settle = poses.filter { $0.frame == MotionFrames.settle }.map(\.squash.height)
        #expect(settle.contains { $0 > 1.01 } && settle.contains { $0 < 0.99 })  // a bounce each way
    }

    @Test func facesTheDirectionOfTravel() {
        let left = Choreography.hop(route(CGPoint(x: 900, y: 600), CGPoint(x: 400, y: 600)))
        let right = Choreography.hop(route(CGPoint(x: 400, y: 600), CGPoint(x: 900, y: 600)))
        let up = Choreography.hop(route(CGPoint(x: 400, y: 800), CGPoint(x: 380, y: 300)))
        func airborneFacing(_ c: Choreography) -> Set<Bool> { Set(samples(c).filter { $0.frame == MotionFrames.rise }.map(\.mirrored)) }
        #expect(airborneFacing(left) == [true])
        #expect(airborneFacing(right) == [false])
        #expect(airborneFacing(up) == [false])  // mostly vertical: no flip
        #expect(left.pose(at: 0).pose.mirrored)  // the notice look turns toward the target too
    }

    @Test func dustAtEveryLanding() {
        let c = Choreography.hop(route(CGPoint(x: 100, y: 800), CGPoint(x: 1300, y: 300)))
        let legs = route(CGPoint(x: 100, y: 800), CGPoint(x: 1300, y: 300)).legs.count
        #expect(c.landings(between: -1, and: c.duration).count == legs)
    }

    @Test func dropInIsQuickAndPeeksFirst() {
        let c = Choreography.dropIn(hangFoot: CGPoint(x: 500, y: 140), to: CGPoint(x: 500, y: 850))
        #expect(c.duration <= 0.6)
        #expect(c.pose(at: 0.01).pose.frame == MotionFrames.hang)
        let falling = samples(c).filter { $0.frame == MotionFrames.fall }
        #expect(!falling.isEmpty && falling.allSatisfy { $0.squash.height >= 1 })  // stretched while falling
        #expect(samples(c).contains { $0.frame == MotionFrames.dropLand && $0.squash.height < 0.85 })
        #expect(c.pose(at: c.duration).pose.foot == CGPoint(x: 500, y: 850))
        let exit = Choreography.exit(from: CGPoint(x: 500, y: 850), scale: 2)
        #expect(exit.duration <= 0.15 && exit.pose(at: exit.duration).pose.alpha == 0)
    }

    @Test func retargetingMidAirNeverSnapsBack() {
        let a = CGPoint(x: 200, y: 600), b = CGPoint(x: 700, y: 600), c2 = CGPoint(x: 400, y: 300)
        let c = Choreography.hop(route(a, b))
        for t in stride(from: 0.0, through: c.duration, by: 0.05) {
            let here = c.pose(at: t).pose.foot
            let next = c.retargeted(at: t) { route($0, c2) }
            let start = next.pose(at: 0).pose.foot
            #expect(hypot(start.x - here.x, start.y - here.y) < 1, "retarget at \(t) jumped from \(here) to \(start)")
            #expect(next.pose(at: next.duration).pose.foot == c2)
            #expect(next.pose(at: 0).pose.frame != MotionFrames.notice)  // no second notice beat
        }
    }

    @Test func bumpIsATinyHopInPlace() {
        let p = CGPoint(x: 500, y: 400)
        let c = Choreography.bump(at: p, scale: 2)
        let highest = samples(c).map(\.foot.y).min()!
        #expect(p.y - highest <= 10.5 && p.y - highest > 5)
        #expect(c.pose(at: c.duration).pose.foot == p && c.duration < 0.5)
    }
}

struct RetargetSpeedTests {
    /// Retargeting at any moment keeps speeds in the normal hop range (seen live: a
    /// fullscreen focused window once made the route raise the arc to screen height).
    @Test func retargetedFlightsStayAtNormalSpeed() {
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 870)
        let sprite = CGSize(width: 140, height: 100)
        for keepOut in [nil, CGRect(x: 0, y: 25, width: 1512, height: 870)] {
            let r = { (a: CGPoint, b: CGPoint) in HopRoute.plan(from: a, to: b, bounds: screen, sprite: sprite, scale: 2, keepOut: keepOut) }
            let c = Choreography.hop(r(CGPoint(x: 900, y: 895), CGPoint(x: 480, y: 895)))
            for t in stride(from: 0.0, to: c.duration, by: 0.05) {
                let next = c.retargeted(at: t) { r($0, CGPoint(x: 700, y: 895)) }
                var prev = next.pose(at: 0).pose.foot
                for k in 1...600 {
                    let p = next.pose(at: Double(k) / 600 * next.duration).pose.foot
                    let perFrame = hypot(p.x - prev.x, p.y - prev.y) / CGFloat(next.duration / 600 * 60)
                    #expect(perFrame < 40, "t=\(t) keepOut=\(keepOut != nil): \(perFrame) pt/frame")
                    prev = p
                }
            }
        }
    }
}
