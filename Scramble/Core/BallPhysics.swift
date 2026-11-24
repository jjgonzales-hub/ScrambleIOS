import Foundation
import CoreGraphics

/// Real ball physics for every shot: flight (gravity, drag, lift from
/// backspin, side spin, wind), bounces that depend on the surface, rolling
/// with lie-specific friction and green slope, and cup capture/lip-outs.
///
/// Everything runs in hole coordinates (2 pts = 1 yd) with height in the
/// same units. A shot is simulated to completion up front — the renderer
/// just plays the frames back — so the landing spot, the read line, and the
/// tracer are all exactly what the ball does.
enum BallPhysics {

    // MARK: - World description

    /// What the physics needs to know about a hole. Kept independent of the
    /// renderer and of UIKit so it can be tested on its own.
    struct Course {
        let lie: (CGPoint) -> Lie
        let pin: CGPoint
        let cupRadius: CGFloat
        /// Downhill acceleration (pts/s²) at a point on the green.
        let slope: (CGPoint) -> CGVector
        let bounds: CGRect
        /// Height (pts) below which a ball over `.trees` clips branches.
        var treeHeight: CGFloat = 30
    }

    struct Frame {
        let t: Double
        let p: CGPoint
        let h: CGFloat
    }

    enum Finish: Equatable { case rest, holed, water }

    enum Event: Equatable {
        case landed(Lie)       // first touchdown
        case bounce(Lie)
        case treeHit
        case lipOut
    }

    struct Trajectory {
        let frames: [Frame]
        let events: [(t: Double, event: Event)]
        let finish: Finish
        let end: CGPoint
        /// First touchdown point (nil for putts) — "carry".
        let landing: CGPoint?
        /// Where the ball entered water (for the drop), if it did.
        let waterEntry: CGPoint?

        var duration: Double { frames.last?.t ?? 0 }
        var path: [CGPoint] { frames.map(\.p) }
        /// Highest point of the flight in pts.
        var apex: CGFloat { frames.map(\.h).max() ?? 0 }
    }

    // MARK: - Constants

    static let gravity: CGFloat = 21.5          // pts/s² (9.81 m/s²)
    static let dragK: CGFloat = 0.0021          // per pt
    static let liftK: CGFloat = 0.0017          // per pt at full spin
    /// Wind mph → pts/s of air movement, exaggerated a touch for gameplay
    /// so the wind is always worth reading.
    static let windScale: CGFloat = 1.55
    static let dt: Double = 1.0 / 240

    // Green roll model: dv/dt = -(k v + c). Exponential + constant decel
    // gives a natural slow-down and a soft stop instead of a snap.
    static let greenK: CGFloat = 1.15
    static let greenC: CGFloat = 13

    struct Launch {
        var speed: CGFloat          // pts/s
        var angle: CGFloat          // radians above horizontal
        var spin: CGFloat           // 0…1.5 backspin factor (lift + check)
        var side: CGFloat           // side-force coefficient (+ = right)
    }

    /// Per-club launch characteristics: launch angle, backspin, and how
    /// much the ball checks on its first bounce.
    static func launchProfile(_ club: Club) -> (angle: CGFloat, spin: CGFloat, check: CGFloat) {
        switch club {
        case .driver: return (11.5 * .pi / 180, 0.62, 0.0)
        case .wood3: return (12.5 * .pi / 180, 0.72, 0.03)
        case .iron5: return (15 * .pi / 180, 0.9, 0.12)
        case .iron7: return (18 * .pi / 180, 1.0, 0.2)
        case .iron9: return (23 * .pi / 180, 1.12, 0.3)
        case .pitchWedge: return (27 * .pi / 180, 1.2, 0.38)
        case .sandWedge: return (32 * .pi / 180, 1.3, 0.45)
        case .putter: return (0, 0, 0)
        }
    }

    // MARK: - Full shots and chips

    /// Simulate a struck shot. `carryYards`/`lateralYards` are the
    /// still-air targets from the swing; the launch is solved to hit them,
    /// then the ball flies for real through `wind`.
    static func strike(from start: CGPoint, aim: CGVector, club: Club,
                       carryYards: Double, lateralYards: Double,
                       grounded: Bool, wind: Wind,
                       course: Course) -> Trajectory {
        let aimU = aim.normalized
        let profile = launchProfile(club)
        var launch = Launch(speed: 0, angle: grounded ? 0.05 : profile.angle,
                            spin: grounded ? 0.1 : profile.spin, side: 0)
        let targetCarry = CGFloat(max(carryYards, 1)) * Hole.pointsPerYard
        launch.speed = solveSpeed(for: targetCarry, launch: launch)
        let targetLateral = CGFloat(lateralYards) * Hole.pointsPerYard
        if abs(targetLateral) > 0.5 {
            launch.side = solveSide(for: targetLateral, launch: launch)
        }
        return simulate(from: start, aim: aimU, launch: launch,
                        check: grounded ? 0 : profile.check,
                        wind: wind, course: course, offGreen: true)
    }

    /// Still-air carry and lateral of a launch (no bounces).
    static func carry(_ launch: Launch) -> (carry: CGFloat, lateral: CGFloat) {
        var pos = SIMD3<Double>(0, 0, 0)        // x = lateral, y = forward, z = up
        var vel = SIMD3<Double>(0, Double(launch.speed * cos(launch.angle)),
                                Double(launch.speed * sin(launch.angle)))
        var t = 0.0
        let step = 1.0 / 120
        while t < 20 {
            vel += accel(vel: vel, air: .zero, spin: launch.spin, side: launch.side, t: t) * step
            pos += vel * step
            t += step
            if pos.z <= 0 && vel.z < 0 { break }
        }
        return (CGFloat(pos.y), CGFloat(pos.x))
    }

    private static func solveSpeed(for target: CGFloat, launch: Launch) -> CGFloat {
        var lo: CGFloat = 2, hi: CGFloat = 700
        var l = launch
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            l.speed = mid
            if carry(l).carry < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    private static func solveSide(for target: CGFloat, launch: Launch) -> CGFloat {
        // Lateral is close to linear in the side coefficient — two secant
        // steps land within a fraction of a yard.
        var l = launch
        var s0: CGFloat = 0, f0: CGFloat = -target
        var s1: CGFloat = target > 0 ? 0.0004 : -0.0004
        l.side = s1
        var f1 = carry(l).lateral - target
        for _ in 0..<6 {
            guard abs(f1 - f0) > 0.0001 else { break }
            let s2 = s1 - f1 * (s1 - s0) / (f1 - f0)
            s0 = s1; f0 = f1; s1 = s2
            l.side = s1
            f1 = carry(l).lateral - target
            if abs(f1) < 0.3 { break }
        }
        return s1
    }

    /// Acceleration in local shot space (x lateral, y forward, z up).
    private static func accel(vel: SIMD3<Double>, air: SIMD3<Double>,
                              spin: CGFloat, side: CGFloat, t: Double) -> SIMD3<Double> {
        let rel = vel - air
        let speed = (rel * rel).sum().squareRoot()
        var a = SIMD3<Double>(0, 0, -Double(gravity))
        guard speed > 0.01 else { return a }
        a -= rel * (Double(dragK) * speed)
        // Spin decays over the flight, so the ball climbs, peaks, and falls
        // steeper than it rose — the classic ball-flight shape.
        let spinNow = Double(spin) * exp(-t / 5.5)
        let horiz = (rel.x * rel.x + rel.y * rel.y).squareRoot()
        if horiz > 0.01 {
            // Lift: perpendicular to velocity in the vertical plane.
            let liftDir = SIMD3<Double>(-rel.x * rel.z / horiz, -rel.y * rel.z / horiz, horiz) / speed
            a += liftDir * (Double(liftK) * spinNow * speed * speed)
            // Side force: horizontal, perpendicular to travel (+ = right).
            let rightDir = SIMD3<Double>(rel.y / horiz, -rel.x / horiz, 0)
            a += rightDir * (Double(side) * speed * speed * exp(-t / 9))
        }
        return a
    }

    // MARK: - Putts

    /// Flat-green roll distance (pts) for an initial speed.
    static func puttDistance(speed v0: CGFloat) -> CGFloat {
        guard v0 > 0 else { return 0 }
        let k = greenK, c = greenC
        return v0 / k - (c / (k * k)) * log(1 + k * v0 / c)
    }

    /// Inverse of `puttDistance`: the speed that rolls `d` pts on a flat
    /// green.
    static func puttSpeed(forDistance d: CGFloat) -> CGFloat {
        var lo: CGFloat = 0, hi: CGFloat = 1200
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if puttDistance(speed: mid) < d { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static func putt(from start: CGPoint, direction: CGVector, speed: CGFloat,
                     course: Course) -> Trajectory {
        let dir = direction.normalized
        let launch = Launch(speed: speed, angle: 0, spin: 0, side: 0)
        return simulate(from: start, aim: dir, launch: launch, check: 0,
                        wind: Wind(speed: 0, angle: 0), course: course,
                        offGreen: course.lie(start) != .green, rollingStart: true)
    }

    // MARK: - Core simulation

    private static func rollFriction(_ lie: Lie) -> (k: CGFloat, c: CGFloat) {
        switch lie {
        case .green: return (greenK, greenC)
        case .fringe: return (2.2, 22)
        case .fairway, .tee: return (1.6, 24)
        case .rough: return (4.2, 60)
        case .trees: return (4.5, 70)
        case .bunker: return (9, 140)
        case .water: return (20, 300)
        }
    }

    private static func bounceResponse(_ lie: Lie) -> (restitution: CGFloat, keep: CGFloat) {
        switch lie {
        case .green: return (0.26, 0.7)
        case .fringe: return (0.28, 0.66)
        case .fairway, .tee: return (0.34, 0.74)
        case .rough: return (0.16, 0.42)
        case .trees: return (0.14, 0.4)
        case .bunker: return (0.03, 0.12)
        case .water: return (0, 0)
        }
    }

    private static func simulate(from start: CGPoint, aim: CGVector, launch: Launch,
                                 check: CGFloat, wind: Wind, course: Course,
                                 offGreen: Bool, rollingStart: Bool = false) -> Trajectory {
        // World space: x/y hole coords, z height.
        let right = aim.perpendicularRight
        func toWorld(_ local: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(local.y * Double(aim.dx) + local.x * Double(right.dx),
                  local.y * Double(aim.dy) + local.x * Double(right.dy),
                  local.z)
        }
        var pos = SIMD3<Double>(Double(start.x), Double(start.y), 0)
        var vel = toWorld(SIMD3(0, Double(launch.speed * cos(launch.angle)),
                                Double(launch.speed * sin(launch.angle))))
        let windVec = wind.vector
        let air = SIMD3<Double>(Double(windVec.dx), Double(windVec.dy), 0)
            * Double(CGFloat(wind.speed) * windScale)

        var frames: [Frame] = [Frame(t: 0, p: start, h: 0)]
        var events: [(Double, Event)] = []
        var t = 0.0
        var nextFrame = 1.0 / 60
        var airborne = !rollingStart
        var flightTime = 0.0
        var bounces = 0
        var landing: CGPoint?
        var hitTree = false
        var lippedUntilClear = false
        var finish: Finish = .rest
        var waterEntry: CGPoint?
        // Flagstick in for shots from off the green: much more forgiving
        // capture, which is what makes chip-ins possible.
        let captureBoost: CGFloat = offGreen ? 2.4 : 1.0

        func point(_ v: SIMD3<Double>) -> CGPoint { CGPoint(x: v.x, y: v.y) }
        func now2D(_ v: SIMD3<Double>) -> CGPoint { CGPoint(x: v.x, y: v.y) }

        while t < 30 {
            let p2 = point(pos)
            let lie = course.lie(p2)

            if airborne {
                // Local-space acceleration rotated into the world, with the
                // wind expressed in the same local frame.
                let localVel = SIMD3<Double>(
                    vel.x * Double(right.dx) + vel.y * Double(right.dy),
                    vel.x * Double(aim.dx) + vel.y * Double(aim.dy),
                    vel.z)
                let localAir = SIMD3<Double>(
                    air.x * Double(right.dx) + air.y * Double(right.dy),
                    air.x * Double(aim.dx) + air.y * Double(aim.dy), 0)
                let a = bounces == 0
                    ? accel(vel: localVel, air: localAir, spin: launch.spin,
                            side: launch.side, t: flightTime)
                    : accel(vel: localVel, air: localAir, spin: 0, side: 0, t: 99)
                vel += toWorld(a) * dt
                pos += vel * dt
                flightTime += dt

                // Branches: a low ball over the trees gets knocked down.
                if !hitTree, lie == .trees, pos.z < Double(course.treeHeight), pos.z > 2 {
                    hitTree = true
                    vel.x *= 0.22; vel.y *= 0.22
                    vel.z = -abs(vel.z) * 0.25
                    events.append((t, .treeHit))
                }

                if pos.z <= 0 && vel.z < 0 {
                    pos.z = 0
                    let here = point(pos)
                    let ground = course.lie(here)
                    if landing == nil {
                        landing = here
                        events.append((t, .landed(ground)))
                    } else {
                        events.append((t, .bounce(ground)))
                    }
                    if ground == .water {
                        finish = .water
                        waterEntry = here
                        frames.append(Frame(t: t, p: here, h: 0))
                        break
                    }
                    // Dunk: landing right on the cup.
                    if here.distance(to: course.pin) <= course.cupRadius,
                       hypot(vel.x, vel.y) < 70 {
                        finish = .holed
                        frames.append(Frame(t: t, p: course.pin, h: 0))
                        break
                    }
                    let resp = bounceResponse(ground)
                    var keep = resp.keep
                    if bounces == 0 && (ground == .green || ground == .fringe || ground == .fairway) {
                        keep *= (1 - check)
                    }
                    vel.x *= Double(keep)
                    vel.y *= Double(keep)
                    vel.z = -vel.z * Double(resp.restitution)
                    bounces += 1
                    if vel.z < 7 || bounces > 6 {
                        vel.z = 0
                        airborne = false
                    }
                }
            } else {
                // Rolling
                pos.z = 0
                if lie == .water {
                    finish = .water
                    waterEntry = p2
                    frames.append(Frame(t: t, p: p2, h: 0))
                    break
                }
                let f = rollFriction(lie)
                var v = SIMD2<Double>(vel.x, vel.y)
                let speed = (v * v).sum().squareRoot()
                if speed > 0.0001 {
                    let decel = Double(f.k) * speed + Double(f.c)
                    let newSpeed = max(speed - decel * dt, 0)
                    v *= newSpeed / speed
                }
                if lie == .green || lie == .fringe {
                    let local = course.slope(now2D(pos))
                    let slope = lie == .green ? local : local * 0.5
                    // Slope only moves a ball that's already rolling; static
                    // friction holds a stopped ball (no endless creep).
                    if (v * v).sum().squareRoot() > 0.5 {
                        v += SIMD2(Double(slope.dx), Double(slope.dy)) * dt
                    }
                }
                let prev = point(pos)
                pos.x += v.x * dt
                pos.y += v.y * dt
                vel = SIMD3(v.x, v.y, 0)
                let now = point(pos)

                // Cup: closest approach along this step's segment.
                let dPin = segmentDistance(course.pin, prev, now)
                let rollSpeed = CGFloat((v * v).sum().squareRoot())
                if lippedUntilClear {
                    if now.distance(to: course.pin) > course.cupRadius * 1.6 {
                        lippedUntilClear = false
                    }
                } else if dPin <= course.cupRadius {
                    // How centered the ball's line is: perpendicular offset
                    // of its travel from the pin, not its current distance.
                    let travelU = CGVector(dx: v.x, dy: v.y).normalized
                    let toPin = CGVector(from: prev, to: course.pin)
                    let offset = abs(toPin.dx * travelU.dy - toPin.dy * travelU.dx)
                    let centered = 1 - min(offset / course.cupRadius, 1)
                    let cap = 12.5 * captureBoost * (0.5 + 0.5 * sqrt(centered))
                    if rollSpeed <= cap {
                        finish = .holed
                        frames.append(Frame(t: t, p: course.pin, h: 0))
                        break
                    } else if rollSpeed <= cap * 1.7 {
                        // Lip-out: horns around the edge and spins away.
                        let toBall = CGVector(from: course.pin, to: now)
                        let travel = CGVector(dx: v.x, dy: v.y).normalized
                        let sideSign: CGFloat = toBall.dot(travel.perpendicularRight) >= 0 ? 1 : -1
                        let turn = sideSign * (0.6 + 0.9 * (1 - centered))
                        let out = travel.rotated(by: -turn) * (rollSpeed * 0.55)
                        vel = SIMD3(Double(out.dx), Double(out.dy), 0)
                        lippedUntilClear = true
                        events.append((t, .lipOut))
                    }
                    // Faster than that: it just rolls over the hole.
                }

                if (v * v).sum().squareRoot() < 0.35 {
                    frames.append(Frame(t: t, p: now, h: 0))
                    break
                }
            }

            // Keep the ball on the property.
            let b = course.bounds
            if pos.x < Double(b.minX) || pos.x > Double(b.maxX)
                || pos.y < Double(b.minY) || pos.y > Double(b.maxY) {
                pos.x = min(max(pos.x, Double(b.minX)), Double(b.maxX))
                pos.y = min(max(pos.y, Double(b.minY)), Double(b.maxY))
                vel = .zero
                airborne = false
                pos.z = 0
                frames.append(Frame(t: t, p: point(pos), h: 0))
                break
            }

            t += dt
            if t >= nextFrame {
                frames.append(Frame(t: t, p: point(pos), h: CGFloat(max(pos.z, 0))))
                nextFrame += 1.0 / 60
            }
        }

        let end = finish == .holed ? course.pin : (frames.last?.p ?? start)
        return Trajectory(frames: frames, events: events, finish: finish,
                          end: end, landing: landing, waterEntry: waterEntry)
    }

    private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(from: a, to: b)
        let len2 = ab.dx * ab.dx + ab.dy * ab.dy
        guard len2 > 0.000001 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.dx + (p.y - a.y) * ab.dy) / len2))
        return p.distance(to: CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t))
    }
}
