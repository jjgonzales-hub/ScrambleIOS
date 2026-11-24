import SceneKit
import UIKit
import simd

/// 3D SceneKit renderer for one hole.
///
/// All gameplay runs in 2D hole coordinates (2 pts = 1 yd); `BallPhysics`
/// simulates every shot up front and this class plays the result back,
/// draws the course, poses the golfer, and drives the camera.
/// Mapping: hole (x, y) → world (x, height, -y). Looking from tee to pin the
/// camera faces -z, so +x (screen right) matches +x in hole coords.
final class Course3DScene: NSObject {
    let hole: Hole
    let scene = SCNScene()
    let cameraNode = SCNNode()

    // MARK: - Nodes

    private let ballNode = SCNNode()
    private let ballShadow = SCNNode()
    private let teePeg = SCNNode()
    private let previewRoot = SCNNode()
    private let readRoot = SCNNode()       // partner's putt line
    private let tuftRoot = SCNNode()
    /// On the green the golfer steps away and it's just you and the putter.
    private let putterPivot = SCNNode()
    private var putterAngle: Float = 0
    private var putterTarget: Float = 0
    private var putterAxis = SIMD3<Float>(1, 0, 0)
    private var putterBase = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private let tracerRoot = SCNNode()
    private let greenGridNode = SCNNode()
    private let flagPivot = SCNNode()
    private let flagNode = SCNNode()
    private let markerRoot = SCNNode()
    private let sun = SCNNode()
    private var golfer: GolferRig
    private var golferCharacter: String

    // MARK: - State

    private var ball2D: CGPoint
    private var ballH: CGFloat = 0
    private var ballRest: CGFloat = Course3DScene.ballRadius
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var clock: CFTimeInterval = 0
    private var timed: [(at: CFTimeInterval, run: () -> Void)] = []
    private var fingerDriven = false

    static let ballRadius: CGFloat = 0.42
    /// Global speed-up for automated playtests (-autoplay -fast).
    static var timeScale: Double = 1

    private struct Playback {
        let trajectory: BallPhysics.Trajectory
        let speed: Double
        let aim: CGVector
        let tracerHex: UInt32?
        let completion: (BallPhysics.Trajectory) -> Void
        var t: Double = 0
        var nextEvent = 0
        var tracerFrame = 0
    }
    private var playback: Playback?

    // Camera: everything eases toward these.
    private enum CameraMode { case address, follow, intro, overview }
    private var cameraMode: CameraMode = .address
    private var camGoal = SCNVector3Zero
    private var lookGoal = SCNVector3Zero
    private var lookCurrent = SCNVector3Zero
    private var introT: Double = 0
    private var introCompletion: (() -> Void)?
    private var introPath: (from: SCNVector3, to: SCNVector3, lookFrom: SCNVector3, lookTo: SCNVector3)?

    private var rng: SeededRandom

    // MARK: - Init

    init(hole: Hole, character: String) {
        self.hole = hole
        self.ball2D = hole.tee
        self.golferCharacter = character
        self.golfer = GolferRig(character: character)
        self.rng = SeededRandom(seed: UInt64(hole.number) * 7919 + 17)
        super.init()
        buildScene()
        placeBall(at: hole.tee, onTee: true)
    }

    /// Start the per-frame update. Call on the main thread once the scene
    /// (which can be built on a background thread) is on screen.
    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
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
        let sky = Course3DScene.skyImage()
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky
        scene.lightingEnvironment.intensity = 0.9
        scene.fogColor = UIColor(hex: 0xDDEBE6)
        scene.fogStartDistance = 520
        scene.fogEndDistance = 2400
        scene.fogDensityExponent = 1.4

        // Camera with a light, polished post stack: gentle bloom on the
        // highlights, a soft vignette, a touch of saturation.
        let camera = SCNCamera()
        camera.fieldOfView = 70
        camera.zNear = 0.3
        camera.zFar = 3000
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.15
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 8
        camera.vignettingIntensity = 0.35
        camera.vignettingPower = 0.6
        camera.saturation = 1.08
        camera.contrast = 0.06
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(hex: 0xBFD3E6)
        ambient.light?.intensity = 360
        scene.rootNode.addChildNode(ambient)

        let light = SCNLight()
        light.type = .directional
        light.color = UIColor(hex: 0xFFF2DA)
        light.intensity = 950
        light.castsShadow = true
        light.shadowColor = UIColor(red: 0.08, green: 0.16, blue: 0.1, alpha: 0.42)
        light.shadowRadius = 2.5
        light.shadowSampleCount = 8
        light.shadowMapSize = CGSize(width: 2048, height: 2048)
        light.automaticallyAdjustsShadowProjection = true
        light.maximumShadowDistance = 160
        sun.light = light
        sun.eulerAngles = SCNVector3(-0.95, 0.55, 0)
        scene.rootNode.addChildNode(sun)

        // Endless ground beyond the hole, same green as deep rough.
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.firstMaterial = Course3DScene.material(0x4F8A3F)
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = -0.6
        scene.rootNode.addChildNode(floorNode)

        scene.rootNode.addChildNode(buildTerrain())
        buildWater()
        buildTeeBox()
        buildPinAndCup()
        buildPracticeTargets()
        buildGreenGrid()
        buildVegetation()
        buildRoughGrass()
        buildClouds()

        // Ball
        let ballGeo = SCNSphere(radius: Course3DScene.ballRadius)
        ballGeo.segmentCount = 24
        let ballMat = SCNMaterial()
        ballMat.diffuse.contents = UIColor.white
        ballMat.lightingModel = .blinn
        ballMat.specular.contents = UIColor(white: 1, alpha: 0.6)
        ballMat.shininess = 30
        ballMat.emission.contents = UIColor(white: 1, alpha: 0.12)
        ballGeo.firstMaterial = ballMat
        ballNode.geometry = ballGeo
        ballNode.castsShadow = true
        scene.rootNode.addChildNode(ballNode)

        let shadowGeo = SCNCylinder(radius: 0.55, height: 0.01)
        shadowGeo.firstMaterial = GolferRig.unlit(UIColor.black.withAlphaComponent(0.3))
        ballShadow.geometry = shadowGeo
        ballShadow.castsShadow = false
        scene.rootNode.addChildNode(ballShadow)

        let pegGeo = SCNCylinder(radius: 0.09, height: 0.6)
        pegGeo.firstMaterial = Course3DScene.material(0xF4EFE2)
        teePeg.geometry = pegGeo
        scene.rootNode.addChildNode(teePeg)

        scene.rootNode.addChildNode(golfer.node)
        buildPutter()
        scene.rootNode.addChildNode(previewRoot)
        scene.rootNode.addChildNode(readRoot)
        scene.rootNode.addChildNode(tracerRoot)
        scene.rootNode.addChildNode(markerRoot)
    }

    // MARK: Terrain

    private let cell: CGFloat = 6

    /// Smooth-shaded terrain mesh over the hole with per-vertex colors
    /// sampled from the gameplay lie map (so what you see is what the
    /// rules say), mowing stripes, and soft blended edges.
    private func buildTerrain() -> SCNNode {
        let cols = Int(ceil(hole.sceneSize.width / cell))
        let rows = Int(ceil(hole.sceneSize.height / cell))
        let stride = cols + 1
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [SIMD3<Float>] = []
        positions.reserveCapacity(stride * (rows + 1))

        for r in 0...rows {
            for c in 0...cols {
                let p = CGPoint(x: CGFloat(c) * cell, y: CGFloat(r) * cell)
                let h = groundHeight(p)
                positions.append(SCNVector3(Float(p.x), Float(h), Float(-p.y)))
                // Normal from central differences.
                let e: CGFloat = 1.5
                let hx = groundHeight(CGPoint(x: p.x + e, y: p.y)) - groundHeight(CGPoint(x: p.x - e, y: p.y))
                let hy = groundHeight(CGPoint(x: p.x, y: p.y + e)) - groundHeight(CGPoint(x: p.x, y: p.y - e))
                let n = simd_normalize(SIMD3<Float>(Float(-hx), Float(2 * e), Float(hy)))
                normals.append(SCNVector3(n.x, n.y, n.z))
                colors.append(groundColor(at: p))
            }
        }

        // One blur pass softens the boundaries between surfaces without a
        // texture (anti-aliased fairway/green edges).
        var blurred = colors
        for r in 1..<rows {
            for c in 1..<cols {
                let i = r * stride + c
                let sum = colors[i] * 4 + colors[i - 1] + colors[i + 1]
                    + colors[i - stride] + colors[i + stride]
                blurred[i] = sum / 8
            }
        }

        var colorData: [Float] = []
        colorData.reserveCapacity(blurred.count * 4)
        for c in blurred { colorData += [c.x, c.y, c.z, 1] }

        var indices: [Int32] = []
        indices.reserveCapacity(cols * rows * 6)
        for r in 0..<rows {
            for c in 0..<cols {
                let i = Int32(r * stride + c)
                let s = Int32(stride)
                indices += [i, i + 1, i + s + 1, i, i + s + 1, i + s]
            }
        }

        let vSrc = SCNGeometrySource(vertices: positions)
        let nSrc = SCNGeometrySource(normals: normals)
        let cSrc = SCNGeometrySource(
            data: colorData.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: .color, vectorCount: blurred.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [vSrc, nSrc, cSrc], elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white
        m.lightingModel = .lambert
        geo.firstMaterial = m
        let node = SCNNode(geometry: geo)
        node.castsShadow = false
        return node
    }

    private func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255)
    }

    private func groundColor(at p: CGPoint) -> SIMD3<Float> {
        let axis = CGVector(from: hole.tee, to: hole.pin).normalized
        let along = CGVector(from: hole.tee, to: p).dot(axis)
        let noise = Float(valueNoise(p.x * 0.045, p.y * 0.045))
        switch hole.lie(at: p) {
        case .water: return rgb(0x3D7DA6)
        case .bunker:
            // Darker lip toward the edge of the trap.
            var edge: CGFloat = 1
            for b in hole.bunkers {
                let d = p.distance(to: b.center) / b.radius
                if d <= 1 { edge = min(edge, 1 - d) }
            }
            return simd_mix(rgb(0xD8BC82), rgb(0xF1DCA8), SIMD3(repeating: Float(min(edge * 3, 1))))
        case .green:
            let a = Int(floor(p.x / 9)), b = Int(floor(p.y / 9))
            return (a + b) % 2 == 0 ? rgb(0x8FD266) : rgb(0x9ADB70)
        case .fringe: return rgb(0x7DC25A)
        case .tee:
            return Int(floor(along / 8)) % 2 == 0 ? rgb(0x84C75E) : rgb(0x8FD067)
        case .fairway:
            let band = Int(floor(along / 20))
            return band % 2 == 0 ? rgb(0x74BC4F) : rgb(0x82C65B)
        case .trees:
            return rgb(0x4F8A3F) * (0.92 + 0.1 * noise)
        case .rough:
            // First cut right next to the fairway, deeper rough beyond,
            // mottled with darker clumps so it reads as long grass.
            let first = distanceToFairway(p) < 12
            let fine = Float(valueNoise(p.x * 0.22, p.y * 0.22))
            let clumps = Float(valueNoise(p.x * 0.07 + 40, p.y * 0.07))
            if first { return rgb(0x69AE49) * (0.95 + 0.08 * fine) }
            let base = simd_mix(rgb(0x5DA042), rgb(0x47853A), SIMD3(repeating: clumps * clumps))
            return base * (0.9 + 0.14 * fine)
        }
    }

    private func distanceToFairway(_ p: CGPoint) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for q in hole.fairwayLine { best = min(best, q.distance(to: p)) }
        return best - hole.fairwayWidth / 2
    }

    /// Stylized rolling terrain, purely visual — gameplay stays flat 2D.
    func groundHeight(_ p: CGPoint) -> CGFloat {
        let w = hole.sceneSize.width, l = hole.sceneSize.height
        let border = min(min(p.x, w - p.x), min(p.y, l - p.y))
        let edge = smoothstep(min(max(border / 40, 0), 1))

        let greenT = 1 - min(max((p.distance(to: hole.pin) - hole.greenRadius) / 50, 0), 1)
        let sGreen = smoothstep(greenT)
        let teeT = 1 - min(max((p.distance(to: hole.tee) - 22) / 34, 0), 1)
        let sTee = smoothstep(teeT)

        var h = 2.2 * sin(p.x * 0.011 + 0.7) * cos(p.y * 0.008 + 2.1)
            + 1.4 * sin((p.x + p.y) * 0.006 + 4.2)
            + 0.6 * (valueNoise(p.x * 0.03, p.y * 0.03) - 0.5)
        // Calm down the ground around water so banks stay above the surface.
        var calm: CGFloat = 0
        for rect in hole.waterRects {
            let nx = (p.x - rect.midX) / (rect.width / 2)
            let ny = (p.y - rect.midY) / (rect.height / 2)
            calm = max(calm, 1 - min(max((sqrt(nx * nx + ny * ny) - 1) / 0.6, 0), 1))
        }
        h *= (1 - sGreen) * (1 - sTee) * (1 - calm)
        h += 1.6 * sGreen
        // The green's real contours (same field the ball rolls on).
        h += sGreen * hole.greenHeight(at: p) * 1.8
        h += 1.1 * sTee

        for rect in hole.waterRects {
            let nx = (p.x - rect.midX) / (rect.width / 2)
            let ny = (p.y - rect.midY) / (rect.height / 2)
            let nd = nx * nx + ny * ny
            if nd < 1 { h -= 2.6 * smoothstep(1 - nd) }
        }
        for b in hole.bunkers {
            let d = p.distance(to: b.center) / (b.radius * 1.05)
            if d < 1 { h -= 1.0 * smoothstep(1 - d * d) }
        }
        // Mounds in the stands of trees.
        for zone in hole.treeZones {
            let nx = (p.x - zone.midX) / (zone.width / 2)
            let ny = (p.y - zone.midY) / (zone.height / 2)
            let nd = nx * nx + ny * ny
            if nd < 1 { h += 2.5 * smoothstep(1 - nd) }
        }
        return h * edge
    }

    // MARK: Water, tee, pin

    private func buildWater() {
        for rect in hole.waterRects {
            let path = UIBezierPath(ovalIn: CGRect(x: -rect.width / 2, y: -rect.height / 2,
                                                   width: rect.width, height: rect.height))
            let shape = SCNShape(path: path, extrusionDepth: 0.05)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(hex: 0x4FA3D9).withAlphaComponent(0.82)
            m.lightingModel = .blinn
            m.specular.contents = UIColor(white: 1, alpha: 0.9)
            m.shininess = 80
            m.transparencyMode = .dualLayer
            m.fresnelExponent = 1.5
            shape.firstMaterial = m
            let node = SCNNode(geometry: shape)
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(Float(rect.midX), -0.35, Float(-rect.midY))
            node.castsShadow = false
            scene.rootNode.addChildNode(node)

            // Lazy shimmer.
            let up = SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 2.4)
            up.timingMode = .easeInEaseOut
            node.runAction(.repeatForever(.sequence([up, up.reversed()])))
        }
    }

    private func buildTeeBox() {
        let axis = CGVector(from: hole.tee, to: hole.pin).normalized
        let side = axis.perpendicularRight
        for s in [CGFloat(-1), 1] {
            let p = hole.tee + side * (s * 9) + axis * 4
            let geo = SCNSphere(radius: 0.6)
            geo.firstMaterial = Course3DScene.material(0xF0705E)
            let marker = SCNNode(geometry: geo)
            marker.position = world(p, h: 0.45)
            scene.rootNode.addChildNode(marker)
        }
    }

    private func buildPinAndCup() {
        let base = world(hole.pin, h: 0)

        let cupGeo = SCNCylinder(radius: hole.cupRadius * 0.9, height: 0.04)
        cupGeo.firstMaterial = GolferRig.unlit(UIColor(hex: 0x0E1A10))
        let cup = SCNNode(geometry: cupGeo)
        cup.position = SCNVector3(base.x, base.y + 0.03, base.z)
        cup.castsShadow = false
        scene.rootNode.addChildNode(cup)

        let rimGeo = SCNTube(innerRadius: hole.cupRadius * 0.9, outerRadius: hole.cupRadius * 0.9 + 0.12,
                             height: 0.05)
        rimGeo.firstMaterial = Course3DScene.material(0xFFFFFF)
        let rim = SCNNode(geometry: rimGeo)
        rim.position = SCNVector3(base.x, base.y + 0.04, base.z)
        scene.rootNode.addChildNode(rim)

        let poleGeo = SCNCylinder(radius: 0.11, height: 13)
        poleGeo.firstMaterial = Course3DScene.material(0xF7F7F2)
        let pole = SCNNode(geometry: poleGeo)
        pole.position.y = 6.5
        flagNode.addChildNode(pole)

        let tri = UIBezierPath()
        tri.move(to: .zero)
        tri.addLine(to: CGPoint(x: 4.2, y: -1.1))
        tri.addLine(to: CGPoint(x: 0, y: -2.4))
        tri.close()
        let clothGeo = SCNShape(path: tri, extrusionDepth: 0.04)
        let clothMat = Course3DScene.material(0xF25C54)
        clothMat.isDoubleSided = true
        clothGeo.firstMaterial = clothMat
        let cloth = SCNNode(geometry: clothGeo)
        cloth.position = SCNVector3(0.08, 0, 0)
        flagPivot.position = SCNVector3(0, 12.9, 0)
        flagPivot.addChildNode(cloth)
        flagNode.addChildNode(flagPivot)
        let sway1 = SCNAction.rotateTo(x: 0, y: 0.35, z: 0, duration: 1.4)
        sway1.timingMode = .easeInEaseOut
        let sway2 = SCNAction.rotateTo(x: 0, y: -0.2, z: 0, duration: 1.4)
        sway2.timingMode = .easeInEaseOut
        flagPivot.runAction(.repeatForever(.sequence([sway1, sway2])))

        flagNode.position = base
        scene.rootNode.addChildNode(flagNode)
    }

    /// Driving range target greens: a disc of green, a flag, and a big
    /// yardage sign facing the tee.
    private func buildPracticeTargets() {
        let flagColors: [UInt32] = [0xF0705E, 0xFFD27A, 0x4F9BE0, 0xB97FE0, 0xFFFFFF]
        for (i, t) in hole.practiceTargets.enumerated() {
            let disc = SCNNode(geometry: SCNCylinder(radius: 16, height: 0.06))
            disc.geometry?.firstMaterial = Course3DScene.material(0x93D86A)
            disc.position = world(t.center, h: 0.06)
            disc.castsShadow = false
            scene.rootNode.addChildNode(disc)
            let ring = SCNNode(geometry: SCNTube(innerRadius: 16, outerRadius: 17.2, height: 0.07))
            ring.geometry?.firstMaterial = Course3DScene.material(0x7DC25A)
            ring.position = world(t.center, h: 0.06)
            scene.rootNode.addChildNode(ring)

            let flag = SCNNode()
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.12, height: 9))
            pole.geometry?.firstMaterial = Course3DScene.material(0xF7F7F2)
            pole.position.y = 4.5
            flag.addChildNode(pole)
            let cloth = SCNNode(geometry: SCNBox(width: 3, height: 1.8, length: 0.05, chamferRadius: 0))
            cloth.geometry?.firstMaterial = Course3DScene.material(flagColors[i % flagColors.count])
            cloth.position = SCNVector3(1.55, 8, 0)
            flag.addChildNode(cloth)
            flag.position = world(t.center, h: 0)
            scene.rootNode.addChildNode(flag)

            let text = SCNText(string: "\(t.yards)", extrusionDepth: 0.6)
            text.font = UIFont.systemFont(ofSize: 10, weight: .black)
            text.flatness = 0.2
            text.firstMaterial = GolferRig.unlit(.white)
            let label = SCNNode(geometry: text)
            let (mn, mx) = label.boundingBox
            label.pivot = SCNMatrix4MakeTranslation((mx.x + mn.x) / 2, mn.y, 0)
            let side = CGVector(dx: t.center.x < hole.tee.x ? -24 : 24, dy: 0)
            label.position = world(t.center + side + CGVector(dx: 0, dy: -0.6), h: 3.2)
            label.scale = SCNVector3(0.55, 0.55, 0.55)
            let board = SCNNode(geometry: SCNBox(width: 12, height: 6, length: 0.3, chamferRadius: 0.8))
            board.geometry?.firstMaterial = Course3DScene.material(0x17382A)
            board.position = world(t.center + side, h: 5.8)
            for n in [label, board] {
                // Face back toward the tee (world +z).
                scene.rootNode.addChildNode(n)
            }
            let legs = SCNNode(geometry: SCNBox(width: 0.4, height: 4, length: 0.4, chamferRadius: 0))
            legs.geometry?.firstMaterial = Course3DScene.material(0x5C4632)
            legs.position = world(t.center + side, h: 1.5)
            scene.rootNode.addChildNode(legs)
        }
    }

    /// Slope steepness → grid color, PGA 2K-style: blue flat, green,
    /// yellow, orange, red severe.
    private func slopeColor(_ s: CGFloat) -> SIMD3<Float> {
        let stops: [(CGFloat, UInt32)] = [(0, 0x5BC0F8), (2.2, 0x6FE0A8), (3.6, 0xF2E14C),
                                          (5.0, 0xF5A142), (6.4, 0xE8483C)]
        if s <= stops[0].0 { return rgb(stops[0].1) }
        for i in 1..<stops.count where s <= stops[i].0 {
            let t = Float((s - stops[i - 1].0) / (stops[i].0 - stops[i - 1].0))
            return simd_mix(rgb(stops[i - 1].1), rgb(stops[i].1), SIMD3(repeating: t))
        }
        return rgb(stops.last!.1)
    }

    /// The green gets its own fine mesh (1.5 pt cells) so its contours are
    /// smooth and exact, then a 2K-style grid drapes over it: lines that
    /// bend with every rise and dip, colored by steepness, plus dots that
    /// flow downhill. The grid shows only while putting.
    private func buildGreenGrid() {
        let pin = hole.pin
        let outer = hole.greenRadius + hole.fringeWidth
        let step: CGFloat = 1.5
        let n = Int(ceil(outer * 2 / step)) + 1
        let origin = CGPoint(x: pin.x - outer, y: pin.y - outer)

        // ---- surface ----
        var pos: [SCNVector3] = [], nrm: [SCNVector3] = [], col: [Float] = []
        var index = [Int](repeating: -1, count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let p = CGPoint(x: origin.x + CGFloat(i) * step, y: origin.y + CGFloat(j) * step)
                guard p.distance(to: pin) <= outer + step else { continue }
                index[j * n + i] = pos.count
                pos.append(world(p, h: 0.1))
                let e: CGFloat = 0.75
                let hx = groundHeight(CGPoint(x: p.x + e, y: p.y)) - groundHeight(CGPoint(x: p.x - e, y: p.y))
                let hy = groundHeight(CGPoint(x: p.x, y: p.y + e)) - groundHeight(CGPoint(x: p.x, y: p.y - e))
                let nn = simd_normalize(SIMD3<Float>(Float(-hx), Float(2 * e), Float(hy)))
                nrm.append(SCNVector3(nn.x, nn.y, nn.z))
                let d = p.distance(to: pin)
                var c: SIMD3<Float>
                if d <= hole.greenRadius {
                    let stripe = Int(floor((p.x + p.y) / 7)) % 2 == 0
                    c = stripe ? rgb(0x8BD064) : rgb(0x97D96E)
                } else {
                    c = rgb(0x7DC25A)
                }
                col += [c.x, c.y, c.z, 1]
            }
        }
        var tris: [Int32] = []
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = index[j * n + i], b = index[j * n + i + 1]
                let c = index[(j + 1) * n + i], d = index[(j + 1) * n + i + 1]
                guard a >= 0, b >= 0, c >= 0, d >= 0 else { continue }
                tris += [Int32(a), Int32(b), Int32(d), Int32(a), Int32(d), Int32(c)]
            }
        }
        let surface = SCNGeometry(
            sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nrm),
                      SCNGeometrySource(data: col.withUnsafeBufferPointer { Data(buffer: $0) },
                                        semantic: .color, vectorCount: pos.count,
                                        usesFloatComponents: true, componentsPerVector: 4,
                                        bytesPerComponent: 4, dataOffset: 0, dataStride: 16)],
            elements: [SCNGeometryElement(indices: tris, primitiveType: .triangles)])
        let sm = SCNMaterial()
        sm.diffuse.contents = UIColor.white
        sm.lightingModel = .lambert
        surface.firstMaterial = sm
        let surfaceNode = SCNNode(geometry: surface)
        surfaceNode.castsShadow = false
        scene.rootNode.addChildNode(surfaceNode)

        // ---- draped grid ----
        var gp: [SCNVector3] = [], gc: [Float] = [], gi: [Int32] = []
        let spacing: CGFloat = 3
        let half: CGFloat = 0.07
        func ribbon(_ from: CGPoint, _ dir: CGVector, length: CGFloat) {
            let side = dir.perpendicularRight * half
            var t: CGFloat = 0
            var prev: (Int32, Int32)?
            while t <= length {
                let p = from + dir * t
                t += 0.9
                guard p.distance(to: pin) <= hole.greenRadius - 0.5 else { prev = nil; continue }
                let c = slopeColor(hole.slope(at: p).length)
                let l = world(p + side, h: 0.2), r = world(p + side * -1, h: 0.2)
                let base = Int32(gp.count)
                gp += [l, r]
                gc += [c.x, c.y, c.z, 1, c.x, c.y, c.z, 1]
                if let (pl, pr) = prev { gi += [pl, pr, base + 1, pl, base + 1, base] }
                prev = (base, base + 1)
            }
        }
        let span = hole.greenRadius * 2
        var k = -hole.greenRadius
        while k <= hole.greenRadius {
            ribbon(CGPoint(x: pin.x - hole.greenRadius, y: pin.y + k), CGVector(dx: 1, dy: 0), length: span)
            ribbon(CGPoint(x: pin.x + k, y: pin.y - hole.greenRadius), CGVector(dx: 0, dy: 1), length: span)
            k += spacing
        }
        if !gi.isEmpty {
            let grid = SCNGeometry(
                sources: [SCNGeometrySource(vertices: gp),
                          SCNGeometrySource(data: gc.withUnsafeBufferPointer { Data(buffer: $0) },
                                            semantic: .color, vectorCount: gp.count,
                                            usesFloatComponents: true, componentsPerVector: 4,
                                            bytesPerComponent: 4, dataOffset: 0, dataStride: 16)],
                elements: [SCNGeometryElement(indices: gi, primitiveType: .triangles)])
            let gm = SCNMaterial()
            gm.diffuse.contents = UIColor.white
            gm.lightingModel = .constant
            gm.isDoubleSided = true
            gm.transparency = 0.75
            grid.firstMaterial = gm
            let gridNode = SCNNode(geometry: grid)
            gridNode.castsShadow = false
            greenGridNode.addChildNode(gridNode)
        }

        // ---- downhill flow dots on the grid ----
        var idx = 0
        var y = pin.y - hole.greenRadius
        while y <= pin.y + hole.greenRadius {
            var x = pin.x - hole.greenRadius
            while x <= pin.x + hole.greenRadius {
                let p = CGPoint(x: x, y: y)
                x += 7.5
                guard p.distance(to: pin) <= hole.greenRadius - 2, p.distance(to: pin) > 2 else { continue }
                let slope = hole.slope(at: p)
                let strength = slope.length
                let c = slopeColor(strength)
                let end = p + slope.normalized * min(1.5 + strength * 0.55, 4.5)
                let cycle = max(Double(7 / max(strength, 1)), 0.8)
                _ = c
                let geo = SCNSphere(radius: 0.2)
                geo.segmentCount = 10
                geo.firstMaterial = GolferRig.unlit(UIColor.white)
                let dot = SCNNode(geometry: geo)
                let start = world(p, h: 0.32), stop = world(end, h: 0.32)
                dot.position = start
                dot.opacity = 0
                dot.castsShadow = false
                dot.runAction(.sequence([
                    .wait(duration: Double(idx % 6) * cycle / 6),
                    .repeatForever(.sequence([
                        .group([.move(to: stop, duration: cycle),
                                .sequence([.fadeOpacity(to: 1, duration: cycle * 0.2),
                                           .wait(duration: cycle * 0.5),
                                           .fadeOpacity(to: 0, duration: cycle * 0.3)])]),
                        .move(to: start, duration: 0)]))
                ]))
                greenGridNode.addChildNode(dot)
                idx += 1
            }
            y += 7.5
        }
        greenGridNode.isHidden = true
        scene.rootNode.addChildNode(greenGridNode)
    }

    // MARK: Vegetation (Kenney Nature Kit, CC0)

    private static var props: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "Props", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url, options: nil)
    }()

    private var prototypes: [String: [SCNNode]] = [:]

    /// A recolored, height-normalized copy of a prop. Variants differ only
    /// in leaf color so the forest doesn't look stamped.
    private func prototype(_ name: String, height: CGFloat, variant: Int) -> SCNNode? {
        if let list = prototypes[name], variant < list.count { return list[variant] }
        guard let src = Course3DScene.props?.rootNode.childNode(withName: "prop_\(name)", recursively: true)
        else { return nil }
        var list = prototypes[name] ?? []
        let leafSets: [[UInt32]] = [[0x4C9A3E, 0x2F6E34], [0x5FAE45, 0x3A7D38], [0x3F8A3A, 0x285F2E]]
        for v in list.count...variant {
            let copy = src.clone()
            copy.position = SCNVector3Zero
            let leaves = leafSets[v % leafSets.count]
            copy.enumerateHierarchy { n, _ in
                guard let g = n.geometry else { return }
                let gg = g.copy() as! SCNGeometry
                gg.materials = g.materials.map { old in
                    let m = SCNMaterial()
                    m.lightingModel = .lambert
                    let name = old.name ?? ""
                    if name.hasPrefix("leafsGreen") {
                        m.diffuse.contents = UIColor(hex: leaves[0])
                    } else if name.hasPrefix("leafsDark") {
                        m.diffuse.contents = UIColor(hex: leaves[1])
                    } else if name.hasPrefix("woodBark") {
                        m.diffuse.contents = UIColor(hex: 0x7B5A3D)
                    } else if name.hasPrefix("grass") {
                        m.diffuse.contents = UIColor(hex: 0x5FA548)
                    } else if name.hasPrefix("dirt") {
                        m.diffuse.contents = UIColor(hex: 0x8A6B4A)
                    } else if name.hasPrefix("stone") || name.hasPrefix("_default") {
                        m.diffuse.contents = UIColor(hex: 0xA7A9A3)
                    } else {
                        m.diffuse.contents = old.diffuse.contents
                    }
                    return m
                }
                n.geometry = gg
            }
            let (mn, mx) = copy.boundingBox
            let raw = max(CGFloat(mx.y - mn.y), 0.001)
            let s = Float(height / raw)
            copy.scale = SCNVector3(s, s, s)
            let holder = SCNNode()
            holder.addChildNode(copy)
            list.append(holder)
        }
        prototypes[name] = list
        return list[min(variant, list.count - 1)]
    }

    private func scatter(_ name: String, at p: CGPoint, height: CGFloat, into parent: SCNNode,
                         variants: Int = 3) {
        guard let proto = prototype(name, height: height, variant: rng.int(variants)) else { return }
        let n = proto.clone()
        n.position = world(p, h: -0.1)
        n.eulerAngles.y = Float(rng.double() * 2 * .pi)
        let s = Float(0.85 + rng.double() * 0.35)
        n.scale = SCNVector3(s, s, s)
        parent.addChildNode(n)
    }

    private func buildVegetation() {
        let forest = SCNNode()
        let decor = SCNNode()
        let treeTypes = ["tree_oak", "tree_default", "tree_detailed", "tree_fat",
                         "tree_pineRoundA", "tree_pineRoundC", "tree_pineTallA_detailed",
                         "tree_pineDefaultA", "tree_tall"]
        func randomTree() -> String { treeTypes[rng.int(treeTypes.count)] }
        func treeHeight() -> CGFloat { 24 + CGFloat(rng.double()) * 14 }

        let w = hole.sceneSize.width, l = hole.sceneSize.height

        // Inside the property: wherever the rules say "trees".
        var y: CGFloat = 8
        while y < l - 8 {
            var x: CGFloat = 8
            while x < w - 8 {
                let p = CGPoint(x: x + CGFloat(rng.double() - 0.5) * 12,
                                y: y + CGFloat(rng.double() - 0.5) * 12)
                if hole.lie(at: p) == .trees && p.distance(to: hole.tee) > 30 {
                    scatter(randomTree(), at: p, height: treeHeight(), into: forest)
                }
                x += 21
            }
            y += 21
        }

        // Backdrop forest outside the property so there's no void.
        func backdrop(_ rect: CGRect, step: CGFloat) {
            var yy = rect.minY
            while yy < rect.maxY {
                var xx = rect.minX
                while xx < rect.maxX {
                    let p = CGPoint(x: xx + CGFloat(rng.double() - 0.5) * step * 0.6,
                                    y: yy + CGFloat(rng.double() - 0.5) * step * 0.6)
                    scatter(randomTree(), at: p, height: treeHeight() * 1.15, into: forest)
                    xx += step
                }
                yy += step
            }
        }
        backdrop(CGRect(x: -110, y: -80, width: 100, height: l + 260), step: 30)
        backdrop(CGRect(x: w + 10, y: -80, width: 100, height: l + 260), step: 30)
        backdrop(CGRect(x: -10, y: l + 6, width: w + 20, height: 110), step: 30)

        // Bushes along the tree line, flowers by the tee and green, grass
        // tufts and the odd rock in the rough.
        for _ in 0..<Int(l / 6) {
            let p = CGPoint(x: CGFloat(rng.double()) * w, y: CGFloat(rng.double()) * l)
            let lie = hole.lie(at: p)
            if lie == .rough {
                let nearTrees = p.x < hole.treeMarginX + 26 || p.x > w - hole.treeMarginX - 26
                if nearTrees && rng.double() < 0.5 {
                    scatter(["plant_bushLarge", "plant_bush", "plant_bushDetailed"][rng.int(3)],
                            at: p, height: 3.5 + CGFloat(rng.double()) * 3, into: decor)
                } else if distanceToFairway(p) > 14 {
                    scatter(rng.double() < 0.5 ? "grass_large" : "grass", at: p,
                            height: 1.4 + CGFloat(rng.double()), into: decor, variants: 1)
                }
            }
        }
        for i in 0..<14 {
            let a = Double(i) / 14 * 2 * .pi
            let p = hole.tee + CGVector(dx: cos(a), dy: sin(a)) * (34 + CGFloat(rng.double()) * 10)
            if hole.lie(at: p) == .rough {
                scatter(["flower_yellowA", "flower_redA", "flower_purpleA"][rng.int(3)], at: p,
                        height: 1.3, into: decor, variants: 1)
            }
        }
        for _ in 0..<10 {
            let p = CGPoint(x: CGFloat(rng.double()) * w, y: CGFloat(rng.double()) * l)
            if hole.lie(at: p) == .rough && distanceToFairway(p) > 20 {
                scatter(["rock_largeA", "rock_smallA", "rock_smallC"][rng.int(3)], at: p,
                        height: 1.5 + CGFloat(rng.double()) * 2, into: decor, variants: 1)
            }
        }

        // Merge thousands of nodes into a handful of draw calls.
        let forestMerge = MeshMerger()
        forestMerge.add(forest)
        let flatForest = forestMerge.build()
        flatForest.enumerateHierarchy { n, _ in n.castsShadow = true }
        scene.rootNode.addChildNode(flatForest)
        let decorMerge = MeshMerger()
        decorMerge.add(decor)
        let flatDecor = decorMerge.build()
        flatDecor.enumerateHierarchy { n, _ in n.castsShadow = false }
        scene.rootNode.addChildNode(flatDecor)
    }

    /// Thousands of little grass tufts in the rough — one mesh, one draw
    /// call — so the rough reads as long grass instead of flat paint.
    private func buildRoughGrass() {
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var colors: [Float] = []
        let palette: [SIMD3<Float>] = [rgb(0x4E8F3A), rgb(0x5FA243), rgb(0x3F7A33), rgb(0x6FB04C)]
        let w = hole.sceneSize.width, l = hole.sceneSize.height
        let step: CGFloat = 4.2
        var y: CGFloat = 0
        while y < l {
            var x: CGFloat = 0
            while x < w {
                let p = CGPoint(x: x + CGFloat(rng.double() - 0.5) * step,
                                y: y + CGFloat(rng.double() - 0.5) * step)
                x += step
                guard hole.lie(at: p) == .rough else { continue }
                // Thinner right at the fairway edge (first cut).
                let edge = distanceToFairway(p)
                if edge < 10 && rng.double() < 0.75 { continue }
                let base = world(p, h: -0.05)
                let height = Float(0.7 + rng.double() * (edge < 14 ? 0.5 : 1.1))
                let color = palette[rng.int(palette.count)]
                for blade in 0..<3 {
                    let ang = Float(rng.double() * .pi) + Float(blade) * 1.05
                    let dx = cos(ang) * 0.32, dz = sin(ang) * 0.32
                    let lean = SIMD2<Float>(Float(rng.double() - 0.5) * 0.5, Float(rng.double() - 0.5) * 0.5)
                    let a = SCNVector3(base.x - dx, base.y, base.z - dz)
                    let b = SCNVector3(base.x + dx, base.y, base.z + dz)
                    let c = SCNVector3(base.x + lean.x, base.y + height, base.z + lean.y)
                    let n = SCNVector3(-dz, 0.4, dx)
                    let tip = color * 1.25
                    for (v, col) in [(a, color * 0.8), (b, color * 0.8), (c, tip)] {
                        positions.append(v)
                        normals.append(n)
                        colors += [col.x, col.y, col.z, 1]
                    }
                }
            }
            y += step
        }
        guard !positions.isEmpty else { return }
        let vSrc = SCNGeometrySource(vertices: positions)
        let nSrc = SCNGeometrySource(normals: normals)
        let cSrc = SCNGeometrySource(
            data: colors.withUnsafeBufferPointer { Data(buffer: $0) },
            semantic: .color, vectorCount: positions.count, usesFloatComponents: true,
            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let element = SCNGeometryElement(indices: (0..<UInt32(positions.count)).map { $0 },
                                         primitiveType: .triangles)
        let geo = SCNGeometry(sources: [vSrc, nSrc, cSrc], elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white
        m.lightingModel = .lambert
        m.isDoubleSided = true
        geo.firstMaterial = m
        tuftRoot.geometry = geo
        tuftRoot.castsShadow = false
        scene.rootNode.addChildNode(tuftRoot)
    }

    private func buildClouds() {
        for _ in 0..<9 {
            let cloud = SCNNode()
            let puffs = 3 + rng.int(3)
            for p in 0..<puffs {
                let r = CGFloat(10 + rng.double() * 9)
                let geo = SCNSphere(radius: r)
                geo.segmentCount = 16
                let m = SCNMaterial()
                m.diffuse.contents = UIColor.white
                m.lightingModel = .lambert
                m.emission.contents = UIColor(white: 0.55, alpha: 1)
                geo.firstMaterial = m
                let puff = SCNNode(geometry: geo)
                puff.position = SCNVector3(Float(p) * Float(r) * 1.1 - Float(puffs) * 8,
                                           Float(rng.double() * 4), Float(rng.double() * 6 - 3))
                puff.scale = SCNVector3(1, 0.6, 0.85)
                puff.castsShadow = false
                cloud.addChildNode(puff)
            }
            cloud.position = SCNVector3(Float(rng.double() * 1000 - 200),
                                        Float(280 + rng.double() * 90),
                                        Float(-(rng.double() * Double(hole.sceneSize.height + 600))))
            let drift = SCNAction.moveBy(x: 80, y: 0, z: 0, duration: 120)
            cloud.runAction(.repeatForever(.sequence([drift, drift.reversed()])))
            scene.rootNode.addChildNode(cloud)
        }
    }

    // MARK: - Putter

    /// A milled blade putter: tapered chrome shaft, rubber grip, hosel and
    /// a blade with a white sight line. Built hanging down local -Y from
    /// the hands, blade width along local Z.
    private func buildPutter() {
        let length: CGFloat = 3.4
        let chrome = SCNMaterial()
        chrome.lightingModel = .physicallyBased
        chrome.diffuse.contents = UIColor(white: 0.82, alpha: 1)
        chrome.metalness.contents = 1.0
        chrome.roughness.contents = 0.22

        let shaft = SCNNode(geometry: SCNCone(topRadius: 0.05, bottomRadius: 0.035, height: length))
        shaft.geometry?.firstMaterial = chrome
        shaft.position = SCNVector3(0, Float(-length / 2), 0)
        putterPivot.addChildNode(shaft)

        let grip = SCNNode(geometry: SCNCone(topRadius: 0.11, bottomRadius: 0.075, height: 1.0))
        let gm = SCNMaterial()
        gm.diffuse.contents = UIColor(hex: 0x1E2226)
        gm.lightingModel = .blinn
        gm.specular.contents = UIColor(white: 0.2, alpha: 1)
        grip.geometry?.firstMaterial = gm
        grip.position = SCNVector3(0, -0.5, 0)
        putterPivot.addChildNode(grip)

        let headRoot = SCNNode()
        headRoot.position = SCNVector3(0, Float(-length), 0)
        putterPivot.addChildNode(headRoot)

        let hosel = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 0.32))
        hosel.geometry?.firstMaterial = chrome
        hosel.position = SCNVector3(0, 0.05, 0)
        headRoot.addChildNode(hosel)

        let blade = SCNNode(geometry: SCNBox(width: 0.42, height: 0.36, length: 1.7, chamferRadius: 0.08))
        let bm = SCNMaterial()
        bm.lightingModel = .physicallyBased
        bm.diffuse.contents = UIColor(white: 0.62, alpha: 1)
        bm.metalness.contents = 0.9
        bm.roughness.contents = 0.35
        blade.geometry?.firstMaterial = bm
        // Heel-shafted: the blade sits toe-out, away from the hands.
        blade.position = SCNVector3(-0.05, -0.12, 0.62)
        headRoot.addChildNode(blade)

        let flange = SCNNode(geometry: SCNBox(width: 0.38, height: 0.06, length: 1.6, chamferRadius: 0.02))
        flange.geometry?.firstMaterial = GolferRig.lit(UIColor(hex: 0x2A2E33), shiny: true)
        flange.position = SCNVector3(-0.25, -0.27, 0.62)
        headRoot.addChildNode(flange)

        let sight = SCNNode(geometry: SCNBox(width: 0.32, height: 0.02, length: 0.06, chamferRadius: 0))
        sight.geometry?.firstMaterial = GolferRig.unlit(.white)
        sight.position = SCNVector3(-0.05, 0.065, 0.62)
        headRoot.addChildNode(sight)

        putterPivot.isHidden = true
        scene.rootNode.addChildNode(putterPivot)
    }

    /// Stand the putter behind the ball, square to the aim line.
    private func placePutter(ball spot: CGPoint, aim: CGVector) {
        let a = SIMD3<Float>(Float(aim.dx), 0, Float(-aim.dy))
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(a, up))      // screen-right of the aim line
        let ballW = world(spot, h: 0)
        let ball = SIMD3<Float>(ballW.x, ballW.y, ballW.z)
        // Blade centre just behind the ball; hands up and toward the
        // (invisible) golfer's side, shaft leaning slightly forward.
        let bladeCentre = ball - a * 0.75 + up * 0.3
        let hands = bladeCentre - right * 1.25 + up * 3.1 + a * 0.15
        let heel = bladeCentre - right * 0.62
        let down = simd_normalize(heel - hands)
        // Local frame: -Y along the shaft, X toward the target, Z = blade width.
        let yAxis = -down
        let xAxis = simd_normalize(a - yAxis * simd_dot(a, yAxis))
        let zAxis = simd_cross(xAxis, yAxis)
        putterBase = simd_quatf(simd_float3x3(columns: (xAxis, yAxis, zAxis)))
        // Rescale so the head lands exactly on the heel point.
        let length = simd_length(heel - hands)
        putterPivot.simdScale = SIMD3(1, length / 3.4, 1)
        putterPivot.simdPosition = hands
        putterAxis = right
        putterAngle = 0
        putterTarget = 0
        applyPutter()
    }

    private func applyPutter() {
        let swing = simd_quatf(angle: putterAngle, axis: putterAxis)
        putterPivot.simdOrientation = swing * putterBase
    }

    // MARK: - Golfer

    func setCharacter(_ name: String) {
        guard name != golferCharacter else { return }
        golferCharacter = name
        let old = golfer
        let fresh = GolferRig(character: name)
        fresh.node.simdTransform = old.node.simdTransform
        scene.rootNode.replaceChildNode(old.node, with: fresh.node)
        golfer = fresh
    }

    /// Mirror the putt/chip/full-swing pull. Pass nil to ease back to
    /// address.
    func setBackswing(_ amount: CGFloat?, kind: ShotKind) {
        guard let amount else {
            fingerDriven = false
            golfer.resetToAddress()
            putterTarget = 0
            return
        }
        fingerDriven = true
        switch kind {
        case .putt: putterTarget = -Float(amount) * 0.55
        case .chip: golfer.setBackswing(Float(amount) * 0.6)
        case .meter: golfer.setBackswing(Float(amount))
        }
    }

    enum SwingQuality { case pure, clean, mishit }

    /// Play the downswing; `impact` fires as the club meets the ball.
    func swingRelease(power: Double, kind: ShotKind, quality: SwingQuality,
                      impact: @escaping () -> Void) {
        fingerDriven = false
        let putting = kind == .putt
        if putting {
            // Pendulum: back through square at impact, a follow-through
            // matching the stroke, then settle.
            putterTarget = 0
            schedule(after: 0.11) { impact() }
            schedule(after: 0.12) { [weak self] in self?.putterTarget = 0.3 + 0.45 * Float(power) }
            schedule(after: 1.2) { [weak self] in self?.putterTarget = 0 }
            return
        }
        let finish: Float
        switch kind {
        case .putt: finish = 1
        case .chip: finish = 0.45 + 0.3 * Float(power)
        case .meter: finish = quality == .mishit ? 0.62 : 1
        }
        let steps = golfer.strike(power: Float(power), putting: putting, finish: finish) { [weak self] in
            impact()
            guard let self, !putting, power > 0.75 else { return }
            self.shakeCamera(CGFloat(power - 0.7) * 1.2)
        }
        for step in steps {
            schedule(after: step.delay) { [weak self] in
                guard let self else { return }
                step.apply(self.golfer)
            }
        }
    }

    func react(celebrate: Bool, dejected: Bool) {
        if celebrate { golfer.celebrate() } else if dejected { golfer.dejected() }
        schedule(after: 1.6) { [weak self] in self?.golfer.calm() }
    }

    private func schedule(after delay: Double, _ run: @escaping () -> Void) {
        timed.append((clock + delay, run))
    }

    private func shakeCamera(_ intensity: CGFloat) {
        guard intensity > 0.04 else { return }
        var actions: [SCNAction] = []
        var net = SCNVector3Zero
        for i in 0..<5 {
            let f = intensity * (1 - CGFloat(i) / 5) * 0.4
            let dx = CGFloat.random(in: -f...f), dy = CGFloat.random(in: -f...f) * 0.6
            net.x += Float(dx); net.y += Float(dy)
            actions.append(.moveBy(x: dx, y: dy, z: 0, duration: 0.03))
        }
        actions.append(.moveBy(x: CGFloat(-net.x), y: CGFloat(-net.y), z: 0, duration: 0.05))
        cameraNode.runAction(.sequence(actions))
    }

    // MARK: - Aiming & camera

    /// Stand the golfer at `spot`, facing along `aimDir`, and frame the
    /// shot from behind like Golf Dreams.
    /// `pitch` 0…1 lifts the camera from the address view up into a
    /// look-down-range view (free look).
    func aim(spot: CGPoint, aimDir: CGVector, kind: ShotKind, animated: Bool, pitch: CGFloat = 0) {
        let aimU = aimDir.normalized
        let putting = kind == .putt
        greenGridNode.isHidden = !putting

        switch kind {
        case .putt: golfer.setClub(.putter)
        case .chip: golfer.setClub(.iron)
        case .meter(let club): golfer.setClub(club == .driver || club == .wood3 ? .wood : .iron)
        }
        golfer.node.isHidden = putting
        putterPivot.isHidden = !putting
        golfer.place(ballWorld: world(spot, h: 0),
                     aim: SIMD3(Float(aimU.dx), 0, Float(-aimU.dy)))
        if putting { placePutter(ball: spot, aim: aimU) }

        let back: CGFloat, height: CGFloat, ahead: CGFloat, lookH: CGFloat
        switch kind {
        case .putt: (back, height, ahead, lookH) = (13, 7.5, 20, 0)
        case .chip: (back, height, ahead, lookH) = (21, 8, 45, 0)
        case .meter: (back, height, ahead, lookH) = (26, 9.5, 80, 2)
        }
        // Camera behind the ball, nudged right so the golfer sits left of
        // centre and the target line runs up the middle.
        let side: CGFloat = putting ? 0 : 3.5
        let lift: CGFloat, reach: CGFloat
        switch kind {
        case .putt: (lift, reach) = (26, 14)
        case .chip: (lift, reach) = (55, 50)
        case .meter: (lift, reach) = (130, 230)
        }
        let p = min(max(pitch, 0), 1)
        camGoal = world(spot + aimU * (-back * (1 - 0.45 * p)) + aimU.perpendicularRight * side * (1 - p),
                        h: height + lift * p)
        lookGoal = world(spot + aimU * (ahead + reach * p), h: lookH * (1 - p))
        if !animated || cameraMode == .intro {
            if cameraMode != .intro {
                cameraNode.position = camGoal
                lookCurrent = lookGoal
            }
        }
        if cameraMode != .intro { cameraMode = .address }
    }

    /// Overview flyover from behind the green back to the tee.
    func playIntro(completion: @escaping () -> Void) {
        // Start high behind the green looking back down the whole hole,
        // then swoop down to the tee — always above the treetops.
        let axis = CGVector(from: hole.tee, to: hole.pin).normalized
        let length = hole.tee.distance(to: hole.pin)
        let from = world(hole.pin + axis * 90, h: 110 + length * 0.08)
        let mid = CGPoint(x: (hole.tee.x + hole.pin.x) / 2, y: (hole.tee.y + hole.pin.y) / 2)
        let lookFrom = world(mid + axis * -length * 0.1, h: 0)
        introPath = (from, camGoal, lookFrom, lookGoal)
        introT = 0
        introCompletion = completion
        cameraMode = .intro
        cameraNode.position = from
        lookCurrent = lookFrom
    }

    func skipIntro() {
        guard cameraMode == .intro else { return }
        introT = 1
    }

    // MARK: - Ball

    func placeBall(at p: CGPoint, onTee: Bool) {
        playback = nil
        clearTracer()
        ball2D = p
        ballRest = Course3DScene.ballRadius + (onTee ? 0.5 : 0)
        ballH = ballRest
        ballNode.removeAllActions()
        ballNode.opacity = 1
        ballNode.scale = SCNVector3(1, 1, 1)
        ballShadow.opacity = 1
        teePeg.isHidden = !onTee
        teePeg.position = world(p, h: 0.25)
        syncBall()
    }

    func addMarker(at p: CGPoint, teamColorHex: UInt32) {
        let ballGeo = SCNSphere(radius: Course3DScene.ballRadius)
        ballGeo.firstMaterial = GolferRig.lit(.white)
        let b = SCNNode(geometry: ballGeo)
        b.position = world(p, h: Course3DScene.ballRadius)
        markerRoot.addChildNode(b)
        let ringGeo = SCNTube(innerRadius: 1.1, outerRadius: 1.5, height: 0.03)
        ringGeo.firstMaterial = GolferRig.unlit(UIColor(hex: teamColorHex).withAlphaComponent(0.9))
        let ring = SCNNode(geometry: ringGeo)
        ring.position = world(p, h: 0.1)
        markerRoot.addChildNode(ring)
        let pulse = SCNAction.sequence([.scale(to: 1.25, duration: 0.7), .scale(to: 1, duration: 0.7)])
        ring.runAction(.repeatForever(pulse))
    }

    func clearMarkers() {
        markerRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    /// Play a simulated shot. Completion fires on the main thread when the
    /// ball comes to rest (or drops / splashes).
    func play(_ tr: BallPhysics.Trajectory, aim: CGVector, speed: Double,
              tracerHex: UInt32?, completion: @escaping (BallPhysics.Trajectory) -> Void) {
        clearPreview()
        clearTracer()
        teePeg.isHidden = true
        playback = Playback(trajectory: tr, speed: speed, aim: aim.normalized,
                            tracerHex: tracerHex, completion: completion)
        // Hold on the follow-through for a beat (it's the payoff of the
        // swing), then chase the ball.
        let hold = tr.landing == nil ? 0.25 : 0.55
        schedule(after: hold) { [weak self] in
            guard let self, self.playback != nil || self.cameraMode == .address else { return }
            self.cameraMode = .follow
        }
    }

    // MARK: - Previews

    /// Dashed aim line from the ball with a landing ring at `carryYards`
    /// (still-air) — the ring is how you judge partial swings.
    func showAim(from spot: CGPoint, direction: CGVector, carryYards: Double?, lineYards: Double = 30) {
        clearPreview()
        let dir = direction.normalized
        let carry = CGFloat(carryYards ?? lineYards) * Hole.pointsPerYard
        var t: CGFloat = 6
        while t < carry - 4 {
            // Dots grow with distance so they read at the far end too.
            let geo = SCNCylinder(radius: 0.32 + t * 0.006, height: 0.02)
            geo.firstMaterial = GolferRig.unlit(UIColor.white.withAlphaComponent(0.85 - 0.45 * t / carry))
            let dot = SCNNode(geometry: geo)
            dot.position = world(spot + dir * t, h: 0.35)
            previewRoot.addChildNode(dot)
            t += max(5, carry / 22)
        }
        guard carryYards != nil else { return }
        let target = spot + dir * carry
        let r = max(2.6, carry * 0.045)
        let ringGeo = SCNTube(innerRadius: r - max(0.45, r * 0.14), outerRadius: r, height: 0.04)
        ringGeo.firstMaterial = GolferRig.unlit(UIColor.white.withAlphaComponent(0.9))
        let ring = SCNNode(geometry: ringGeo)
        ring.position = world(target, h: 0.4)
        previewRoot.addChildNode(ring)
        let dotGeo = SCNCylinder(radius: max(0.5, r * 0.18), height: 0.04)
        dotGeo.firstMaterial = GolferRig.unlit(UIColor.white)
        let center = SCNNode(geometry: dotGeo)
        center.position = world(target, h: 0.4)
        previewRoot.addChildNode(center)
    }

    /// Putt read: the first part of the real roll (you still have to read
    /// the rest of the break off the green).
    func showPuttRead(_ tr: BallPhysics.Trajectory, fraction: Double = 0.6) {
        clearPreview()
        let frames = tr.frames
        guard frames.count > 2 else { return }
        var travelled: CGFloat = 0
        var total: CGFloat = 0
        for i in 1..<frames.count { total += frames[i].p.distance(to: frames[i - 1].p) }
        var lastDot = frames[0].p
        for i in 1..<frames.count {
            travelled += frames[i].p.distance(to: frames[i - 1].p)
            if travelled > total * CGFloat(fraction) { break }
            if frames[i].p.distance(to: lastDot) >= 1.6 {
                lastDot = frames[i].p
                let geo = SCNCylinder(radius: 0.34, height: 0.02)
                let fade = 0.95 - 0.6 * Double(travelled / max(total * CGFloat(fraction), 1))
                geo.firstMaterial = GolferRig.unlit(UIColor.white.withAlphaComponent(fade))
                let dot = SCNNode(geometry: geo)
                dot.position = world(frames[i].p, h: 0.22)
                previewRoot.addChildNode(dot)
            }
        }
    }

    /// Your partner's putt, left on the green as the read for you.
    func showPartnerRead(_ path: [CGPoint], colorHex: UInt32) {
        clearPartnerRead()
        var last = CGPoint(x: -999, y: -999)
        for p in path where p.distance(to: last) >= 1.4 {
            last = p
            let geo = SCNCylinder(radius: 0.26, height: 0.02)
            geo.firstMaterial = GolferRig.unlit(UIColor(hex: colorHex).withAlphaComponent(0.85))
            let dot = SCNNode(geometry: geo)
            dot.position = world(p, h: 0.24)
            readRoot.addChildNode(dot)
        }
    }

    func clearPartnerRead() {
        readRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    /// Curved preview of a shaped shot: the still-air flight's ground
    /// track up to the landing, with the landing ring.
    func showFlightPreview(_ tr: BallPhysics.Trajectory, from spot: CGPoint, ring: Bool = true) {
        clearPreview()
        guard let landing = tr.landing else { return }
        let total = spot.distance(to: landing)
        var last = spot
        for f in tr.frames {
            if f.p.distance(to: last) < max(5, total / 22) { continue }
            if f.p.distance(to: spot) > total - 4 { break }
            last = f.p
            let t = f.p.distance(to: spot)
            let geo = SCNCylinder(radius: 0.32 + t * 0.006, height: 0.02)
            geo.firstMaterial = GolferRig.unlit(UIColor.white.withAlphaComponent(0.85 - 0.45 * t / total))
            let dot = SCNNode(geometry: geo)
            dot.position = world(f.p, h: 0.35)
            previewRoot.addChildNode(dot)
        }
        if ring { addLandingRing(at: landing, carry: total) }
    }

    private func addLandingRing(at target: CGPoint, carry: CGFloat) {
        let r = max(2.6, carry * 0.045)
        let ringGeo = SCNTube(innerRadius: r - max(0.45, r * 0.14), outerRadius: r, height: 0.04)
        ringGeo.firstMaterial = GolferRig.unlit(UIColor.white.withAlphaComponent(0.9))
        let ring = SCNNode(geometry: ringGeo)
        ring.position = world(target, h: 0.4)
        previewRoot.addChildNode(ring)
        let dotGeo = SCNCylinder(radius: max(0.5, r * 0.18), height: 0.04)
        dotGeo.firstMaterial = GolferRig.unlit(UIColor.white)
        let center = SCNNode(geometry: dotGeo)
        center.position = world(target, h: 0.4)
        previewRoot.addChildNode(center)
    }

    /// Toggle the overhead read of the putt: camera up over the line.
    func setReadView(_ on: Bool, spot: CGPoint) {
        if on {
            let mid = CGPoint(x: (spot.x + hole.pin.x) / 2, y: (spot.y + hole.pin.y) / 2)
            let len = spot.distance(to: hole.pin)
            let back = CGVector(from: hole.pin, to: spot).normalized
            readSaved = (camGoal, lookGoal)
            camGoal = world(mid + back * (len * 0.35 + 6), h: len * 0.75 + 12)
            lookGoal = world(mid, h: 0)
        } else if let saved = readSaved {
            camGoal = saved.cam
            lookGoal = saved.look
            readSaved = nil
        }
    }
    private var readSaved: (cam: SCNVector3, look: SCNVector3)?

    func clearPreview() {
        previewRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    private func clearTracer() {
        tracerRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    // MARK: - Effects

    func playImpactEffect(perfect: Bool) {
        let colors: [UInt32] = perfect ? [0xFFF7D6, 0xFFD98A, 0xFFFFFF] : [0xF5EFDA, 0xD6BE8B]
        for i in 0..<(perfect ? 12 : 6) {
            let spark = SCNNode(geometry: SCNSphere(radius: CGFloat.random(in: 0.06...0.14)))
            spark.geometry?.firstMaterial = GolferRig.unlit(UIColor(hex: colors[i % colors.count]))
            spark.position = world(ball2D, h: 0.5)
            scene.rootNode.addChildNode(spark)
            let travel = SCNAction.group([
                .moveBy(x: CGFloat.random(in: -1.6...1.6), y: CGFloat.random(in: 0.6...2.4),
                        z: CGFloat.random(in: -1.6...1.6), duration: 0.25),
                .fadeOut(duration: 0.25)
            ])
            travel.timingMode = .easeOut
            spark.runAction(.sequence([travel, .removeFromParentNode()]))
        }
    }

    private func puff(at p: CGPoint, lie: Lie) {
        let colors: [UInt32]
        let count: Int
        switch lie {
        case .bunker: colors = [0xF1DCA8, 0xD8BC82]; count = 14
        case .rough, .trees: colors = [0x5A9A42, 0x7DC25A]; count = 7
        case .water: return
        default: colors = [0xE9F3DE, 0xB9DB98]; count = 5
        }
        for i in 0..<count {
            let mote = SCNNode(geometry: SCNSphere(radius: CGFloat.random(in: 0.08...0.18)))
            mote.geometry?.firstMaterial = GolferRig.unlit(UIColor(hex: colors[i % colors.count]))
            mote.position = world(p, h: 0.2)
            scene.rootNode.addChildNode(mote)
            let rise = SCNAction.group([
                .moveBy(x: CGFloat.random(in: -1.5...1.5), y: CGFloat.random(in: 0.5...(lie == .bunker ? 2.6 : 1.4)),
                        z: CGFloat.random(in: -1.5...1.5), duration: 0.35),
                .fadeOut(duration: 0.35)
            ])
            rise.timingMode = .easeOut
            mote.runAction(.sequence([rise, .removeFromParentNode()]))
        }
    }

    private func splash(at p: CGPoint) {
        SoundFX.play("splash", volume: 0.8)
        for d in [0.0, 0.18, 0.36] { ring(at: p, hex: 0xFFFFFF, delay: d) }
        for _ in 0..<10 {
            let drop = SCNNode(geometry: SCNSphere(radius: 0.15))
            drop.geometry?.firstMaterial = GolferRig.unlit(UIColor(hex: 0xD8EEFA))
            drop.position = world(p, h: 0)
            scene.rootNode.addChildNode(drop)
            let up = SCNAction.moveBy(x: CGFloat.random(in: -1...1), y: CGFloat.random(in: 1.5...3),
                                      z: CGFloat.random(in: -1...1), duration: 0.25)
            up.timingMode = .easeOut
            let down = SCNAction.moveBy(x: 0, y: -3, z: 0, duration: 0.25)
            down.timingMode = .easeIn
            drop.runAction(.sequence([up, .group([down, .fadeOut(duration: 0.25)]), .removeFromParentNode()]))
        }
        ballNode.runAction(.fadeOut(duration: 0.2))
        ballShadow.opacity = 0
    }

    private func cupDrop() {
        SoundFX.play("cup_drop", volume: 0.9)
        for _ in 0..<12 {
            let spark = SCNNode(geometry: SCNSphere(radius: CGFloat.random(in: 0.1...0.2)))
            spark.geometry?.firstMaterial = GolferRig.unlit(UIColor(hex: Bool.random() ? 0xFFFFFF : 0xFFD98A))
            spark.position = world(hole.pin, h: 0.3)
            scene.rootNode.addChildNode(spark)
            let up = SCNAction.group([
                .moveBy(x: CGFloat.random(in: -2...2), y: CGFloat.random(in: 2...4.5),
                        z: CGFloat.random(in: -2...2), duration: 0.55),
                .fadeOut(duration: 0.55)
            ])
            up.timingMode = .easeOut
            spark.runAction(.sequence([up, .removeFromParentNode()]))
        }
        ballNode.runAction(.group([.moveBy(x: 0, y: -0.6, z: 0, duration: 0.15), .fadeOut(duration: 0.15)]))
        ballShadow.opacity = 0
        ring(at: hole.pin, hex: 0xFFFFFF, delay: 0)
        flagNode.runAction(.sequence([.moveBy(x: 0, y: 1.2, z: 0, duration: 0.1),
                                      .moveBy(x: 0, y: -1.2, z: 0, duration: 0.2)]))
    }

    private func ring(at p: CGPoint, hex: UInt32, delay: TimeInterval) {
        let geo = SCNTube(innerRadius: 0.9, outerRadius: 1.05, height: 0.02)
        geo.firstMaterial = GolferRig.unlit(UIColor(hex: hex).withAlphaComponent(0.85))
        let node = SCNNode(geometry: geo)
        node.position = world(p, h: 0.15)
        node.opacity = 0
        scene.rootNode.addChildNode(node)
        node.runAction(.sequence([
            .wait(duration: delay),
            .fadeIn(duration: 0.05),
            .group([.scale(to: 3.6, duration: 0.6), .fadeOut(duration: 0.6)]),
            .removeFromParentNode()
        ]))
    }

    // MARK: - Per-frame update

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = (lastTick > 0 ? min(now - lastTick, 1.0 / 20.0) : 0) * Course3DScene.timeScale
        lastTick = now
        guard dt > 0 else { return }
        clock += dt

        // Timed callbacks (swing phases etc.)
        if !timed.isEmpty {
            let due = timed.filter { $0.at <= clock }
            timed.removeAll { $0.at <= clock }
            due.forEach { $0.run() }
        }

        golfer.update(dt: Float(dt), snap: fingerDriven ? 34 : 0)
        if !putterPivot.isHidden {
            let rate: Float = fingerDriven ? 30 : 22
            putterAngle += (putterTarget - putterAngle) * (1 - exp(-rate * Float(dt)))
            applyPutter()
        }

        if var pb = playback {
            let finished = advance(&pb, dt: dt)
            playback = finished ? nil : pb
        }

        updateCamera(dt: dt)
    }

    /// Returns true when the ball has come to rest.
    private func advance(_ pb: inout Playback, dt: Double) -> Bool {
        let tr = pb.trajectory
        pb.t += dt * pb.speed
        let frames = tr.frames
        let fi = pb.t * 60
        let i = min(Int(fi), frames.count - 1)
        let next = min(i + 1, frames.count - 1)
        let frac = CGFloat(fi - Double(i))
        let a = frames[i], b = frames[next]
        ball2D = CGPoint(x: a.p.x + (b.p.x - a.p.x) * frac, y: a.p.y + (b.p.y - a.p.y) * frac)
        ballH = Course3DScene.ballRadius + a.h + (b.h - a.h) * frac
        syncBall()

        // Fire events whose time has come.
        while pb.nextEvent < tr.events.count && tr.events[pb.nextEvent].t <= pb.t {
            switch tr.events[pb.nextEvent].event {
            case .landed(let lie), .bounce(let lie):
                puff(at: ball2D, lie: lie)
                let first: Bool
                if case .landed = tr.events[pb.nextEvent].event { first = true } else { first = false }
                let vol: Float = first ? 0.6 : 0.3
                switch lie {
                case .bunker: SoundFX.play("land_sand", volume: vol)
                case .green, .fringe: SoundFX.play("land_green", volume: vol)
                case .water: break
                default: SoundFX.play("land_turf", volume: vol)
                }
            case .treeHit:
                SoundFX.play("tree_hit", volume: 0.7)
            case .lipOut:
                SoundFX.play("lip_out", volume: 0.8)
                SoundFX.play("crowd_ohh", volume: 0.55, after: 0.25)
                Haptics.rumble()
            }
            pb.nextEvent += 1
        }

        // Tracer while airborne.
        if let hex = pb.tracerHex, a.h > 0.6, i - pb.tracerFrame >= 2 {
            pb.tracerFrame = i
            let geo = SCNSphere(radius: 0.16)
            geo.segmentCount = 8
            geo.firstMaterial = GolferRig.unlit(UIColor(hex: hex).withAlphaComponent(0.85))
            let dot = SCNNode(geometry: geo)
            dot.position = world(a.p, h: a.h + Course3DScene.ballRadius)
            dot.castsShadow = false
            tracerRoot.addChildNode(dot)
        }

        guard pb.t >= tr.duration else { return false }
        switch tr.finish {
        case .water: splash(at: tr.end)
        case .holed: cupDrop()
        case .rest: break
        }
        let done = pb.completion
        // Let the moment breathe before the result card.
        schedule(after: tr.finish == .rest ? 0.45 : 0.9) { done(tr) }
        return true
    }

    private func updateCamera(dt: Double) {
        let k: Float
        switch cameraMode {
        case .intro:
            guard let path = introPath else { break }
            introT = min(introT + dt / 3.6, 1)
            let e = Float(introT < 0.5 ? 4 * introT * introT * introT
                          : 1 - pow(-2 * introT + 2, 3) / 2)
            // Arc up and over on the way back to the tee.
            let lift = Float(sin(introT * .pi)) * 55
            cameraNode.position = mix(path.from, path.to, e) + SCNVector3(0, lift, 0)
            lookCurrent = mix(path.lookFrom, path.lookTo, e)
            cameraNode.look(at: lookCurrent, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            if introT >= 1 {
                cameraMode = .address
                let done = introCompletion
                introCompletion = nil
                done?()
            }
            return
        case .follow:
            if let pb = playback {
                // Chase from behind and above; as the ball comes down the
                // camera slows and looks at where it's landing.
                // Chase from behind and ABOVE the ball so the horizon stays
                // in frame; look slightly ahead of and below the ball.
                let aim = pb.aim
                let airborne = ballH > Course3DScene.ballRadius + 0.5
                let putting = pb.trajectory.landing == nil
                let back: CGFloat = putting ? 9 : (airborne ? 42 : 22)
                let height: CGFloat = putting ? 3.8 : (airborne ? 14 + ballH * 0.85 : 9)
                camGoal = world(ball2D + aim * -back, h: height)
                let ahead = airborne ? aim * 30 : aim * 4
                lookGoal = world(ball2D + ahead, h: max(ballH * 0.55, 1))
                k = Float(1 - exp(-2.4 * dt))
            } else {
                k = Float(1 - exp(-3 * dt))
            }
            cameraNode.position = mix(cameraNode.position, camGoal, k)
            lookCurrent = mix(lookCurrent, lookGoal, Float(1 - exp(-7 * dt)))
            cameraNode.look(at: lookCurrent, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            return
        case .address, .overview:
            // Watching the ball leave from the address camera: turn to
            // keep it in frame until the chase kicks in.
            if playback != nil {
                let b = world(ball2D, h: ballH)
                lookGoal = SCNVector3((lookGoal.x * 3 + b.x) / 4, (lookGoal.y * 3 + b.y) / 4,
                                      (lookGoal.z * 3 + b.z) / 4)
            }
        }
        k = Float(1 - exp(-4 * dt))
        cameraNode.position = mix(cameraNode.position, camGoal, k)
        lookCurrent = mix(lookCurrent, lookGoal, Float(1 - exp(-5 * dt)))
        cameraNode.look(at: lookCurrent, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }

    private func syncBall() {
        ballNode.position = world(ball2D, h: ballH)
        ballShadow.position = world(ball2D, h: 0.04)
        let air = max(ballH - ballRest, 0)
        ballShadow.opacity = CGFloat(max(0.08, 1 - Double(air) / 60))
        let spread = Float(1 + air / 40)
        ballShadow.scale = SCNVector3(spread, 1, spread)
    }

    // MARK: - Geometry helpers

    /// Hole point → world, `h` above the ground.
    func world(_ p: CGPoint, h: CGFloat) -> SCNVector3 {
        SCNVector3(Float(p.x), Float(groundHeight(p) + h), Float(-p.y))
    }

    /// Project a hole point to view coordinates (for SwiftUI labels).
    func project(_ p: CGPoint, in view: SCNView?) -> CGPoint? {
        guard let view else { return nil }
        let v = view.projectPoint(world(p, h: 1))
        guard v.z < 1 else { return nil }
        return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y))
    }

    private func mix(_ a: SCNVector3, _ b: SCNVector3, _ t: Float) -> SCNVector3 {
        SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
    }

    private func smoothstep(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    /// Cheap smooth 2D value noise in 0…1.
    private func valueNoise(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        func hash(_ i: Int, _ j: Int) -> CGFloat {
            let s = sin(Double(i) * 127.1 + Double(j) * 311.7) * 43758.5453
            return CGFloat(s - floor(s))
        }
        let xi = Int(floor(x)), yi = Int(floor(y))
        let xf = x - floor(x), yf = y - floor(y)
        let u = smoothstep(xf), v = smoothstep(yf)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    static func material(_ hex: UInt32) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(hex: hex)
        m.lightingModel = .lambert
        return m
    }

    /// Bright day sky: deep blue overhead fading to a warm, hazy horizon.
    private static func skyImage() -> UIImage {
        let size = CGSize(width: 8, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(hex: 0x4F93D8).cgColor, UIColor(hex: 0x8EC3EC).cgColor,
                          UIColor(hex: 0xD3E9F2).cgColor, UIColor(hex: 0xEFE8D2).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                  locations: [0, 0.38, 0.5, 0.56])!
            ctx.cgContext.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height),
                                             options: [.drawsAfterEndLocation])
        }
    }
}

private func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
}

/// Deterministic RNG so every phone builds the same course.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
        return z ^ (z >> 33)
    }
    mutating func double() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
}
