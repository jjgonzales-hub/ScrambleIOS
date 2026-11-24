import SceneKit
import UIKit
import simd

/// A Kenney Mini Character (CC0) posed procedurally as a golfer.
///
/// The character file is split into rigid parts (root, torso, head, arms,
/// legs — see tools/assets/convert_chars.py). At load we build a golf
/// stance from them: bent at the hips, both arms hanging to a grip in front
/// of the body, and a club in the hands. The swing is a rotation of the
/// arms + club about the tilted swing plane, layered with a torso coil, a
/// hip turn, a still head, and footwork — every frame is driven by code, so
/// the backswing can follow the player's finger exactly (Golf Dreams-style).
///
/// Local frame of `node`: +X = target direction, +Z = facing the ball,
/// +Y = up. The ball sits at `ballOffset` in this frame.
final class GolferRig {
    enum ClubStyle { case wood, iron, putter }

    let node = SCNNode()
    /// Where the ball sits relative to `node` (address).
    private(set) var ballOffset = SCNVector3Zero

    private let model: SCNNode
    private let torso: SCNNode
    private let head: SCNNode?
    private let legL: SCNNode?
    private let legR: SCNNode?
    private let swingPivot = SCNNode()
    private let planeNode = SCNNode()
    private let clubNode = SCNNode()
    private var clubHeads: [ClubStyle: SCNNode] = [:]
    private var shafts: [ClubStyle: SCNNode] = [:]
    private let blob: SCNNode

    private let torsoRest: simd_quatf
    private let headRest: simd_quatf
    private let legLRest: simd_quatf
    private let legRRest: simd_quatf

    /// Character height in world units.
    static let height: CGFloat = 6.4

    // Pose state (0 = address). All eased every frame in `update`.
    struct Pose {
        var swing: Float = 0     // rad about the swing plane, + = backswing
        var coil: Float = 0      // torso twist, + = away from target
        var hips: Float = 0      // hip turn, + = toward target
        var bend: Float = 0.28   // forward bend at the hips
        var sway: Float = 0      // weight shift, + = toward target
        var trailHeel: Float = 0 // trail leg pivot onto the toe (follow-through)
        var arms: Float = 0      // 0 = grip, 1 = arms up (celebrate)
        var slump: Float = 0     // head down
        var hop: Float = 0
    }
    var target = Pose()
    private var current = Pose()

    // MARK: - Asset cache

    private static var library: SCNScene? = {
        guard let url = Bundle.main.url(forResource: "Golfers", withExtension: "usdz") else { return nil }
        return try? SCNScene(url: url, options: nil)
    }()

    static let characters = ["male_a", "female_b", "male_e", "female_d",
                             "male_c", "female_a", "male_f", "female_e",
                             "male_b", "female_c", "male_d", "female_f", "male_g"]

    init(character: String) {
        let source = GolferRig.library?.rootNode.childNode(withName: character, recursively: true)
            ?? GolferRig.library?.rootNode.childNode(withName: "male_a", recursively: true)
        let model = source?.clone() ?? SCNNode()
        model.position = SCNVector3Zero
        self.model = model

        func part(_ name: String) -> SCNNode? {
            model.childNode(withName: "\(character)_\(name)", recursively: true)
                ?? model.childNodes(passingTest: { n, _ in n.name?.hasSuffix("_\(name)") == true }).first
        }
        torso = part("torso") ?? SCNNode()
        head = part("head")
        legL = part("leg_left")
        legR = part("leg_right")
        let armL = part("arm_left")
        let armR = part("arm_right")

        // Measure the model to scale it to a consistent golfer height.
        let (mn, mx) = model.boundingBox
        let rawHeight = max(CGFloat(mx.y - mn.y), 0.01)
        let s = Float(GolferRig.height / rawHeight)
        model.scale = SCNVector3(s, s, s)
        node.addChildNode(model)

        // Soft contact shadow under the feet.
        let blobGeo = SCNCylinder(radius: 1.9, height: 0.02)
        blobGeo.firstMaterial = GolferRig.unlit(UIColor.black.withAlphaComponent(0.22))
        blob = SCNNode(geometry: blobGeo)
        blob.position = SCNVector3(0, 0.06, 0.2)
        node.addChildNode(blob)

        // ---- Swing assembly ----
        // Pivot between the shoulders, inside the torso so the coil and
        // the bend carry it.
        let shoulderY: Float
        if let armL, let armR {
            let a = armL.convertPosition(SCNVector3Zero, to: torso)
            let b = armR.convertPosition(SCNVector3Zero, to: torso)
            shoulderY = (a.y + b.y) / 2
            swingPivot.position = SCNVector3(0, shoulderY, (a.z + b.z) / 2)
        } else {
            shoulderY = 0.11
            swingPivot.position = SCNVector3(0, shoulderY, 0)
        }
        torso.addChildNode(planeNode)
        planeNode.position = swingPivot.position
        swingPivot.position = SCNVector3Zero
        planeNode.addChildNode(swingPivot)

        // Arm length from the mesh, so the grip sits where the hands meet.
        var armLength: Float = 0.13
        if let armL, let geo = armL.childNodes.first {
            let (amn, amx) = geo.boundingBox
            armLength = max(abs(amx.x), abs(amn.x)) * 0.92
        }

        // Grip point in plane space: below and in front of the chest.
        var halfShoulder: Float = 0.1
        if let armL {
            halfShoulder = abs(armL.convertPosition(SCNVector3Zero, to: planeNode).x)
        }
        // Kenney arms are long for the body, so fully extended they'd put
        // the hands on the ground. Hold the grip at belt height in front of
        // the body instead (hands overlap a little — reads fine).
        let reach = max(armLength * armLength - halfShoulder * halfShoulder, 0.002).squareRoot()
        let grip = SIMD3<Float>(0, -reach * 0.42, reach * 0.62)

        // Hang both arms to the grip (rest direction is ±X in the T-pose).
        for (arm, side) in [(armL, Float(1)), (armR, Float(-1))] {
            guard let arm else { continue }
            let world = arm.worldTransform
            swingPivot.addChildNode(arm)
            arm.setWorldTransform(world)
            let shoulder = SIMD3<Float>(arm.simdPosition)
            let toGrip = simd_normalize(grip - shoulder)
            arm.simdOrientation = simd_quatf(from: SIMD3(side, 0, 0), to: toGrip)
        }

        // Club in the hands, pointing down to the ball.
        clubNode.simdPosition = grip
        swingPivot.addChildNode(clubNode)

        torsoRest = torso.simdOrientation
        headRest = head?.simdOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        legLRest = legL?.simdOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        legRRest = legR?.simdOrientation ?? simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))

        buildClubs()
        // Settle the address pose once so we can measure where the club
        // head touches the ground — that's where the ball goes.
        current = target
        apply(current)
        calibrateClub()
        setClub(.wood)
    }

    // MARK: - Clubs

    private func buildClubs() {
        // Model units (the character is ~0.67 tall). Shaft hangs down -Y;
        // the head's face points +X (the target), toe toward +Z.
        let chrome = SCNMaterial()
        chrome.lightingModel = .physicallyBased
        chrome.diffuse.contents = UIColor(white: 0.85, alpha: 1)
        chrome.metalness.contents = 1.0
        chrome.roughness.contents = 0.2
        let rubber = SCNMaterial()
        rubber.diffuse.contents = UIColor(hex: 0x1C1F23)
        rubber.lightingModel = .blinn
        rubber.specular.contents = UIColor(white: 0.15, alpha: 1)
        let carbon = SCNMaterial()
        carbon.lightingModel = .physicallyBased
        carbon.diffuse.contents = UIColor(hex: 0x1A1F27)
        carbon.metalness.contents = 0.6
        carbon.roughness.contents = 0.18
        let satin = SCNMaterial()
        satin.lightingModel = .physicallyBased
        satin.diffuse.contents = UIColor(white: 0.7, alpha: 1)
        satin.metalness.contents = 0.95
        satin.roughness.contents = 0.38

        for style in [ClubStyle.wood, .iron, .putter] {
            let shaft = SCNNode()
            // First child = the rod; calibrateClub stretches it to length.
            let rod = SCNNode(geometry: SCNCone(topRadius: 0.0075, bottomRadius: 0.005, height: 1))
            rod.geometry?.firstMaterial = chrome
            rod.position = SCNVector3(0, -0.5, 0)
            shaft.addChildNode(rod)
            let grip = SCNNode(geometry: SCNCone(topRadius: 0.0098, bottomRadius: 0.0072, height: 0.24))
            grip.geometry?.firstMaterial = rubber
            grip.position = SCNVector3(0, -0.12, 0)
            shaft.addChildNode(grip)

            let head = SCNNode()
            let hosel = SCNNode(geometry: SCNCone(topRadius: 0.0042, bottomRadius: 0.0062, height: 0.03))
            hosel.geometry?.firstMaterial = style == .wood ? carbon : chrome
            hosel.position = SCNVector3(0, 0.012, 0)
            head.addChildNode(hosel)
            switch style {
            case .wood:
                // Big rounded 460cc-style head with a silver face.
                let body = SCNNode(geometry: SCNSphere(radius: 0.03))
                body.geometry?.firstMaterial = carbon
                body.scale = SCNVector3(0.92, 0.55, 1.18)
                body.position = SCNVector3(-0.006, -0.004, 0.028)
                head.addChildNode(body)
                let face = SCNNode(geometry: SCNBox(width: 0.003, height: 0.026, length: 0.052, chamferRadius: 0.0015))
                face.geometry?.firstMaterial = satin
                face.position = SCNVector3(0.021, -0.004, 0.028)
                head.addChildNode(face)
            case .iron:
                // Forged blade with a cavity back.
                let blade = SCNNode(geometry: SCNBox(width: 0.007, height: 0.026, length: 0.05, chamferRadius: 0.002))
                blade.geometry?.firstMaterial = chrome
                blade.position = SCNVector3(0.002, -0.006, 0.026)
                blade.eulerAngles.z = 0.35        // loft
                head.addChildNode(blade)
                let sole = SCNNode(geometry: SCNBox(width: 0.012, height: 0.008, length: 0.048, chamferRadius: 0.003))
                sole.geometry?.firstMaterial = satin
                sole.position = SCNVector3(-0.002, -0.017, 0.026)
                head.addChildNode(sole)
            case .putter:
                let blade = SCNNode(geometry: SCNBox(width: 0.01, height: 0.012, length: 0.05, chamferRadius: 0.002))
                blade.geometry?.firstMaterial = satin
                blade.position = SCNVector3(0, -0.006, 0.024)
                head.addChildNode(blade)
            }
            // Cartoon proportions: chunky heads to match chunky golfers.
            head.scale = SCNVector3(1.5, 1.5, 1.5)
            shaft.addChildNode(head)
            shafts[style] = shaft
            clubHeads[style] = head
            clubNode.addChildNode(shaft)
        }
    }

    private var shaftLength: [ClubStyle: Float] = [:]

    /// Point each shaft from the grip to the ground in front of the golfer
    /// and stretch it to reach. Done once in the address pose.
    private func calibrateClub() {
        node.simdTransform = matrix_identity_float4x4
        for (style, shaft) in shafts {
            // Lie angle: putter more upright and shorter.
            let down: SIMD3<Float> = style == .putter
                ? simd_normalize(SIMD3(0, -1, 1.05))
                : simd_normalize(SIMD3(0, -1, style == .wood ? 1.45 : 1.15))
            // The shaft's local -Y runs from grip to head.
            shaft.simdOrientation = simd_quatf(from: SIMD3(0, -1, 0), to: down)
            // Find the length that puts the head on the ground.
            var lo: Float = 0.05, hi: Float = 0.6
            for _ in 0..<24 {
                let mid = (lo + hi) / 2
                let tip = shaft.convertPosition(SCNVector3(0, -mid, 0), to: node)
                if tip.y > 0.16 { lo = mid } else { hi = mid }
            }
            let len = (lo + hi) / 2
            shaftLength[style] = len
            shaft.childNodes.first?.scale = SCNVector3(1, len, 1)
            shaft.childNodes.first?.position = SCNVector3(0, -len / 2, 0)
            clubHeads[style]?.position = SCNVector3(0, -len, 0)
        }
    }

    func setClub(_ style: ClubStyle) {
        for (s, shaft) in shafts { shaft.isHidden = s != style }
        if let headNode = clubHeads[style] {
            let saved = current
            apply(Pose())
            let p = headNode.convertPosition(SCNVector3Zero, to: node)
            // Square face, ball resting against it on the target side.
            ballOffset = SCNVector3(p.x + 0.5, 0, p.z)
            apply(saved)
        }
        // Putting stance: more bend, quieter body.
        target.bend = style == .putter ? 0.36 : 0.28
    }

    // MARK: - Placement

    /// Stand at address to `ball` (world), with `aim` (unit, world XZ) the
    /// target line.
    func place(ballWorld ball: SCNVector3, aim: SIMD3<Float>) {
        let x = simd_normalize(SIMD3(aim.x, 0, aim.z))
        let y = SIMD3<Float>(0, 1, 0)
        let z = simd_cross(x, y)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(x, 0)
        m.columns.1 = SIMD4(y, 0)
        m.columns.2 = SIMD4(z, 0)
        let off = x * ballOffset.x + z * ballOffset.z
        m.columns.3 = SIMD4(SIMD3(ball.x, ball.y, ball.z) - off, 1)
        node.simdTransform = m
    }

    /// World position of the club head right now (for effects).
    var clubHeadWorld: SCNVector3 {
        for (style, shaft) in shafts where !shaft.isHidden {
            return clubHeads[style]?.worldPosition ?? node.worldPosition
        }
        return node.worldPosition
    }

    // MARK: - Animation

    private var idleTime: Float = 0

    /// Ease the current pose toward `target` and apply it. `snap` makes the
    /// swing component track the target immediately (finger following).
    func update(dt: Float, snap: Float = 0.0) {
        idleTime += dt
        let k = 1 - exp(-18 * dt)
        let kSwing = snap > 0 ? 1 - exp(-snap * dt) : k
        current.swing += (target.swing - current.swing) * kSwing
        current.coil += (target.coil - current.coil) * kSwing
        current.hips += (target.hips - current.hips) * kSwing
        current.sway += (target.sway - current.sway) * kSwing
        current.trailHeel += (target.trailHeel - current.trailHeel) * k
        current.bend += (target.bend - current.bend) * k
        current.arms += (target.arms - current.arms) * (1 - exp(-10 * dt))
        current.slump += (target.slump - current.slump) * (1 - exp(-6 * dt))
        current.hop += (target.hop - current.hop) * (1 - exp(-14 * dt))
        apply(current)
    }

    private func apply(_ p: Pose) {
        // Breathing keeps the address from looking frozen.
        let breath = sin(idleTime * 2.1) * 0.012

        // Torso: hip turn about the vertical, forward bend, then the coil
        // about the (bent) spine.
        let qHips = simd_quatf(angle: p.hips * 0.6, axis: SIMD3(0, 1, 0))
        let qBend = simd_quatf(angle: p.bend + breath + p.slump * 0.25, axis: SIMD3(1, 0, 0))
        let qCoil = simd_quatf(angle: -p.coil, axis: SIMD3(0, 1, 0))
        torso.simdOrientation = torsoRest * qHips * qBend * qCoil
        torso.simdPosition.x = p.sway * 0.03

        // Head stays on the ball: undo most of the coil and the bend.
        if let head {
            let qKeep = simd_quatf(angle: p.coil * 0.85 - p.hips * 0.4, axis: SIMD3(0, 1, 0))
            let qNod = simd_quatf(angle: -(p.bend * 0.35) + p.slump * 0.55, axis: SIMD3(1, 0, 0))
            head.simdOrientation = headRest * qKeep * qNod
        }

        // Swing plane: contains the target line and the shaft. Its normal
        // in plane space is roughly (0, -0.6, -0.8); rotating about it
        // swings the club away from the target and up.
        let planeAxis = simd_normalize(SIMD3<Float>(0, -0.62, -0.78))
        let qSwing = simd_quatf(angle: p.swing, axis: planeAxis)
        // Celebrate: arms up overrides the grip.
        let qArms = simd_quatf(angle: -p.arms * 2.6, axis: SIMD3(1, 0, 0))
        swingPivot.simdOrientation = qArms * qSwing
        clubNode.isHidden = p.arms > 0.5

        // Legs: athletic stance, lead leg posts, trail heel lifts.
        let stance: Float = 0.12
        legL?.simdOrientation = legLRest
            * simd_quatf(angle: stance + p.sway * 0.06, axis: SIMD3(0, 0, 1))
        legR?.simdOrientation = legRRest
            * simd_quatf(angle: -stance + p.sway * 0.06, axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: -p.trailHeel * 0.35, axis: SIMD3(1, 0, 0))

        model.simdPosition.y = p.hop * 0.06
    }

    // MARK: - High-level moves

    /// Finger-driven backswing, 0…1 (full) — chips use part of it.
    func setBackswing(_ amount: Float, putting: Bool = false) {
        if putting {
            target.swing = amount * 0.55
            target.coil = 0
            target.hips = 0
        } else {
            target.swing = amount * 2.55
            target.coil = amount * 1.05
            target.hips = -amount * 0.35
            target.sway = -amount * 0.6
        }
    }

    func resetToAddress() {
        let bend = target.bend
        target = Pose()
        target.bend = bend
    }

    /// Downswing → impact → finish, timed in real seconds. `impact` fires
    /// when the club reaches the ball.
    func strike(power: Float, putting: Bool, finish: Float,
                impact: @escaping () -> Void) -> [(delay: Double, apply: (GolferRig) -> Void)] {
        if putting {
            let follow = -(0.25 + 0.55 * power)
            return [
                (0.0, { $0.target.swing = 0 }),
                (0.11, { _ in impact() }),
                (0.12, { $0.target.swing = follow }),
                (1.1, { $0.resetToAddress() })
            ]
        }
        let down = Double(max(0.16 - 0.06 * power, 0.1))
        return [
            // Hips fire first, then the arms.
            (0.0, { $0.target.hips = 0.5; $0.target.sway = 0.4 }),
            (0.04, { $0.target.swing = 0; $0.target.coil = 0.1 }),
            (down, { _ in impact() }),
            (down + 0.01, {
                $0.target.swing = -2.7 * finish
                $0.target.coil = -1.25 * finish
                $0.target.hips = 1.4 * finish
                $0.target.sway = 1.0
                $0.target.trailHeel = finish
            }),
            (2.0, { $0.resetToAddress() })
        ]
    }

    func celebrate() {
        target.arms = 1
        target.hop = 1
        target.slump = 0
    }

    func dejected() {
        target.slump = 1
        target.arms = 0
    }

    func calm() {
        target.arms = 0
        target.hop = 0
        target.slump = 0
    }

    // MARK: - Materials

    static func lit(_ color: UIColor, shiny: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .blinn
        m.specular.contents = UIColor(white: 1, alpha: shiny ? 0.6 : 0.15)
        m.shininess = shiny ? 40 : 8
        return m
    }

    static func unlit(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .constant
        m.writesToDepthBuffer = false
        return m
    }
}
