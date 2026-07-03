import SwiftUI
import SceneKit

struct GameView: View {
    let onExit: () -> Void

    @EnvironmentObject private var app: AppState
    @StateObject private var engine: MatchEngine
    @State private var scene: Course3DScene
    @State private var showShare = false
    @State private var pendingPuttStartFt = 0
    @State private var coinsApplied = false

    init(config: MatchConfig, onExit: @escaping () -> Void) {
        self.onExit = onExit
        _engine = StateObject(wrappedValue: MatchEngine(config: config))
        _scene = State(initialValue: Course3DScene(hole: config.hole))
    }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()

            SceneView(scene: scene.scene, pointOfView: scene.cameraNode, options: [])
                .ignoresSafeArea()

            VStack {
                hud
                Spacer()
                if engine.phase == .aiming { bottomBar }
            }

            // One-motion swing for every club (Golf Dreams style).
            // Full shots: drift = shot shape (hook/slice).
            // Chips/putts: drift = AIM, so you can play the break; the
            // putt preview bends with the green's slope as you pull.
            if engine.phase == .aiming {
                switch engine.currentKind {
                case .meter:
                    SwingGestureOverlay(
                        mode: .full,
                        label: { b in "\(Int(b * 100))" },
                        onPull: { b, _ in scene.setBackswing(CGFloat(b)) },
                        onSwing: { b, _, shapeDrift, upSpeed in
                            let flick = min(upSpeed / 3000, 1)
                            let power = min(b * (0.5 + 0.65 * flick), 1)
                            executeMeterShot(power: power, earlyLate: shapeDrift)
                        },
                        onCancel: { scene.setBackswing(nil) }
                    )
                case .chip, .putt:
                    let isPutt = engine.currentKind == .putt
                    SwingGestureOverlay(
                        mode: isPutt ? .putt : .chip,
                        label: { b in flickLabel(power: b) },
                        onPull: { b, aimDrift in
                            scene.setPullback(CGFloat(b))
                            let dir = aimedDirection(drift: aimDrift)
                            if isPutt {
                                scene.showPuttPreview(from: engine.currentSpot,
                                                      direction: dir, power: b)
                            } else {
                                scene.showPreview(from: engine.currentSpot,
                                                  direction: dir, power: b,
                                                  isPutt: false)
                            }
                        },
                        onSwing: { b, aimDrift, _, upSpeed in
                            let flick = min(upSpeed / 2600, 1)
                            let power = min(max(b * (0.55 + 0.9 * flick), 0.03), 1)
                            executeFlick(dir: aimedDirection(drift: aimDrift),
                                         power: power)
                        },
                        onCancel: {
                            scene.setPullback(nil)
                            scene.removePreview()
                        }
                    )
                }
            }

            if engine.phase == .shotResult, let outcome = engine.lastOutcome {
                ResultBanner(outcome: outcome,
                             onShare: { showShare = true },
                             onContinue: { engine.advanceAfterResult() })
            }

            if engine.phase == .pickBall {
                PickBallView(engine: engine)
            }

            if engine.phase == .holeComplete, let summary = engine.summary {
                HoleCompleteView(summary: summary,
                                 onShare: { showShare = true },
                                 onExit: onExit)
            }
        }
        .statusBarHidden()
        .onAppear(perform: wire)
        .onDisappear { scene.tearDown() }
        .onChange(of: engine.phase) { _, newPhase in handlePhaseChange(newPhase) }
        .sheet(isPresented: $showShare) {
            ShareSheet(text: shareText)
        }
    }

    private var isFlickShot: Bool {
        engine.currentKind == .chip || engine.currentKind == .putt
    }

    private var shareText: String {
        if engine.phase == .holeComplete { return engine.summary?.chatLine ?? "" }
        return engine.lastOutcome?.message ?? ""
    }

    // MARK: - HUD

    private var hud: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Hole \(engine.hole.number) • Par \(engine.hole.par) • \(engine.hole.yards) yds",
                      systemImage: "flag.fill")
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundStyle(Palette.cream)
                Spacer()
                windBadge
            }

            HStack {
                scoreChip(team: 0)
                Spacer()
                scoreChip(team: 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var windBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "location.north.fill")
                .font(.caption)
                .rotationEffect(.radians(.pi / 2 - engine.wind.angle))
            Text("\(engine.wind.speed) MPH")
                .font(.system(.footnote, design: .rounded).bold())
        }
        .foregroundStyle(engine.wind.speed > 8 ? Palette.danger : Palette.cream)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.card.opacity(0.9), in: Capsule())
    }

    private func scoreChip(team: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: engine.teams[team].colorHex))
                .frame(width: 10, height: 10)
            Text("\(engine.teams[team].name)  \(engine.strokes[team])")
                .font(.system(.footnote, design: .rounded).bold())
                .foregroundStyle(
                    engine.activeTeam == team ? Palette.accent : Palette.cream.opacity(0.7)
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Palette.card.opacity(0.9), in: Capsule())
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text("\(engine.currentPlayer.emoji) \(engine.currentPlayer.name)")
                .font(.system(.headline, design: .rounded).bold())
                .foregroundStyle(Palette.cream)
            Text(engine.currentLie.label.uppercased())
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(Palette.cream.opacity(0.65))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Palette.ink.opacity(0.6), in: Capsule())
            if case .meter(let club) = engine.currentKind {
                Text(club.rawValue.uppercased())
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Palette.accent.opacity(0.9), in: Capsule())
            }
            Spacer()
            Text(distanceLabel)
                .font(.system(.headline, design: .rounded).bold())
                .monospacedDigit()
                .foregroundStyle(Palette.accent)
        }
        .padding(16)
        .background(Palette.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var distanceLabel: String {
        engine.currentKind == .putt
            ? "\(engine.distanceToPinFeet) FT"
            : "\(Int(engine.distanceToPinYards)) YDS"
    }

    // MARK: - Wiring

    private func wire() {
        SoundFX.prepare()

        // "-demoPutt" drops the ball on the green — simulator checks only.
        // Also stages a mid-pull with the curved read line for screenshots.
        if CommandLine.arguments.contains("-demoPutt") {
            engine.teamSpot[0] = engine.hole.pin + CGVector(dx: -14, dy: -34)
            engine.teamLie[0] = .green
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                scene.setPullback(0.55)
                scene.showPuttPreview(from: engine.currentSpot,
                                      direction: aimedDirection(drift: -0.25),
                                      power: 0.17)
            }
        }
        // "-demoSwing" auto-plays a full swing for simulator checks:
        // staged pull-back, then a committed 88% swing, slight fade.
        if CommandLine.arguments.contains("-demoSwing") {
            for (t, b) in [(1.2, 0.3), (1.5, 0.6), (1.8, 0.9), (2.1, 1.0)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    scene.setBackswing(CGFloat(b))
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                executeMeterShot(power: 0.88, earlyLate: 0.04)
            }
        }
        scene.placeBall(at: engine.currentSpot, onTee: engine.currentLie == .tee)
        scene.aim(spot: engine.currentSpot, aimDir: engine.aimDirection,
                  kind: engine.currentKind, animated: false)

        scene.onPuttEnded = { holed, end in
            engine.resolvePutt(holed: holed, end: end)
            if holed {
                scene.celebrate(at: engine.hole.pin)
                SoundFX.play("pure_chime", volume: 0.5, after: 0.25)
            } else if pendingPuttStartFt <= 5 {
                Haptics.rumble()   // missing a gimme hurts in your hand, not on screen
            }
        }
    }

    private func handlePhaseChange(_ phase: GamePhase) {
        if phase == .holeComplete, let summary = engine.summary, !coinsApplied {
            coinsApplied = true
            app.apply(summary)
            return
        }
        guard phase == .aiming else { return }
        scene.removePreview()
        if engine.roundShots.isEmpty {
            scene.clearMarkers()
        } else if let first = engine.roundShots.last, !first.holed {
            // Teammate's ball stays visible while the second player hits.
            scene.addMarker(at: first.endPoint,
                            teamColorHex: engine.teams[first.teamIndex].colorHex)
        }
        scene.placeBall(at: engine.currentSpot, onTee: engine.currentLie == .tee)
        scene.aim(spot: engine.currentSpot, aimDir: engine.aimDirection,
                  kind: engine.currentKind, animated: true)
    }

    // MARK: - Gesture → world mapping

    /// Chip/putt aim: lateral drift steers the launch line left/right of
    /// the pin (up to ~31° at full drift) so you can play the break.
    private func aimedDirection(drift: Double) -> CGVector {
        let aimU = engine.aimDirection
        return (aimU + aimU.perpendicularRight * CGFloat(drift * 0.6)).normalized
    }

    private func flickLabel(power: Double) -> String {
        if engine.currentKind == .putt {
            // Projected roll: v0/k in points, 2 pts = 1 yd, 3 ft = 1 yd.
            let feet = Int(power * 480 / 1.9 / 2 * 3)
            return "\(feet) ft"
        }
        return "\(Int(power * Club.wedge.maxYards)) yds"
    }

    // MARK: - Shot execution

    private func executeMeterShot(power: Double, earlyLate: Double) {
        guard case .meter(let club) = engine.currentKind else { return }
        let raw = ShotEngine.meterShot(club: club, power: power,
                                       earlyLate: earlyLate,
                                       wind: engine.wind,
                                       aim: engine.aimDirection)
        let result = applyLie(raw)
        let spot = engine.currentSpot
        let aim = engine.aimDirection
        engine.beginShot()

        // Downswing plays out, then the ball launches at the moment of
        // contact — the shot was decided at the second tap, the animation
        // just delivers it.
        SoundFX.play("whoosh", volume: 0.65)
        scene.swingRelease {
            Haptics.accuracyLock()
            playHitSound(result: result, club: club)
            scene.animateShot(from: spot, aim: aim,
                              carryYards: result.carryYards,
                              lateralYards: result.lateralYards,
                              flavor: result.flavor,
                              apexScale: club.apexScale) { end, samples in
                engine.resolveLanding(kind: .meter(club), result: result,
                                      end: end, samples: samples)
            }
        }
    }

    private func executeFlick(dir: CGVector, power: Double) {
        scene.removePreview()
        switch engine.currentKind {
        case .chip:
            let (raw, angleError) = ShotEngine.chip(power: power)
            let result = applyLie(raw)
            let spot = engine.currentSpot
            engine.beginShot()
            scene.strokeRelease(power: power) {
                SoundFX.play(result.flavor == .chunk ? "mishit" : "hit_chip",
                             volume: 0.75)
                scene.animateShot(from: spot,
                                  aim: dir.rotated(by: angleError),
                                  carryYards: result.carryYards,
                                  lateralYards: 0,
                                  flavor: result.flavor,
                                  apexScale: Club.wedge.apexScale) { end, samples in
                    engine.resolveLanding(kind: .chip, result: result,
                                          end: end, samples: samples)
                }
            }
        case .putt:
            pendingPuttStartFt = engine.distanceToPinFeet
            engine.beginShot()
            Haptics.powerLock()
            scene.strokeRelease(power: power) {
                SoundFX.play("hit_putt", volume: 0.7)
                scene.startPutt(velocity: dir.normalized * CGFloat(power * 480))
            }
        case .meter:
            break
        }
    }

    private func playHitSound(result: ShotResult, club: Club) {
        switch result.flavor {
        case .topped, .fat, .chunk:
            SoundFX.play("mishit", volume: 0.85)
        default:
            SoundFX.play(club == .driver ? "hit_driver" : "hit_iron", volume: 0.9)
            if result.rating == .perfect {
                SoundFX.play("pure_chime", volume: 0.4, after: 0.12)
            }
        }
    }

    private func applyLie(_ raw: ShotResult) -> ShotResult {
        let factor = engine.currentLie.distanceFactor
        guard factor < 1 else { return raw }
        return ShotResult(club: raw.club, powerPct: raw.powerPct,
                          accuracyPct: raw.accuracyPct, rating: raw.rating,
                          flavor: raw.flavor,
                          carryYards: raw.carryYards * factor,
                          lateralYards: raw.lateralYards)
    }
}
