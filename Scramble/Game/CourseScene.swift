import SpriteKit
import UIKit

/// Top-down cartoon course — flat muted colors, soft dark outlines, and
/// restrained animation (a little squash on landing, gentle ripples, no
/// confetti). The whole hole is visible at once (aspectFit), letterboxed
/// into the ink background.
final class CourseScene: SKScene {
    let hole: Hole

    private let ballNode = SKShapeNode(circleOfRadius: 9)
    private let ballShadow = SKShapeNode(ellipseOf: CGSize(width: 16, height: 8))
    private var markers: [SKNode] = []
    private var previewNode = SKNode()
    private var flagNode = SKNode()

    // Putt simulation state
    private var puttVelocity = CGVector.zero
    private var puttActive = false
    private var lastUpdateTime: TimeInterval = 0
    var onPuttEnded: ((Bool, CGPoint) -> Void)?

    init(hole: Hole) {
        self.hole = hole
        super.init(size: hole.sceneSize)
        scaleMode = .aspectFit
        backgroundColor = SceneColors.ink
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func didMove(to view: SKView) {
        buildCourse()
        placeBall(at: hole.tee)
    }

    // MARK: - Course construction

    private func buildCourse() {
        // Rough base
        let roughRect = CGRect(x: 30, y: 30, width: size.width - 60, height: size.height - 60)
        let rough = SKShapeNode(rect: roughRect, cornerRadius: 60)
        rough.fillColor = SceneColors.rough
        rough.strokeColor = SceneColors.outline
        rough.lineWidth = 3.5
        rough.zPosition = 0
        addChild(rough)

        // Decorative trees along the margins
        for i in 0..<10 {
            let y = CGFloat(120 + i * 88)
            addTree(at: CGPoint(x: CGFloat.random(in: 44...62), y: y + .random(in: -20...20)))
            addTree(at: CGPoint(x: size.width - CGFloat.random(in: 44...62), y: y + .random(in: -25...25)))
        }

        // Fairway
        let fairway = SKShapeNode(path: hole.fairwayPath)
        fairway.fillColor = SceneColors.fairway
        fairway.strokeColor = SceneColors.outline
        fairway.lineWidth = 3.5
        fairway.zPosition = 1
        addChild(fairway)

        // Water
        for rect in hole.waterRects {
            let pond = SKShapeNode(ellipseIn: rect)
            pond.fillColor = SceneColors.water
            pond.strokeColor = SceneColors.outline
            pond.lineWidth = 3.5
            pond.zPosition = 2
            addChild(pond)
        }

        // Bunkers
        for b in hole.bunkers {
            let bunker = SKShapeNode(circleOfRadius: b.radius)
            bunker.position = b.center
            bunker.fillColor = SceneColors.sand
            bunker.strokeColor = SceneColors.outline
            bunker.lineWidth = 3.5
            bunker.zPosition = 2
            addChild(bunker)
        }

        // Fringe + green
        let fringe = SKShapeNode(circleOfRadius: hole.greenRadius + hole.fringeWidth)
        fringe.position = hole.pin
        fringe.fillColor = SceneColors.fringe
        fringe.strokeColor = SceneColors.outline
        fringe.lineWidth = 3.5
        fringe.zPosition = 2
        addChild(fringe)

        let green = SKShapeNode(circleOfRadius: hole.greenRadius)
        green.position = hole.pin
        green.fillColor = SceneColors.green
        green.strokeColor = SceneColors.outline
        green.lineWidth = 3
        green.zPosition = 2.5
        addChild(green)

        // Tee box
        let teeBox = SKShapeNode(rectOf: CGSize(width: 56, height: 26), cornerRadius: 8)
        teeBox.position = CGPoint(x: hole.tee.x, y: hole.tee.y - 4)
        teeBox.fillColor = SceneColors.fairway
        teeBox.strokeColor = SceneColors.outline
        teeBox.lineWidth = 3
        teeBox.zPosition = 2
        addChild(teeBox)

        // Cup + flag
        let cup = SKShapeNode(circleOfRadius: hole.cupRadius)
        cup.position = hole.pin
        cup.fillColor = SKColor(hex: 0x123018)
        cup.strokeColor = SceneColors.outline
        cup.lineWidth = 2
        cup.zPosition = 3
        addChild(cup)

        flagNode.position = hole.pin
        flagNode.zPosition = 4
        let pole = SKShapeNode(rect: CGRect(x: -1.5, y: 0, width: 3, height: 42))
        pole.fillColor = SceneColors.ball
        pole.strokeColor = SceneColors.outline
        pole.lineWidth = 1.5
        flagNode.addChild(pole)
        let flagPath = UIBezierPath()
        flagPath.move(to: CGPoint(x: 1.5, y: 42))
        flagPath.addLine(to: CGPoint(x: 26, y: 34))
        flagPath.addLine(to: CGPoint(x: 1.5, y: 26))
        flagPath.close()
        let flag = SKShapeNode(path: flagPath.cgPath)
        flag.fillColor = SceneColors.flagRed
        flag.strokeColor = SceneColors.outline
        flag.lineWidth = 2
        flagNode.addChild(flag)
        // A barely-there idle waggle so the course feels alive
        flag.run(.repeatForever(.sequence([
            .scaleX(to: 0.93, duration: 1.2),
            .scaleX(to: 1.0, duration: 1.2)
        ])))
        addChild(flagNode)

        // Ball + shadow
        ballShadow.fillColor = SKColor.black.withAlphaComponent(0.3)
        ballShadow.strokeColor = .clear
        ballShadow.zPosition = 9
        addChild(ballShadow)

        ballNode.fillColor = SceneColors.ball
        ballNode.strokeColor = SceneColors.outline
        ballNode.lineWidth = 2.5
        ballNode.zPosition = 10
        addChild(ballNode)

        previewNode.zPosition = 8
        addChild(previewNode)
    }

    private func addTree(at p: CGPoint) {
        let tree = SKShapeNode(circleOfRadius: CGFloat.random(in: 14...22))
        tree.position = p
        tree.fillColor = SceneColors.deepRough
        tree.strokeColor = SceneColors.outline
        tree.lineWidth = 3
        tree.zPosition = 3
        addChild(tree)
    }

    // MARK: - Ball placement & markers

    func placeBall(at p: CGPoint) {
        ballNode.removeAllActions()
        ballNode.position = p
        ballNode.setScale(1)
        ballNode.alpha = 1
        ballShadow.position = CGPoint(x: p.x, y: p.y - 4)
        ballShadow.alpha = 0.6
    }

    /// Ghost marker showing a teammate's ball during the pick phase.
    func addMarker(at p: CGPoint, teamColorHex: UInt32) {
        let marker = SKShapeNode(circleOfRadius: 7)
        marker.position = p
        marker.fillColor = SKColor(hex: teamColorHex).withAlphaComponent(0.85)
        marker.strokeColor = SceneColors.outline
        marker.lineWidth = 2
        marker.zPosition = 6
        addChild(marker)
        markers.append(marker)
    }

    func clearMarkers() {
        markers.forEach { $0.removeFromParent() }
        markers.removeAll()
    }

    // MARK: - Flight animation (driver / iron / chip)

    /// Animates the ball along a curved flight and reports the final resting
    /// point plus sampled flight path (for water-entry detection).
    func animateShot(from: CGPoint, aim: CGVector, carryYards: Double,
                     lateralYards: Double, flavor: ShotFlavor, apexScale: CGFloat,
                     completion: @escaping (CGPoint, [CGPoint]) -> Void) {
        placeBall(at: from)
        removePreview()

        let aimU = aim.normalized
        let perp = aimU.perpendicularRight
        let d = CGFloat(carryYards) * Hole.pointsPerYard
        let lat = CGFloat(lateralYards) * Hole.pointsPerYard

        var end = from + aimU * d + perp * lat
        end.x = min(max(end.x, 42), size.width - 42)
        end.y = min(max(end.y, 42), size.height - 42)
        let control = from + aimU * (d * 0.55)

        var samples: [CGPoint] = []
        for i in 0...30 {
            let t = CGFloat(i) / 30
            samples.append(quadPoint(t: t, p0: from, c: control, p1: end))
        }

        let grounded = flavor == .topped || flavor == .chunk || flavor == .fat

        if grounded {
            // Worm burner: fast, low, no arc, lots of shame.
            let skitter = SKAction.move(to: end, duration: 0.55)
            skitter.timingMode = .easeOut
            ballShadow.run(SKAction.move(to: end, duration: 0.55))
            ballNode.run(.sequence([skitter, squash()])) { [weak self] in
                self?.settle(at: end, samples: samples, roll: aimU * 8,
                             completion: completion)
            }
            return
        }

        let path = UIBezierPath()
        path.move(to: from)
        path.addQuadCurve(to: end, controlPoint: control)
        let duration = 0.8 + Double(d) / 900

        let timedFollow = SKAction.follow(path.cgPath, asOffset: false,
                                          orientToPath: false, duration: duration)
        let up = SKAction.scale(to: apexScale, duration: duration / 2)
        up.timingMode = .easeOut
        let down = SKAction.scale(to: 1.0, duration: duration / 2)
        down.timingMode = .easeIn

        // Shadow shrinks and fades while the ball is airborne
        ballShadow.run(.sequence([
            .fadeAlpha(to: 0.15, duration: duration * 0.3),
            .wait(forDuration: duration * 0.4),
            .fadeAlpha(to: 0.6, duration: duration * 0.3)
        ]))
        ballShadow.run(SKAction.move(to: end, duration: duration))

        ballNode.run(.group([timedFollow, .sequence([up, down])])) { [weak self] in
            guard let self else { return }
            self.landingPuff(at: end)
            self.ballNode.run(self.squash()) {
                self.settle(at: end, samples: samples, roll: aimU * (d * 0.05),
                            completion: completion)
            }
        }
    }

    /// Post-landing rollout, then hand the final position back.
    private func settle(at end: CGPoint, samples: [CGPoint], roll: CGVector,
                        completion: @escaping (CGPoint, [CGPoint]) -> Void) {
        var final = end + roll
        final.x = min(max(final.x, 42), size.width - 42)
        final.y = min(max(final.y, 42), size.height - 42)

        // Don't roll into the pond if the carry stayed dry.
        if hole.lie(at: end) != .water && hole.lie(at: final) == .water {
            final = end
        }

        let rollAction = SKAction.move(to: final, duration: 0.35)
        rollAction.timingMode = .easeOut
        ballShadow.run(SKAction.move(to: final, duration: 0.35))
        ballNode.run(rollAction) { [weak self] in
            guard let self else { return }
            if self.hole.lie(at: final) == .water {
                self.splash(at: final)
            }
            completion(final, samples)
        }
    }

    private func squash() -> SKAction {
        .sequence([
            .group([.scaleX(to: 1.12, duration: 0.07), .scaleY(to: 0.88, duration: 0.07)]),
            .group([.scaleX(to: 1.0, duration: 0.12), .scaleY(to: 1.0, duration: 0.12)])
        ])
    }

    private func quadPoint(t: CGFloat, p0: CGPoint, c: CGPoint, p1: CGPoint) -> CGPoint {
        let mt = 1 - t
        let x = mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x
        let y = mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Putting (physics-lite simulation in update loop)

    func startPutt(velocity: CGVector) {
        removePreview()
        puttVelocity = velocity
        puttActive = true
    }

    override func update(_ currentTime: TimeInterval) {
        defer { lastUpdateTime = currentTime }
        guard puttActive, lastUpdateTime > 0 else { return }
        let dt = CGFloat(min(currentTime - lastUpdateTime, 1.0 / 30.0))

        // Exponential friction + constant slope drift while on the green.
        let decay = exp(-1.9 * dt)
        puttVelocity = puttVelocity * decay
        if hole.lie(at: ballNode.position) == .green {
            puttVelocity = puttVelocity + hole.greenSlope * dt
        } else {
            // Fringe/rough kills pace fast
            puttVelocity = puttVelocity * exp(-2.6 * dt)
        }

        var pos = ballNode.position + puttVelocity * dt
        pos.x = min(max(pos.x, 42), size.width - 42)
        pos.y = min(max(pos.y, 42), size.height - 42)
        ballNode.position = pos
        ballShadow.position = CGPoint(x: pos.x, y: pos.y - 3)

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
                puttVelocity = (away * (speed * 0.45)) + (away.perpendicularRight * (speed * 0.25))
            }
        }

        if speed < 6 {
            puttActive = false
            puttVelocity = .zero
            onPuttEnded?(false, ballNode.position)
        }
    }

    private func sinkBall() {
        puttActive = false
        puttVelocity = .zero
        let drop = SKAction.group([
            .move(to: hole.pin, duration: 0.15),
            .scale(to: 0.2, duration: 0.15),
            .fadeOut(withDuration: 0.18)
        ])
        ballShadow.alpha = 0
        ballNode.run(drop) { [weak self] in
            guard let self else { return }
            self.onPuttEnded?(true, self.hole.pin)
        }
    }

    // MARK: - Aim preview (chip arc / putt line)

    func showPreview(from: CGPoint, direction: CGVector, power: Double, isPutt: Bool) {
        removePreview()
        let dir = direction.normalized
        let travel: CGFloat = isPutt
            ? CGFloat(power) * 480 / 1.9                       // v0 / k
            : CGFloat(power * Club.sandWedge.maxYards) * Hole.pointsPerYard

        let dotCount = max(Int(travel / 16), 2)
        for i in 1...dotCount {
            let t = CGFloat(i) / CGFloat(dotCount)
            let dot = SKShapeNode(circleOfRadius: isPutt ? 3 : 3.5 + t * 2)
            dot.position = from + dir * (travel * t)
            dot.fillColor = SceneColors.accent.withAlphaComponent(0.4 + 0.5 * (1 - t))
            dot.strokeColor = .clear
            previewNode.addChild(dot)
        }
        if !isPutt {
            let ring = SKShapeNode(circleOfRadius: 10)
            ring.position = from + dir * travel
            ring.strokeColor = SceneColors.accent
            ring.lineWidth = 2.5
            ring.fillColor = .clear
            previewNode.addChild(ring)
        }
    }

    func removePreview() {
        previewNode.removeAllChildren()
    }

    // MARK: - Reactions (kept understated — ripples and pulses, no confetti)

    func splash(at p: CGPoint) {
        ripple(at: p, color: SceneColors.ball, delay: 0)
        ripple(at: p, color: SceneColors.ball, delay: 0.18)
        ballNode.run(.fadeOut(withDuration: 0.25))
    }

    /// Holed putt: a couple of expanding rings from the cup and a small
    /// flag hop. Satisfying, not a fireworks show.
    func celebrate(at p: CGPoint) {
        ripple(at: p, color: SceneColors.accent, delay: 0)
        ripple(at: p, color: SceneColors.accent, delay: 0.15)
        flagNode.run(.sequence([
            .moveBy(x: 0, y: 10, duration: 0.12),
            .moveBy(x: 0, y: -10, duration: 0.18)
        ]))
    }

    private func ripple(at p: CGPoint, color: SKColor, delay: TimeInterval) {
        let ring = SKShapeNode(circleOfRadius: 7)
        ring.position = p
        ring.strokeColor = color.withAlphaComponent(0.7)
        ring.lineWidth = 2.5
        ring.fillColor = .clear
        ring.zPosition = 15
        ring.alpha = 0
        addChild(ring)
        ring.run(.sequence([
            .wait(forDuration: delay),
            .fadeIn(withDuration: 0.05),
            .group([.scale(to: 3.2, duration: 0.55), .fadeOut(withDuration: 0.55)]),
            .removeFromParent()
        ]))
    }

    private func landingPuff(at p: CGPoint) {
        let puff = SKShapeNode(circleOfRadius: 7)
        puff.position = p
        puff.fillColor = SKColor.white.withAlphaComponent(0.3)
        puff.strokeColor = .clear
        puff.zPosition = 8
        addChild(puff)
        puff.run(.sequence([
            .group([.scale(to: 1.8, duration: 0.3), .fadeOut(withDuration: 0.3)]),
            .removeFromParent()
        ]))
    }
}
