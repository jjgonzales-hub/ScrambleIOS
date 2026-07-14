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

    private let ballNode = SCNNode(geometry: SCNSphere(radius: 0.5))
    private let ballBlobShadow: SCNNode
    private let golferNode = SCNNode()
    private let torsoNode = SCNNode()
    private let swingNode = SCNNode()
    private let swooshNode = SCNNode()
    private let driverClub = SCNNode()
    private let putterClub = SCNNode()
    private let previewRoot = SCNNode()
    private let tracerRoot = SCNNode()
    private let aimLineRoot = SCNNode()
    private let greenGridNode = SCNNode()
    private let flagNode = SCNNode()
    private let teeNode: SCNNode
    private let focusNode = SCNNode()
    private var markerNodes: [SCNNode] = []

    // MARK: - Swing animation state

    /// Meter power 0…1 → backswing angle, polled every frame while aiming.
    var swingPoseProvider: (() -> CGFloat)?
    /// Full-swing drag 0…1 (Golf Dreams-style pull) — the finger IS the
    /// backswing. Overrides the provider while set.
    private var manualBackswing: CGFloat?
    /// Putt/chip pull-back 0…1 — overrides everything while dragging.
    private var manualPullback: CGFloat?
    /// True while a release animation owns the swing node.
    private var isSwinging = false

    // Composed swing poses (euler x, y, z at full amount). The z sweep is
    // the arm arc, y is the shoulder turn wrapping the club around the
    // body, x tilts the club toward the swing plane — together they read
    // as an actual golf swing instead of a flat fan.
    private static let backswingPose = SCNVector3(-0.35, -0.95, 2.15)
    private static let followPose = SCNVector3(-0.5, 1.05, -2.5)
    private static let puttBackPose = SCNVector3(0, -0.15, 0.62)

    // MARK: - Simulation state (2D hole coords, main thread only)

    private var ball2D: CGPoint
    private var ballH: CGFloat = 0.45
    private var ballRest: CGFloat = 0.45
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
        let tracerHex: UInt32
        let completion: (CGPoint, [CGPoint]) -> Void
        var elapsed: Double = 0
        var rolling = false
        var rollElapsed: Double = 0
        var rollStart: CGPoint = .zero

        init(samples: [CGPoint], duration: Double, apex: CGFloat, end: CGPoint,
             rollTarget: CGPoint, rollDuration: Double, tracerHex: UInt32,
             completion: @escaping (CGPoint, [CGPoint]) -> Void) {
            self.samples = samples
            self.duration = duration
            self.apex = apex
            self.end = end
            self.rollTarget = rollTarget
            self.rollDuration = rollDuration
            self.tracerHex = tracerHex
            self.completion = completion
        }
    }

    // MARK: - Init

    init(hole: Hole) {
        self.hole = hole
        self.ball2D = hole.tee
        self.focusTarget = SCNVector3(Float(hole.tee.x), 4, Float(-hole.tee.y - 100))

        let blobGeo = SCNCylinder(radius: 0.85, height: 0.06)
        blobGeo.firstMaterial = Course3DScene.unlitMaterial(UIColor.black.withAlphaComponent(0.28))
        ballBlobShadow = SCNNode(geometry: blobGeo)

        let teeGeo = SCNCylinder(radius: 0.17, height: 0.7)
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
        scene.fogColor = UIColor(hex: 0xEBDCAE)
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
        ambient.light?.color = UIColor(hex: 0xF2EDD8)
        ambient.light?.intensity = 480
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.color = UIColor(hex: 0xFFF3D6)
        sun.light?.intensity = 820
        sun.light?.castsShadow = true
        sun.light?.shadowColor = UIColor.black.withAlphaComponent(0.26)
        sun.light?.shadowRadius = 6
        sun.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.eulerAngles = SCNVector3(-0.9, -0.4, 0)
        scene.rootNode.addChildNode(sun)

        // Endless ground beyond the hole
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.firstMaterial = Course3DScene.material(0x1F3B2E)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = -0.35
        scene.rootNode.addChildNode(floorNode)

        // The hole itself — faceted low-poly terrain. Face colors are
        // sampled from Hole.lie(at:) so what you see is exactly what the
        // gameplay rules, with per-face shade jitter for the facet look.
        scene.rootNode.addChildNode(buildTerrain())

        buildTrees()
        buildClouds()
        buildPinAndCup()
        buildGreenGrid()
        buildGolfer()

        // Ball — slight gloss so it reads as a ball, not a blob
        let ballMat = SCNMaterial()
        ballMat.diffuse.contents = UIColor.white
        ballMat.lightingModel = .blinn
        ballMat.specular.contents = UIColor(white: 1, alpha: 0.4)
        ballMat.shininess = 14
        ballMat.emission.contents = UIColor(white: 1, alpha: 0.22)
        ballNode.geometry?.firstMaterial = ballMat
        scene.rootNode.addChildNode(ballNode)
        scene.rootNode.addChildNode(ballBlobShadow)
        scene.rootNode.addChildNode(teeNode)
        scene.rootNode.addChildNode(previewRoot)
        scene.rootNode.addChildNode(tracerRoot)
        scene.rootNode.addChildNode(aimLineRoot)
    }

    /// Flat-shaded triangle mesh over the hole. Vertices are duplicated
    /// per face (hard normals + one color per face) — that faceting IS the
    /// art style, no texture needed.
    private func buildTerrain() -> SCNNode {
        let cols = 34, rows = 56
        let dx = hole.sceneSize.width / CGFloat(cols)
        let dy = hole.sceneSize.height / CGFloat(rows)

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [Float] = []
        positions.reserveCapacity(cols * rows * 6)

        func vertex(_ p: CGPoint) -> SCNVector3 {
            SCNVector3(Float(p.x), Float(groundHeight(p)), Float(-p.y))
        }

        func addFace(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint,
                     cellX: Int, cellY: Int, alt: Bool) {
            var va = vertex(a), vb = vertex(b), vc = vertex(c)
            var n = cross(sub(vb, va), sub(vc, va))
            if n.y < 0 { swap(&vb, &vc); n = cross(sub(vb, va), sub(vc, va)) }
            let len = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 0.0001)
            let normal = SCNVector3(n.x / len, n.y / len, n.z / len)

            let centroid = CGPoint(x: (a.x + b.x + c.x) / 3,
                                   y: (a.y + b.y + c.y) / 3)
            var rgb = faceColor(at: centroid)
            let seed = sin(Double(cellX) * 127.1 + Double(cellY) * 311.7
                           + (alt ? 17.3 : 0)) * 43758.5453
            let jitter = Float(0.92 + 0.08 * (seed - floor(seed)))
            rgb = (rgb.0 * jitter, rgb.1 * jitter, rgb.2 * jitter)

            for v in [va, vb, vc] {
                positions.append(v)
                normals.append(normal)
                colors.append(contentsOf: [rgb.0, rgb.1, rgb.2, 1])
            }
        }

        for r in 0..<rows {
            for c in 0..<cols {
                let x0 = CGFloat(c) * dx, y0 = CGFloat(r) * dy
                let p00 = CGPoint(x: x0, y: y0)
                let p10 = CGPoint(x: x0 + dx, y: y0)
                let p01 = CGPoint(x: x0, y: y0 + dy)
                let p11 = CGPoint(x: x0 + dx, y: y0 + dy)
                addFace(p00, p10, p11, cellX: c, cellY: r, alt: false)
                addFace(p00, p11, p01, cellX: c, cellY: r, alt: true)
            }
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData, semantic: .color,
            vectorCount: positions.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: 4,
            dataOffset: 0, dataStride: 16)
        let indices = (0..<Int32(positions.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource],
                                   elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white
        material.lightingModel = .lambert
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private func faceColor(at p: CGPoint) -> (Float, Float, Float) {
        func rgb(_ hex: UInt32) -> (Float, Float, Float) {
            (Float((hex >> 16) & 0xFF) / 255,
             Float((hex >> 8) & 0xFF) / 255,
             Float(hex & 0xFF) / 255)
        }
        switch hole.lie(at: p) {
        case .water: return rgb(0x5D9FD6)
        case .bunker: return rgb(0xEAD2A0)
        case .green: return rgb(0xA8D672)
        case .fringe: return rgb(0x8CC868)
        case .fairway, .tee:
            return Int(p.x / 32) % 2 == 0 ? rgb(0x82C15D) : rgb(0x90CB6B)
        case .trees: return rgb(0x1F3B2E)
        case .rough:
            return (p.x < hole.treeMarginX + 20
                    || p.x > hole.sceneSize.width - hole.treeMarginX - 20)
                ? rgb(0x274D33) : rgb(0x2E5E3E)
        }
    }

    private func sub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    private func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        SCNVector3(a.y * b.z - a.z * b.y,
                   a.z * b.x - a.x * b.z,
                   a.x * b.y - a.y * b.x)
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

    /// Puffy flat-white cartoon clouds drifting slowly over the course.
    private func buildClouds() {
        for _ in 0..<6 {
            let cloud = SCNNode()
            let puffs = Int.random(in: 3...4)
            for p in 0..<puffs {
                let r = CGFloat.random(in: 9...16)
                let geo = SCNSphere(radius: r)
                geo.firstMaterial = Course3DScene.unlitMaterial(
                    UIColor.white.withAlphaComponent(0.92))
                let puff = SCNNode(geometry: geo)
                puff.position = SCNVector3(Float(p) * Float(r) * 1.05
                                           - Float(puffs) * 7,
                                           Float.random(in: -2...3),
                                           Float.random(in: -3...3))
                puff.scale = SCNVector3(1, 0.55, 0.8)
                cloud.addChildNode(puff)
            }
            cloud.position = SCNVector3(Float.random(in: -100...700),
                                        Float.random(in: 135...195),
                                        Float.random(in: -950 ... -250))
            let drift = SCNAction.moveBy(x: 60, y: 0, z: 0, duration: 95)
            cloud.runAction(.repeatForever(.sequence([drift, drift.reversed()])))
            scene.rootNode.addChildNode(cloud)
        }
    }

    /// Low-poly pine: boxy trunk + three stacked square pyramids, middle
    /// tier rotated 45° — flat faces catch the light like the terrain.
    private func addTree(at p: CGPoint) {
        let tree = SCNNode()
        let height = CGFloat.random(in: 22...34)

        let trunkGeo = SCNBox(width: 2.2, height: height * 0.4, length: 2.2,
                              chamferRadius: 0)
        trunkGeo.firstMaterial = Course3DScene.material(0x6E5A40)
        let trunk = SCNNode(geometry: trunkGeo)
        trunk.position.y = Float(height * 0.2)
        tree.addChildNode(trunk)

        let baseR = CGFloat.random(in: 8.5...11.5)
        let tiers: [(CGFloat, CGFloat, UInt32)] = [
            (1.0, 0.28, 0x2E5E3E),
            (0.72, 0.5, 0x3C7A4C),
            (0.46, 0.7, 0x4CAF50)
        ]
        for (i, tier) in tiers.enumerated() {
            let r = baseR * tier.0
            let geo = SCNPyramid(width: r * 2, height: height * 0.34,
                                 length: r * 2)
            geo.firstMaterial = Course3DScene.material(tier.2)
            let n = SCNNode(geometry: geo)
            n.position.y = Float(height * tier.1)
            if i % 2 == 1 { n.eulerAngles.y = .pi / 4 }
            tree.addChildNode(n)
        }

        tree.eulerAngles.y = Float.random(in: 0...(2 * .pi))
        tree.position = world(p, h: 0)
        scene.rootNode.addChildNode(tree)
    }

    private func buildPinAndCup() {
        let cupGeo = SCNCylinder(radius: 2.2, height: 0.12)
        cupGeo.firstMaterial = Course3DScene.material(0x123018)
        let cup = SCNNode(geometry: cupGeo)
        cup.position = world(hole.pin, h: 0.07)
        scene.rootNode.addChildNode(cup)

        let poleGeo = SCNCylinder(radius: 0.4, height: 20)
        poleGeo.firstMaterial = Course3DScene.material(0xFFFFFF)
        let pole = SCNNode(geometry: poleGeo)
        pole.position.y = 10
        flagNode.addChildNode(pole)

        // Cloth hangs off a pivot at the pole so it can waggle in the wind
        let clothGeo = SCNPlane(width: 7, height: 3.8)
        clothGeo.firstMaterial = Course3DScene.material(0xFF6B6B)
        clothGeo.firstMaterial?.isDoubleSided = true
        let cloth = SCNNode(geometry: clothGeo)
        cloth.position = SCNVector3(3.6, 17.6, 0)
        let clothPivot = SCNNode()
        clothPivot.addChildNode(cloth)
        flagNode.addChildNode(clothPivot)
        let sway1 = SCNAction.rotateTo(x: 0, y: 0.28, z: 0, duration: 1.7)
        sway1.timingMode = .easeInEaseOut
        let sway2 = SCNAction.rotateTo(x: 0, y: -0.12, z: 0, duration: 1.7)
        sway2.timingMode = .easeInEaseOut
        clothPivot.runAction(.repeatForever(.sequence([sway1, sway2])))

        flagNode.position = world(hole.pin, h: 0)
        scene.rootNode.addChildNode(flagNode)
    }

    /// Green read: a field of soft dots across the green that drift in the
    /// slope direction — flow direction shows the break, flow speed shows
    /// how strong it is. Shown only while putting.
    private func buildGreenGrid() {
        let slope = hole.greenSlope
        let dir = slope.normalized
        let strength = slope.length                       // pts/s² drift
        let travel = dir * 9
        let cycle = max(Double(26 / max(strength, 3)), 0.9)

        var index = 0
        for ring in stride(from: CGFloat(12), through: hole.greenRadius - 6, by: 10) {
            let count = max(Int(ring / 4), 6)
            for i in 0..<count {
                let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
                    + (ring / 13) * 0.35
                let p = CGPoint(x: hole.pin.x + cos(angle) * ring,
                                y: hole.pin.y + sin(angle) * ring)
                guard hole.lie(at: p) == .green,
                      p.distance(to: hole.pin) > 10 else { continue }

                let geo = SCNCylinder(radius: 0.55, height: 0.1)
                geo.firstMaterial = Course3DScene.unlitMaterial(
                    UIColor(hex: 0xF5EFDA).withAlphaComponent(0.55))
                let dot = SCNNode(geometry: geo)
                dot.position = world(p, h: 0.18)
                dot.opacity = 0

                let move = SCNAction.moveBy(x: CGFloat(travel.dx), y: 0,
                                            z: CGFloat(-travel.dy),
                                            duration: cycle)
                let fades = SCNAction.sequence([
                    .fadeOpacity(to: 0.9, duration: cycle * 0.25),
                    .wait(duration: cycle * 0.45),
                    .fadeOpacity(to: 0, duration: cycle * 0.3)
                ])
                let reset = SCNAction.moveBy(x: CGFloat(-travel.dx), y: 0,
                                             z: CGFloat(travel.dy), duration: 0)
                dot.runAction(.sequence([
                    .wait(duration: Double(index % 6) * cycle / 6),
                    .repeatForever(.sequence([.group([move, fades]), reset]))
                ]))
                greenGridNode.addChildNode(dot)
                index += 1
            }
        }
        greenGridNode.isHidden = true
        scene.rootNode.addChildNode(greenGridNode)
    }

    /// The captain — chunky proportions, cream polo, brick backwards cap.
    /// Arms + hands + club live inside `swingNode`, pivoted at the
    /// shoulders, so rotating that one node around local z is the swing:
    /// positive = backswing (club sweeps up to his right), negative =
    /// follow-through.
    private func buildGolfer() {
        func part(_ geo: SCNGeometry, _ hex: UInt32,
                  _ x: Float, _ y: Float, _ z: Float,
                  in parent: SCNNode) -> SCNNode {
            geo.firstMaterial = Course3DScene.material(hex)
            let n = SCNNode(geometry: geo)
            n.position = SCNVector3(x, y, z)
            parent.addChildNode(n)
            return n
        }

        // Soft blob shadow to ground him, like the ball's
        let blobGeo = SCNCylinder(radius: 2.6, height: 0.05)
        blobGeo.firstMaterial = Course3DScene.unlitMaterial(
            UIColor.black.withAlphaComponent(0.2))
        let blob = SCNNode(geometry: blobGeo)
        blob.position = SCNVector3(0, 0.04, -0.3)
        golferNode.addChildNode(blob)

        // Legs + shoes (front of the golfer is local -z)
        _ = part(SCNCapsule(capRadius: 0.6, height: 3.0), 0x556070, -0.62, 1.5, 0, in: golferNode)
        _ = part(SCNCapsule(capRadius: 0.6, height: 3.0), 0x556070, 0.62, 1.5, 0, in: golferNode)
        let shoeL = part(SCNSphere(radius: 0.62), 0xEDE3CB, -0.62, 0.35, -0.25, in: golferNode)
        shoeL.scale = SCNVector3(1, 0.55, 1.5)
        let shoeR = part(SCNSphere(radius: 0.62), 0xEDE3CB, 0.62, 0.35, -0.25, in: golferNode)
        shoeR.scale = SCNVector3(1, 0.55, 1.5)

        // Torso + olive band live in torsoNode so the body can coil
        // (rotate around Y), sway for weight shift, and squish — the legs
        // stay planted and the head stays still above it.
        golferNode.addChildNode(torsoNode)
        _ = part(SCNCapsule(capRadius: 1.35, height: 3.8), 0xF2E8D5, 0, 4.4, 0, in: torsoNode)
        _ = part(SCNCylinder(radius: 1.38, height: 0.55), 0x8E9B63, 0, 4.35, 0, in: torsoNode)

        // Head + backwards cap + button + bill (local +z = toward camera)
        _ = part(SCNSphere(radius: 1.5), 0xE8B98A, 0, 7.3, 0, in: golferNode)
        let cap = part(SCNSphere(radius: 1.58), 0xB5533C, 0, 7.62, 0, in: golferNode)
        cap.scale = SCNVector3(1, 0.62, 1)
        _ = part(SCNSphere(radius: 0.24), 0x9E4634, 0, 8.6, 0, in: golferNode)
        let bill = part(SCNSphere(radius: 0.85), 0x9E4634, 0, 7.45, 1.5, in: golferNode)
        bill.scale = SCNVector3(1, 0.22, 1.2)

        // ---- Swing assembly (pivot at the shoulders) ----
        // Child of the torso, so the coil carries the arms and club.
        swingNode.position = SCNVector3(0, 5.3, -0.3)
        torsoNode.addChildNode(swingNode)

        // Cartoon swoosh crescent in the swing plane — flashes during the
        // downswing as the motion-blur read on the club head.
        let swooshPath = UIBezierPath()
        swooshPath.addArc(withCenter: .zero, radius: 5.3,
                          startAngle: -2.2, endAngle: -0.5, clockwise: true)
        swooshPath.addArc(withCenter: .zero, radius: 3.9,
                          startAngle: -0.5, endAngle: -2.2, clockwise: false)
        swooshPath.close()
        let swooshGeo = SCNShape(path: swooshPath, extrusionDepth: 0.05)
        swooshGeo.firstMaterial = Course3DScene.unlitMaterial(
            UIColor(hex: 0xF5EFDA).withAlphaComponent(0.9))
        swooshNode.geometry = swooshGeo
        swooshNode.position = SCNVector3(0, 0, -1.7)
        swooshNode.opacity = 0
        swingNode.addChildNode(swooshNode)

        let armL = part(SCNCapsule(capRadius: 0.42, height: 2.8), 0xE8B98A,
                        -1.55, -1.1, -0.4, in: swingNode)
        armL.eulerAngles = SCNVector3(-0.75, 0, -0.55)
        let armR = part(SCNCapsule(capRadius: 0.42, height: 2.8), 0xE8B98A,
                        1.55, -1.1, -0.4, in: swingNode)
        armR.eulerAngles = SCNVector3(-0.75, 0, 0.55)
        _ = part(SCNSphere(radius: 0.52), 0xE8B98A, 0.5, -2.4, -1.3, in: swingNode)

        // Driver (also used for irons/wedges)
        swingNode.addChildNode(driverClub)
        let dShaft = part(SCNCylinder(radius: 0.14, height: 4.8), 0x8C7A5A,
                          1.1, -3.4, -1.6, in: driverClub)
        dShaft.eulerAngles = SCNVector3(-0.35, 0, 0.45)
        _ = part(SCNBox(width: 1.0, height: 0.52, length: 0.42, chamferRadius: 0.12),
                 0x55606E, 0.25, -2.45, 0, in: dShaft)

        // Putter — shorter, upright, flat blade
        swingNode.addChildNode(putterClub)
        let pShaft = part(SCNCylinder(radius: 0.12, height: 3.9), 0x8C7A5A,
                          0.95, -3.2, -1.45, in: putterClub)
        pShaft.eulerAngles = SCNVector3(-0.18, 0, 0.3)
        _ = part(SCNBox(width: 1.1, height: 0.4, length: 0.32, chamferRadius: 0.1),
                 0x55606E, 0.2, -2.0, 0, in: pShaft)
        putterClub.isHidden = true

        scene.rootNode.addChildNode(golferNode)
    }

    // MARK: - Swing animation API

    /// Mirror the putt/chip drag: the club draws back as the finger pulls.
    /// Pass nil (cancel/release) to ease back to address.
    func setPullback(_ amount: CGFloat?) {
        guard !isSwinging else { return }
        manualPullback = amount.map { min(max($0, 0), 1) }
    }

    /// Mirror the full-swing pull: 0…1 maps to the whole backswing arc.
    /// Pass nil (cancel) to ease back to address.
    func setBackswing(_ amount: CGFloat?) {
        guard !isSwinging else { return }
        manualBackswing = amount.map { min(max($0, 0), 1) }
    }

    enum SwingQuality {
        case pure                       // clean, balanced, full finish
        case clean                      // solid, normal finish
        case mishit(lateral: CGFloat)   // truncated finish + lurch (+1 right)
    }

    /// Full swing from the top, kinematically sequenced like a real one:
    /// the hips/torso fire first, the shoulders and club lag ~0.08s behind,
    /// `impact` fires as the club face strikes through the ball's spot,
    /// then follow-through, a held finish, and a settle back to address.
    /// Pure strikes finish tall and balanced; mishits cut the finish short
    /// and lurch in the miss direction — readable before the ball lands.
    func swingRelease(power: Double, quality: SwingQuality,
                      impact: @escaping () -> Void) {
        isSwinging = true
        manualPullback = nil
        manualBackswing = nil

        let mishit: Bool
        let lurch: CGFloat
        if case .mishit(let lateral) = quality {
            mishit = true
            lurch = lateral
        } else {
            mishit = false
            lurch = 0
        }
        let followAmount: CGFloat = mishit ? 0.55 : 1.0
        let hold = mishit ? 0.25 : 0.6
        let downDur = max(0.14 - 0.05 * power, 0.08)
        let fp = Course3DScene.followPose

        // --- Torso: unwinds FIRST, transfers weight to the front foot ---
        let torsoDown = SCNAction.group([
            .rotateTo(x: 0, y: 0.4, z: 0, duration: downDur + 0.1),
            .move(to: SCNVector3(0, 0, -0.28), duration: downDur + 0.1),
            .scale(to: 1.0, duration: downDur + 0.1)
        ])
        torsoDown.timingMode = .easeIn
        let torsoThrough = SCNAction.group([
            .rotateTo(x: 0, y: 0.95 * followAmount, z: 0, duration: 0.24),
            .move(to: SCNVector3(0, 0, -0.45), duration: 0.24)
        ])
        torsoThrough.timingMode = .easeOut
        var torsoSeq: [SCNAction] = [torsoDown, torsoThrough]
        if mishit {
            // Off-balance stumble toward the miss
            let out = SCNAction.group([
                .moveBy(x: lurch * 1.1, y: 0, z: 0, duration: 0.16),
                .rotateBy(x: 0, y: 0, z: -lurch * 0.16, duration: 0.16)
            ])
            out.timingMode = .easeOut
            let back = SCNAction.group([
                .moveBy(x: -lurch * 1.1, y: 0, z: 0, duration: 0.4),
                .rotateBy(x: 0, y: 0, z: lurch * 0.16, duration: 0.4)
            ])
            back.timingMode = .easeInEaseOut
            torsoSeq += [.wait(duration: 0.1), out, back]
        } else {
            torsoSeq.append(.wait(duration: hold))
        }
        let torsoSettle = SCNAction.group([
            .rotateTo(x: 0, y: 0, z: 0, duration: 0.8),
            .move(to: SCNVector3(0, 0, 0), duration: 0.8)
        ])
        torsoSettle.timingMode = .easeInEaseOut
        torsoSeq.append(torsoSettle)
        torsoNode.runAction(.sequence(torsoSeq))

        // --- Shoulders + club: lag behind the hips, strike, finish ---
        let down = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: downDur)
        down.timingMode = .easeIn
        let through = SCNAction.rotateTo(x: CGFloat(fp.x) * followAmount,
                                         y: CGFloat(fp.y) * followAmount,
                                         z: CGFloat(fp.z) * followAmount,
                                         duration: 0.22)
        through.timingMode = .easeOut
        let settle = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.8)
        settle.timingMode = .easeInEaseOut
        let shake = CGFloat(max(0, power - 0.5)) * 1.8

        swingNode.runAction(.sequence([
            .wait(duration: 0.08),
            down,
            .run { [weak self] _ in
                DispatchQueue.main.async {
                    impact()
                    guard let self else { return }
                    // Impact punch + swoosh + power-scaled camera shake
                    self.golferNode.runAction(.sequence([
                        .scale(to: 1.02, duration: 0.06),
                        .scale(to: 1.0, duration: 0.12)
                    ]))
                    self.swooshNode.runAction(.sequence([
                        .fadeOpacity(to: 0.5, duration: 0.03),
                        .fadeOpacity(to: 0, duration: 0.16)
                    ]))
                    self.shakeCamera(intensity: shake)
                }
            },
            through,
            .wait(duration: hold + (mishit ? 0.55 : 0)),
            settle,
            .run { [weak self] _ in
                DispatchQueue.main.async { self?.isSwinging = false }
            }
        ]))
    }

    /// Brief decaying position jitter — light around 60% power, strong 95%+.
    private func shakeCamera(intensity: CGFloat) {
        guard intensity > 0.05 else { return }
        var actions: [SCNAction] = []
        var netX: CGFloat = 0, netY: CGFloat = 0
        for i in 0..<5 {
            let f = intensity * (1 - CGFloat(i) / 5) * 0.5
            let dx = CGFloat.random(in: -f...f)
            let dy = CGFloat.random(in: -f...f) * 0.6
            netX += dx
            netY += dy
            actions.append(.moveBy(x: dx, y: dy, z: 0, duration: 0.035))
        }
        actions.append(.moveBy(x: -netX, y: -netY, z: 0, duration: 0.06))
        cameraNode.runAction(.sequence(actions))
    }

    /// Putt/chip stroke from wherever the pull-back left the club.
    func strokeRelease(power: Double, impact: @escaping () -> Void) {
        isSwinging = true
        manualPullback = nil
        manualBackswing = nil
        let follow = -(0.22 + 0.5 * CGFloat(power))
        let down = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.06)
        down.timingMode = .easeIn
        let through = SCNAction.rotateTo(x: 0, y: 0.15, z: CGFloat(follow),
                                         duration: 0.14)
        through.timingMode = .easeOut
        let settle = SCNAction.rotateTo(x: 0, y: 0, z: 0, duration: 0.35)
        settle.timingMode = .easeInEaseOut
        swingNode.runAction(.sequence([
            down,
            .run { _ in DispatchQueue.main.async(execute: impact) },
            through,
            .wait(duration: 0.45),
            settle,
            .run { [weak self] _ in
                DispatchQueue.main.async { self?.isSwinging = false }
            }
        ]))
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

        let putting = kind == .putt
        putterClub.isHidden = !putting
        driverClub.isHidden = putting
        greenGridNode.isHidden = !putting

        // Dashed aim line down the chosen line (style board). Putts use
        // the curved read line instead.
        aimLineRoot.childNodes.forEach { $0.removeFromParentNode() }
        if !putting {
            let carry: CGFloat
            if case .meter(let club) = kind {
                carry = CGFloat(club.maxYards) * Hole.pointsPerYard
            } else {
                carry = 100
            }
            let len = min(carry, spot.distance(to: hole.pin) + 24)
            var t: CGFloat = 16
            while t < len {
                let geo = SCNSphere(radius: 0.34)
                geo.firstMaterial = Course3DScene.unlitMaterial(
                    UIColor.white.withAlphaComponent(0.3 + 0.32 * (1 - t / len)))
                let dot = SCNNode(geometry: geo)
                dot.position = world(spot + aimU * t, h: 0.5)
                aimLineRoot.addChildNode(dot)
                t += 13
            }
        }

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
        clearTracer()
        flight = nil
        puttActive = false
        puttVelocity = .zero
        ball2D = p
        ballRest = onTee ? 1.0 : 0.45
        ballH = ballRest
        ballNode.removeAllActions()
        ballNode.opacity = 1
        ballNode.scale = SCNVector3(1, 1, 1)
        teeNode.isHidden = !onTee
        teeNode.position = world(p, h: 0.35)
        syncBallNode()
    }

    func addMarker(at p: CGPoint, teamColorHex: UInt32) {
        let geo = SCNSphere(radius: 0.65)
        geo.firstMaterial = SCNMaterial()
        geo.firstMaterial?.diffuse.contents = UIColor(hex: teamColorHex)
        geo.firstMaterial?.lightingModel = .lambert
        let marker = SCNNode(geometry: geo)
        marker.position = world(p, h: 0.65)
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
                     rollFactor: CGFloat, tracerHex: UInt32 = 0xF5EFDA,
                     completion: @escaping (CGPoint, [CGPoint]) -> Void) {
        removePreview()
        clearTracer()
        aimLineRoot.childNodes.forEach { $0.removeFromParentNode() }
        ball2D = from
        ballRest = 0.45

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

        // Rollout: club loft × landing surface. Greens and firm fairway
        // release the ball; rough and sand kill it dead.
        let grounded = flavor == .topped || flavor == .chunk || flavor == .fat
        let surface: CGFloat
        switch hole.lie(at: end) {
        case .green: surface = 1.35
        case .fringe: surface = 1.15
        case .fairway, .tee: surface = 1.0
        case .rough: surface = 0.45
        case .trees: surface = 0.35
        case .bunker: surface = 0.08
        case .water: surface = 1.0   // splash handles it
        }
        let rollDist = grounded ? 30 * surface
                                : min(d * rollFactor * surface, 70)
        let roll = aimU * rollDist
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
            rollDuration: min(0.25 + Double(rollDist) / 140, 0.9),
            tracerHex: tracerHex,
            completion: completion
        )
    }

    // MARK: - Putting (same constants as the 2D build)

    func startPutt(velocity: CGVector) {
        removePreview()
        clearTracer()
        aimLineRoot.childNodes.forEach { $0.removeFromParentNode() }
        puttVelocity = velocity
        puttActive = true
    }

    // MARK: - Aim preview (in-world dots along the line)

    func showPreview(from: CGPoint, direction: CGVector, power: Double, isPutt: Bool) {
        removePreview()
        let dir = direction.normalized
        let travel: CGFloat = isPutt
            ? CGFloat(power) * 480 / 1.9
            : CGFloat(power * Club.sandWedge.maxYards) * Hole.pointsPerYard

        let dotCount = max(Int(travel / 16), 2)
        for i in 1...dotCount {
            let t = CGFloat(i) / CGFloat(dotCount)
            let geo = SCNCylinder(radius: 0.5, height: 0.12)
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

    /// Golf Dreams-style tracer: a dotted arc of the flight that just
    /// happened, persisting until the next shot is set up.
    private func showTracer(_ f: FlightState) {
        clearTracer()
        let n = f.samples.count
        for (i, p) in f.samples.enumerated() where i % 2 == 0 {
            let t = CGFloat(i) / CGFloat(n - 1)
            let h = ballRest + (f.apex > 0 ? f.apex * 4 * t * (1 - t) : 0)
            let geo = SCNSphere(radius: 0.28)
            geo.firstMaterial = Course3DScene.unlitMaterial(
                UIColor(hex: f.tracerHex).withAlphaComponent(0.55))
            let dot = SCNNode(geometry: geo)
            dot.position = world(p, h: h)
            tracerRoot.addChildNode(dot)
        }
    }

    private func clearTracer() {
        tracerRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    /// Physics-true putt read: integrates the SAME friction + slope model
    /// as the live putt (minus lip-outs), so the dotted line bends exactly
    /// the way the ball will for this pull. Flick strength at release
    /// still scales the pace — the read is honest, the touch is yours.
    func showPuttPreview(from: CGPoint, direction: CGVector, power: Double) {
        removePreview()
        var pos = from
        var vel = direction.normalized * CGFloat(power * 480)
        let dt: CGFloat = 1.0 / 30
        var step = 0
        var dotIndex = 0

        while vel.length > 6, step < 260 {
            vel = vel * CGFloat(exp(-1.9 * Double(dt)))
            if hole.lie(at: pos) == .green {
                vel = vel + hole.greenSlope * dt
            } else {
                vel = vel * CGFloat(exp(-2.6 * Double(dt)))
            }
            pos = pos + vel * dt
            pos.x = min(max(pos.x, 42), hole.sceneSize.width - 42)
            pos.y = min(max(pos.y, 42), hole.sceneSize.height - 42)
            step += 1

            if step % 3 == 0 {
                let geo = SCNCylinder(radius: 0.5, height: 0.12)
                geo.firstMaterial = Course3DScene.unlitMaterial(
                    UIColor(hex: 0xEDE8D4).withAlphaComponent(
                        max(0.9 - Double(dotIndex) * 0.02, 0.35)))
                let dot = SCNNode(geometry: geo)
                dot.position = world(pos, h: 0.22)
                previewRoot.addChildNode(dot)
                dotIndex += 1
            }
            if pos.distance(to: hole.pin) <= hole.cupRadius { break }
        }
    }

    // MARK: - Reactions (restrained: rings and hops, no confetti)

    func splash(at p: CGPoint) {
        SoundFX.play("splash", volume: 0.8)
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
        let geo = SCNTorus(ringRadius: 1.1, pipeRadius: 0.12)
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

        // Swing pose: pull-back (putts/chips) beats the meter provider;
        // release animations own the node while they run. Each euler axis
        // eases independently so the club tracks the finger smoothly and
        // mode switches never snap.
        if !isSwinging {
            let pose: SCNVector3
            let amount: CGFloat
            if let pull = manualPullback {
                pose = Course3DScene.puttBackPose
                amount = pull
            } else if let back = manualBackswing {
                pose = Course3DScene.backswingPose
                amount = back
            } else {
                pose = Course3DScene.backswingPose
                amount = swingPoseProvider?() ?? 0
            }
            let target = SCNVector3(pose.x * Float(amount),
                                    pose.y * Float(amount),
                                    pose.z * Float(amount))
            let k = Float(1 - exp(-24 * dt))
            let e = swingNode.eulerAngles
            swingNode.eulerAngles = SCNVector3(e.x + (target.x - e.x) * k,
                                               e.y + (target.y - e.y) * k,
                                               e.z + (target.z - e.z) * k)

            // Body follows the gesture in real time: the torso coils −45°
            // at full backswing, weight sways to the trail side, and the
            // body squishes slightly as it loads. Pauses wherever the
            // finger pauses, because it IS the finger.
            let coil = manualPullback != nil ? 0 : Float(amount)
            let ty = torsoNode.eulerAngles.y
            torsoNode.eulerAngles.y = ty + (-0.78 * coil - ty) * k
            let tz = torsoNode.position.z
            torsoNode.position.z = tz + (0.32 * coil - tz) * k
            let sx = torsoNode.scale.x
            let targetSX = 1 + 0.03 * coil
            let targetSY = 1 - 0.035 * coil
            torsoNode.scale = SCNVector3(sx + (targetSX - sx) * k,
                                         torsoNode.scale.y + (targetSY - torsoNode.scale.y) * k,
                                         1)
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
                showTracer(f)
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
        SoundFX.play("cup_drop", volume: 0.9)
        // Sparkle burst out of the cup (style board: hole impact)
        for _ in 0..<10 {
            let geo = SCNSphere(radius: CGFloat.random(in: 0.12...0.22))
            geo.firstMaterial = Course3DScene.unlitMaterial(
                UIColor(hex: Bool.random() ? 0xFFFFFF : 0xFFD98A))
            let spark = SCNNode(geometry: geo)
            spark.position = world(hole.pin, h: 0.4)
            scene.rootNode.addChildNode(spark)
            let up = SCNAction.group([
                .moveBy(x: CGFloat.random(in: -2.4...2.4),
                        y: CGFloat.random(in: 2.5...5),
                        z: CGFloat.random(in: -2.4...2.4), duration: 0.55),
                .fadeOut(duration: 0.55)
            ])
            up.timingMode = .easeOut
            spark.runAction(.sequence([up, .removeFromParentNode()]))
        }
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

    /// Everything sits on the faceted terrain: `h` is height ABOVE ground.
    private func world(_ p: CGPoint, h: CGFloat) -> SCNVector3 {
        SCNVector3(Float(p.x), Float(groundHeight(p) + h), Float(-p.y))
    }

    /// Stylized rolling terrain, purely visual — gameplay stays in flat 2D
    /// hole coords. Gentle noise in the rough, calm fairway, a raised flat
    /// green plateau, a raised tee, sunken pond and bunker dishes, and an
    /// edge fade so the mesh meets the backdrop cleanly.
    private func groundHeight(_ p: CGPoint) -> CGFloat {
        let w = hole.sceneSize.width, l = hole.sceneSize.height
        let border = min(min(p.x, w - p.x), min(p.y, l - p.y))
        let edge = smoothstep(min(max(border / 36, 0), 1))

        let greenT = 1 - min(max((p.distance(to: hole.pin) - hole.greenRadius) / 46, 0), 1)
        let sGreen = smoothstep(greenT)
        let teeT = 1 - min(max((p.distance(to: hole.tee) - 30) / 42, 0), 1)
        let sTee = smoothstep(teeT)

        var h = 2.1 * sin(p.x * 0.012 + 0.7) * cos(p.y * 0.009 + 2.1)
              + 1.5 * sin((p.x + p.y) * 0.0065 + 4.2)
        h *= (1 - sGreen) * (1 - sTee * 0.85)
        h += 3.0 * sGreen
        h += 0.9 * sTee

        for rect in hole.waterRects {
            let nx = (p.x - rect.midX) / (rect.width * 0.62)
            let ny = (p.y - rect.midY) / (rect.height * 0.62)
            let nd = nx * nx + ny * ny
            if nd < 1 { h -= 2.4 * (1 - nd) }
        }
        for b in hole.bunkers {
            let d = p.distance(to: b.center) / (b.radius * 1.15)
            if d < 1 { h -= 1.1 * (1 - d * d) }
        }
        return h * edge
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

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

    /// Style-board sky: soft blue overhead melting into a warm horizon.
    private static func skyImage() -> UIImage {
        let size = CGSize(width: 16, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hex: 0x7FB9E0).cgColor,
                          UIColor(hex: 0xCBDfC2).cgColor,
                          UIColor(hex: 0xF2DCA4).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray,
                                      locations: [0, 0.58, 1])!
            ctx.cgContext.drawLinearGradient(
                gradient, start: .zero,
                end: CGPoint(x: 0, y: size.height), options: [])
        }
    }


}
