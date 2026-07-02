import SceneKit
import UIKit

/// 3D SceneKit renderer for a hole — low chase camera behind the ball, flat-
/// shaded stylized course in the muted palette, chunky cartoon golfer.
///
/// All gameplay math stays in the 2D hole coordinate space (2 pts = 1 yd);
/// this class maps those coordinates into 3D only for rendering, so the shot
/// engine, lie detection, and putt physics are identical to the 2D build.
/// Mapping: hole (x, y) -> world (x, height, -y). Looking from tee to pin the
/// camera faces -z, so +x (screen right) matches +x in hole coords.
final class Course3DScene: NSObject {
    let hole: Hole
    let scene = SCNScene()
    let cameraNode = SCNNode()

    /// (holed, final 2D position). Called on the main thread.
    var onPuttEnded: ((Bool, CGPoint) -> Void)?

    // MARK: - Nodes

    private let ballNode = SCNNode(geometry: SCNSphere(radius: 1.1))
    private let ballBlobShadow: SCNNode
    private let golferNode = SCNNode()
    private let previewRoot = SCNNode()
    private let flagNode = SCNNode()
    private let teeNode: SCNNode
    private let focusNode = SCNNode()
    private var markerNodes: [SCNNode] = []

    // MARK: - Simulation state (2D hole coords, main thread only)

    private var ball2D: CGPoint
    private var ballH: CGFloat = 1.1
    private var ballRest: CGFloat = 1.1
    private var flight: FlightState?
    private var puttActive = false
    private var puttVelocity = CGVector.zero
    private var focusTarget: SCNVector3
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    private final class FlightState {
        let samples: [CGPoint]
        let duration: Double
        let apex: CGFloat
        let end: CGPoint
        let rollTarget: CGPoint
        let rollDuration: Double
        let completion: (CGPoint, [CGPoint]) -> Void
        var elapsed: Double = 0
        var rolling = false
        var rollElapsed: Double = 0
        var rollStart: CGPoint = .zero

        init(samples: [CGPoint], duration: Double, apex: CGFloat, end: CGPoint,
             rollTarget: CGPoint, rollDuration: Double,
             completion: @escaping (CGPoint, [CGPoint]) -> Void) {
            self.samples = samples
            self.duration = duration
            self.apex = apex
            self.end = end
            self.rollTarget = rollTarget
            self.rollDuration = rollDuration
            self.completion = completion
        }
    }

    // MARK: - Init

    init(hole: Hole) {
        self.hole = hole
        self.ball2D = hole.tee
        self.focusTarget = SCNVector3(Float(hole.tee.x), 4, Float(-hole.tee.y - 100))

        let blobGeo = SCNCylinder(radius: 1.5, height: 0.06)
        blobGeo.firstMaterial = Course3DScene.unlitMaterial(UIColor.black.withAlphaComponent(0.28))
        ballBlobShadow = SCNNode(geometry: blobGeo)

        let teeGeo = SCNCylinder(radius: 0.28, height: 0.9)
        teeGeo.firstMaterial = Course3DScene.material(0xF0EDE0)
        teeNode = SCNNode(geometry: teeGeo)

        super.init()
        buildScene()
        placeBall(at: hole.tee, onTee: true)

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// The display link retains us — call this when the view goes away.
    func tearDown() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Scene construction

    private func buildScene() {
        scene.background.contents = Course3DScene.skyImage()
        scene.fogColor = UIColor(hex: 0xE9C384)
        scene.fogStartDistance = 1000
        scene.fogEndDistance = 3200

        // Camera
        let camera = SCNCamera()
        camera.fieldOfView = 66   // vertical; portrait aspect keeps ~33° horizontal
        camera.zNear = 1
        camera.zFar = 4200
        cameraNode.camera = camera
        cameraNode.position = world(CGPoint(x: hole.tee.x, y: hole.tee.y - 46), h: 18)
        scene.rootNode.addChildNode(cameraNode)
        focusNode.position = focusTarget
        scene.rootNode.addChildNode(focusNode)

        // Golden-hour light
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(hex: 0xF0E4C0)
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.color = UIColor(hex: 0xFFEBBC)
        sun.light?.intensity = 950
        sun.light?.castsShadow = true
        sun.light?.shadowColor = UIColor.black.withAlphaComponent(0.26)
        sun.light?.shadowRadius = 6
        sun.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.eulerAngles = SCNVector3(-0.9, -0.4, 0)
        scene.rootNode.addChildNode(sun)

        // Endless ground beyond the hole
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.firstMaterial = Course3DScene.material(0x3A5226)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = -0.3
        scene.rootNode.addChildNode(floorNode)

        // The hole itself — the 2D map painted onto a plane, so the texture
        // matches Hole.lie(at:) hit detection exactly.
        let plane = SCNPlane(width: hole.sceneSize.width, height: hole.sceneSize.height)
        let groundMat = SCNMaterial()
        groundMat.diffuse.contents = courseTexture()
        groundMat.lightingModel = .lambert
        plane.firstMaterial = groundMat
        let ground = SCNNode(geometry: plane)
        ground.eulerAngles.x = -.pi / 2
        ground.position = world(CGPoint(x: hole.sceneSize.width / 2,
                                        y: hole.sceneSize.height / 2), h: 0)
        scene.rootNode.addChildNode(ground)

        buildTrees()
        buildPinAndCup()
        buildGolfer()

        // Ball
        ballNode.geometry?.firstMaterial = Course3DScene.material(0xF0EDE0)
        scene.rootNode.addChildNode(ballNode)
        scene.rootNode.addChildNode(ballBlobShadow)
        scene.rootNode.addChildNode(teeNode)
        scene.rootNode.addChildNode(previewRoot)
    }

    private func buildTrees() {
        for i in 0..<10 {
            let y = CGFloat(120 + i * 88)
            addTree(at: CGPoint(x: .random(in: 30...58), y: y + .random(in: -22...22)))
            addTree(at: CGPoint(x: hole.sceneSize.width - .random(in: 30...58),
                                y: y + .random(in: -25...25)))
        }
        // A stand behind the green to close down the view
        for _ in 0..<6 {
            addTree(at: CGPoint(x: .random(in: 140...460), y: .random(in: 935...985)))
        }
    }

    private func addTree(at p: CGPoint) {
        let tree = SCNNode()
        let height = CGFloat.random(in: 22...34)

        let trunkGeo = SCNCylinder(radius: 1.6, height: height * 0.5)
        trunkGeo.firstMaterial = Course3DScene.material(0x6E5A40)
        let trunk = SCNNode(geometry: trunkGeo)
        trunk.position.y = Float(height * 0.25)
        tree.addChildNode(trunk)

        let canopyGeo = SCNSphere(radius: CGFloat.random(in: 9...13))
        canopyGeo.firstMaterial = Course3DScene.material(0x3A5226)
        let canopy = SCNNode(geometry: canopyGeo)
        canopy.position.y = Float(height * 0.62)
        tree.addChildNode(canopy)

        let tuftGeo = SCNSphere(radius: CGFloat.random(in: 5...7.5))
        tuftGeo.firstMaterial = Course3DScene.material(0x4E6640)
        let tuft = SCNNode(geometry: tuftGeo)
        tuft.position = SCNVector3(Float.random(in: -5...5), Float(height * 0.8),
                                   Float.random(in: -3...3))
        tree.addChildNode(tuft)

        tree.position = world(p, h: 0)
        scene.rootNode.addChildNode(tree)
    }

    private func buildPinAndCup() {
        let cupGeo = SCNCylinder(radius: 3, height: 0.12)
        cupGeo.firstMaterial = Course3DScene.material(0x123018)
        let cup = SCNNode(geometry: cupGeo)
        cup.position = world(hole.pin, h: 0.07)
        scene.rootNode.addChildNode(cup)

        let poleGeo = SCNCylinder(radius: 0.4, height: 20)
        poleGeo.firstMaterial = Course3DScene.material(0xF0EDE0)
        let pole = SCNNode(geometry: poleGeo)
        pole.position.y = 10
        flagNode.addChildNode(pole)

        let clothGeo = SCNPlane(width: 7, height: 3.8)
        clothGeo.firstMaterial = Course3DScene.material(0xB5533C)
        clothGeo.firstMaterial?.isDoubleSided = true
        let cloth = SCNNode(geometry: clothGeo)
        cloth.position = SCNVector3(3.6, 17.6, 0)
        flagNode.addChildNode(cloth)

        flagNode.position = world(hole.pin, h: 0)
        scene.rootNode.addChildNode(flagNode)
    }

    /// The captain — chunky proportions, cream polo, brick backwards cap.
    private func buildGolfer() {
        func part(_ geo: SCNGeometry, _ hex: UInt32,
                  _ x: Float, _ y: Float, _ z: Float) -> SCNNode {
            geo.firstMaterial = Course3DScene.material(hex)
            let n = SCNNode(geometry: geo)
            n.position = SCNVector3(x, y, z)
            golferNode.addChildNode(n)
            return n
        }

        // Legs + shoes (front of the golfer is local -z)
        _ = part(SCNCapsule(capRadius: 0.6, height: 3.0), 0x556070, -0.62, 1.5, 0)
        _ = part(SCNCapsule(capRadius: 0.6, height: 3.0), 0x556070, 0.62, 1.5, 0)
        let shoeL = part(SCNSphere(radius: 0.62), 0xEDE3CB, -0.62, 0.35, -0.25)
        shoeL.scale = SCNVector3(1, 0.55, 1.5)
        let shoeR = part(SCNSphere(radius: 0.62), 0xEDE3CB, 0.62, 0.35, -0.25)
        shoeR.scale = SCNVector3(1, 0.55, 1.5)

        // Torso + olive band
        _ = part(SCNCapsule(capRadius: 1.35, height: 3.8), 0xF2E8D5, 0, 4.4, 0)
        _ = part(SCNCylinder(radius: 1.38, height: 0.55), 0x8E9B63, 0, 4.35, 0)

        // Arms reaching down-forward to the grip
        let armL = part(SCNCapsule(capRadius: 0.42, height: 2.8), 0xE8B98A, -1.55, 4.2, -0.7)
        armL.eulerAngles = SCNVector3(-0.75, 0, -0.55)
        let armR = part(SCNCapsule(capRadius: 0.42, height: 2.8), 0xE8B98A, 1.55, 4.2, -0.7)
        armR.eulerAngles = SCNVector3(-0.75, 0, 0.55)
        _ = part(SCNSphere(radius: 0.52), 0xE8B98A, 0.5, 2.9, -1.6)

        // Head + backwards cap + button
        _ = part(SCNSphere(radius: 1.5), 0xE8B98A, 0, 7.3, 0)
        let cap = part(SCNSphere(radius: 1.58), 0xB5533C, 0, 7.62, 0)
        cap.scale = SCNVector3(1, 0.62, 1)
        _ = part(SCNSphere(radius: 0.24), 0x9E4634, 0, 8.6, 0)
        // Backwards bill pokes out behind (local +z)
        let bill = part(SCNSphere(radius: 0.85), 0x9E4634, 0, 7.45, 1.5)
        bill.scale = SCNVector3(1, 0.22, 1.2)

        // Club angled down to the ball side
        let shaft = part(SCNCylinder(radius: 0.14, height: 4.8), 0x8C7A5A, 1.1, 1.9, -1.9)
        shaft.eulerAngles = SCNVector3(-0.35, 0, 0.45)
        _ = part(SCNBox(width: 0.95, height: 0.5, length: 0.4, chamferRadius: 0.12),
                 0x55606E, 2.15, 0.35, -2.45)

        scene.rootNode.addChildNode(golferNode)
    }

    // MARK: - Camera + golfer aiming

    /// Move the chase camera and golfer behind `spot`, facing along `aimDir`.
    func aim(spot: CGPoint, aimDir: CGVector, kind: ShotKind, animated: Bool) {
        let aimU = aimDir.normalized
        let back: CGFloat, height: CGFloat, ahead: CGFloat, aside: CGFloat
        switch kind {
        case .putt: (back, height, ahead, aside) = (26, 12, 46, -6.5)
        case .chip: (back, height, ahead, aside) = (30, 12, 62, -4.5)
        case .meter: (back, height, ahead, aside) = (46, 18, 96, -3.4)
        }

        let camPos = world(spot + aimU * -back, h: height)
        let golfSpot = spot + aimU.perpendicularRight * aside + aimU * -0.8
        focusTarget = world(spot + aimU * ahead, h: 0)

        let apply = {
            self.cameraNode.position = camPos
            self.golferNode.position = self.world(golfSpot, h: 0)
            self.golferNode.look(at: self.world(spot + aimU * 80, h: 0),
                                 up: SCNVector3(0, 1, 0),
                                 localFront: SCNVector3(0, 0, -1))
        }
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.9
            SCNTransaction.animationTimingFunction =
                CAMediaTimingFunction(name: .easeInEaseOut)
            apply()
            SCNTransaction.commit()
        } else {
            apply()
        }
    }

    // MARK: - Ball placement & markers

    func placeBall(at p: CGPoint, onTee: Bool) {
        flight = nil
        puttActive = false
        puttVelocity = .zero
        ball2D = p
        ballRest = onTee ? 1.95 : 1.1
        ballH = ballRest
        ballNode.removeAllActions()
        ballNode.opacity = 1
        ballNode.scale = SCNVector3(1, 1, 1)
        teeNode.isHidden = !onTee
        teeNode.position = world(p, h: 0.45)
        syncBallNode()
    }

    func addMarker(at p: CGPoint, teamColorHex: UInt32) {
        let geo = SCNSphere(radius: 1.0)
        geo.firstMaterial = SCNMaterial()
        geo.firstMaterial?.diffuse.contents = UIColor(hex: teamColorHex)
        geo.firstMaterial?.lightingModel = .lambert
        let marker = SCNNode(geometry: geo)
        marker.position = world(p, h: 1.0)
        scene.rootNode.addChildNode(marker)
        markerNodes.append(marker)
    }

    func clearMarkers() {
        markerNodes.forEach { $0.removeFromParentNode() }
        markerNodes.removeAll()
    }

    // MARK: - Flight (driver / iron / chip)

    /// Same path math as the 2D build: quad-curve ground track + samples for
    /// water-entry detection, with height added as a parabola for the arc.
    func animateShot(from: CGPoint, aim: CGVector, carryYards: Double,
                     lateralYards: Double, flavor: ShotFlavor, apexScale: CGFloat,
                     completion: @escaping (CGPoint, [CGPoint]) -> Void) {
        removePreview()
        ball2D = from
        ballRest = 1.1

        let aimU = aim.normalized
        let perp = aimU.perpendicularRight
        let d = CGFloat(carryYards) * Hole.pointsPerYard
        let lat = CGFloat(lateralYards) * Hole.pointsPerYard

        var end = from + aimU * d + perp * lat
        end.x = min(max(end.x, 42), hole.sceneSize.width - 42)
        end.y = min(max(end.y, 42), hole.sceneSize.height - 42)
        let control = from + aimU * (d * 0.55)

        var samples: [CGPoint] = []
        for i in 0...30 {
            let t = CGFloat(i) / 30
            samples.append(quadPoint(t: t, p0: from, c: control, p1: end))
        }

        let grounded = flavor == .topped || flavor == .chunk || flavor == .fat
        let roll = grounded ? aimU * 8 : aimU * (d * 0.05)
        var final = end + roll
        final.x = min(max(final.x, 42), hole.sceneSize.width - 42)
        final.y = min(max(final.y, 42), hole.sceneSize.height - 42)
        if hole.lie(at: end) != .water && hole.lie(at: final) == .water {
            final = end
        }

        flight = FlightState(
            samples: samples,
            duration: grounded ? 0.55 : 0.8 + Double(d) / 900,
            apex: grounded ? 0 : max(6, d * 0.085 * apexScale),
            end: end,
            rollTarget: final,
            rollDuration: 0.35,
            completion: completion
        )
    }

    // MARK: - Putting (same constants as the 2D build)

    func startPutt(velocity: CGVector) {
        removePreview()
        puttVelocity = velocity
        puttActive = true
    }

    // MARK: - Aim preview (in-world dots along the line)

    func showPreview(from: CGPoint, direction: CGVector, power: Double, isPutt: Bool) {
        removePreview()
        let dir = direction.normalized
        let travel: CGFloat = isPutt
            ? CGFloat(power) * 480 / 1.9
            : CGFloat(power * Club.wedge.maxYards) * Hole.pointsPerYard

        let dotCount = max(Int(travel / 16), 2)
        for i in 1...dotCount {
            let t = CGFloat(i) / CGFloat(dotCount)
            let geo = SCNCylinder(radius: 0.75, height: 0.14)
            geo.firstMaterial = Course3DScene.unlitMaterial(
                UIColor(hex: 0xEDE8D4).withAlphaComponent(0.35 + 0.55 * (1 - t)))
            let dot = SCNNode(geometry: geo)
            dot.position = world(from + dir * (travel * t), h: 0.2)
            previewRoot.addChildNode(dot)
        }
    }

    func removePreview() {
        previewRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    // MARK: - Reactions (restrained: rings and hops, no confetti)

    func splash(at p: CGPoint) {
        ring(at: p, hex: 0xF0EDE0, delay: 0)
        ring(at: p, hex: 0xF0EDE0, delay: 0.18)
        ballNode.runAction(.fadeOut(duration: 0.25))
        ballBlobShadow.opacity = 0
    }

    func celebrate(at p: CGPoint) {
        ring(at: p, hex: 0xEDE8D4, delay: 0)
        ring(at: p, hex: 0xEDE8D4, delay: 0.15)
        flagNode.runAction(.sequence([
            .moveBy(x: 0, y: 2.2, z: 0, duration: 0.12),
            .moveBy(x: 0, y: -2.2, z: 0, duration: 0.18)
        ]))
    }

    private func ring(at p: CGPoint, hex: UInt32, delay: TimeInterval) {
        let geo = SCNTorus(ringRadius: 1.6, pipeRadius: 0.14)
        geo.firstMaterial = Course3DScene.unlitMaterial(
            UIColor(hex: hex).withAlphaComponent(0.75))
        let node = SCNNode(geometry: geo)
        node.position = world(p, h: 0.4)
        node.opacity = 0
        scene.rootNode.addChildNode(node)
        node.runAction(.sequence([
            .wait(duration: delay),
            .fadeIn(duration: 0.05),
            .group([.scale(to: 3.4, duration: 0.55), .fadeOut(duration: 0.55)]),
            .removeFromParentNode()
        ]))
    }

    // MARK: - Per-frame update (main thread via CADisplayLink)

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick > 0 ? min(now - lastTick, 1.0 / 30.0) : 0
        lastTick = now
        guard dt > 0 else { return }

        if let f = flight {
            stepFlight(f, dt: dt)
        } else if puttActive {
            stepPutt(dt: CGFloat(dt))
        }

        // Camera focus eases toward the ball while it moves, back to the
        // aim point when things are still.
        let inMotion = flight != nil || puttActive
        let target = inMotion
            ? SCNVector3(ballNode.position.x, ballNode.position.y + 2, ballNode.position.z)
            : focusTarget
        let k = Float(1 - exp(-6 * dt))
        focusNode.position = SCNVector3(
            focusNode.position.x + (target.x - focusNode.position.x) * k,
            focusNode.position.y + (target.y - focusNode.position.y) * k,
            focusNode.position.z + (target.z - focusNode.position.z) * k
        )
        cameraNode.look(at: focusNode.position, up: SCNVector3(0, 1, 0),
                        localFront: SCNVector3(0, 0, -1))
    }

    private func stepFlight(_ f: FlightState, dt: Double) {
        if !f.rolling {
            f.elapsed += dt
            let t = min(CGFloat(f.elapsed / f.duration), 1)
            ball2D = samplePoint(f.samples, t: t)
            ballH = ballRest + f.apex * 4 * t * (1 - t)
            if t >= 1 {
                f.rolling = true
                f.rollStart = f.end
                ballH = ballRest
            }
        } else {
            f.rollElapsed += dt
            let s = min(CGFloat(f.rollElapsed / f.rollDuration), 1)
            let eased = 1 - (1 - s) * (1 - s)
            ball2D = CGPoint(
                x: f.rollStart.x + (f.rollTarget.x - f.rollStart.x) * eased,
                y: f.rollStart.y + (f.rollTarget.y - f.rollStart.y) * eased
            )
            if s >= 1 {
                flight = nil
                if hole.lie(at: f.rollTarget) == .water {
                    splash(at: f.rollTarget)
                }
                f.completion(f.rollTarget, f.samples)
            }
        }
        syncBallNode()
    }

    private func stepPutt(dt: CGFloat) {
        // Exponential friction + constant slope drift while on the green.
        puttVelocity = puttVelocity * CGFloat(exp(-1.9 * Double(dt)))
        if hole.lie(at: ball2D) == .green {
            puttVelocity = puttVelocity + hole.greenSlope * dt
        } else {
            // Fringe/rough kills pace fast
            puttVelocity = puttVelocity * CGFloat(exp(-2.6 * Double(dt)))
        }

        var pos = ball2D + puttVelocity * dt
        pos.x = min(max(pos.x, 42), hole.sceneSize.width - 42)
        pos.y = min(max(pos.y, 42), hole.sceneSize.height - 42)
        ball2D = pos
        ballH = ballRest

        let speed = puttVelocity.length
        let cupDist = pos.distance(to: hole.pin)

        if cupDist <= hole.cupRadius {
            if speed < 110 {
                sinkBall()
                return
            } else {
                // Lip out — horn around the cup and keep rolling, slower.
                Haptics.tick()
                let away = CGVector(from: hole.pin, to: pos).normalized
                puttVelocity = (away * (speed * 0.45))
                    + (away.perpendicularRight * (speed * 0.25))
            }
        }

        if speed < 6 {
            puttActive = false
            puttVelocity = .zero
            onPuttEnded?(false, ball2D)
        }
        syncBallNode()
    }

    private func sinkBall() {
        puttActive = false
        puttVelocity = .zero
        ballBlobShadow.opacity = 0
        let drop = SCNAction.group([
            .move(to: world(hole.pin, h: 0.2), duration: 0.15),
            .scale(to: 0.2, duration: 0.15),
            .fadeOut(duration: 0.18)
        ])
        ballNode.runAction(drop) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onPuttEnded?(true, self.hole.pin)
            }
        }
    }

    private func syncBallNode() {
        ballNode.position = world(ball2D, h: ballH)
        ballBlobShadow.position = world(ball2D, h: 0.1)
        let air = max(ballH - ballRest, 0)
        ballBlobShadow.opacity = CGFloat(max(0.05, 0.32 - Double(air) / 220))
        let spread = 1 + air / 45
        ballBlobShadow.scale = SCNVector3(Float(spread), 1, Float(spread))
    }

    // MARK: - Geometry helpers

    private func world(_ p: CGPoint, h: CGFloat) -> SCNVector3 {
        SCNVector3(Float(p.x), Float(h), Float(-p.y))
    }

    private func samplePoint(_ samples: [CGPoint], t: CGFloat) -> CGPoint {
        let scaled = t * CGFloat(samples.count - 1)
        let i = min(Int(scaled), samples.count - 2)
        let frac = scaled - CGFloat(i)
        let a = samples[i], b = samples[i + 1]
        return CGPoint(x: a.x + (b.x - a.x) * frac, y: a.y + (b.y - a.y) * frac)
    }

    private func quadPoint(t: CGFloat, p0: CGPoint, c: CGPoint, p1: CGPoint) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x
        let y = mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y
        return CGPoint(x: x, y: y)
    }

    private static func material(_ hex: UInt32) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(hex: hex)
        m.lightingModel = .lambert
        return m
    }

    private static func unlitMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        return m
    }

    // MARK: - Painted textures

    /// Banded golden-hour sky, flat colors — no gradients, per the art rules.
    private static func skyImage() -> UIImage {
        let size = CGSize(width: 16, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(hex: 0xF3DCA9).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: 16, height: 240))
            cg.setFillColor(UIColor(hex: 0xEFD196).cgColor)
            cg.fill(CGRect(x: 0, y: 240, width: 16, height: 140))
            cg.setFillColor(UIColor(hex: 0xE9C384).cgColor)
            cg.fill(CGRect(x: 0, y: 380, width: 16, height: 132))
        }
    }

    /// The hole map painted in the muted palette, in hole coordinates —
    /// exactly the shapes `Hole.lie(at:)` tests against.
    private func courseTexture() -> UIImage {
        let size = hole.sceneSize
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        let outline = UIColor(hex: 0x2A3A1C).cgColor

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Flip so hole y=0 lands at the image bottom; after the plane is
            // rotated flat, image top = far end (-z), matching world z = -y.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)

            // Rough base with deep tree-line strips down the sides and
            // behind the green (matches treeMarginX in Hole.lie(at:)).
            cg.setFillColor(UIColor(hex: 0x4F6B33).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            cg.setFillColor(UIColor(hex: 0x3A5226).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: hole.treeMarginX, height: size.height))
            cg.fill(CGRect(x: size.width - hole.treeMarginX, y: 0,
                           width: hole.treeMarginX, height: size.height))
            cg.fill(CGRect(x: 0, y: size.height - 40, width: size.width, height: 40))

            // Fairway + mow stripes
            cg.setFillColor(UIColor(hex: 0x8FB35A).cgColor)
            cg.addPath(hole.fairwayPath)
            cg.fillPath()
            cg.saveGState()
            cg.addPath(hole.fairwayPath)
            cg.clip()
            cg.setFillColor(UIColor(hex: 0x9BBE66).withAlphaComponent(0.45).cgColor)
            var x: CGFloat = 0
            while x < size.width {
                cg.fill(CGRect(x: x, y: 0, width: 32, height: size.height))
                x += 64
            }
            cg.restoreGState()
            cg.setStrokeColor(outline)
            cg.setLineWidth(3.5)
            cg.addPath(hole.fairwayPath)
            cg.strokePath()

            // Water
            for rect in hole.waterRects {
                cg.setFillColor(UIColor(hex: 0x6E97AC).cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(outline)
                cg.strokeEllipse(in: rect)
            }

            // Bunkers
            for b in hole.bunkers {
                let r = CGRect(x: b.center.x - b.radius, y: b.center.y - b.radius,
                               width: b.radius * 2, height: b.radius * 2)
                cg.setFillColor(UIColor(hex: 0xC7A16B).cgColor)
                cg.fillEllipse(in: r)
                cg.setStrokeColor(outline)
                cg.strokeEllipse(in: r)
            }

            // Fringe + green
            let fringeR = hole.greenRadius + hole.fringeWidth
            let fringeRect = CGRect(x: hole.pin.x - fringeR, y: hole.pin.y - fringeR,
                                    width: fringeR * 2, height: fringeR * 2)
            cg.setFillColor(UIColor(hex: 0x9CBE63).cgColor)
            cg.fillEllipse(in: fringeRect)
            cg.setStrokeColor(outline)
            cg.strokeEllipse(in: fringeRect)

            let greenRect = CGRect(x: hole.pin.x - hole.greenRadius,
                                   y: hole.pin.y - hole.greenRadius,
                                   width: hole.greenRadius * 2,
                                   height: hole.greenRadius * 2)
            cg.setFillColor(UIColor(hex: 0xA9C871).cgColor)
            cg.fillEllipse(in: greenRect)
            cg.setStrokeColor(outline)
            cg.strokeEllipse(in: greenRect)

            // Slope contours on the green (perpendicular to the drift)
            cg.saveGState()
            cg.addEllipse(in: greenRect)
            cg.clip()
            let slope = hole.greenSlope.normalized
            let across = CGVector(dx: slope.dy, dy: -slope.dx)
            cg.setStrokeColor(UIColor(hex: 0x93B25F).withAlphaComponent(0.8).cgColor)
            cg.setLineWidth(2)
            for k in [-45.0, -15.0, 15.0, 45.0] {
                let c = hole.pin + slope * CGFloat(k)
                let a = c + across * 90
                let b = c + across * -90
                cg.move(to: a)
                cg.addLine(to: b)
                cg.strokePath()
            }
            cg.restoreGState()

            // Tee box — a subtle lighter patch, no outline (up close the
            // camera magnifies it hugely, so outlines read as stray bands)
            let teeRect = CGRect(x: hole.tee.x - 28, y: hole.tee.y - 17,
                                 width: 56, height: 26)
            cg.setFillColor(UIColor(hex: 0x9BBE66).withAlphaComponent(0.6).cgColor)
            cg.addPath(UIBezierPath(roundedRect: teeRect, cornerRadius: 8).cgPath)
            cg.fillPath()
        }
    }
}
