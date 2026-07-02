import SwiftUI
import SceneKit

struct GameView: View {
    let onExit: () -> Void

    @EnvironmentObject private var app: AppState
    @StateObject private var engine: MatchEngine
    @StateObject private var meter = SwingMeterModel()
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

            // Elastic pull-and-flick input for chips & putts
            if engine.phase == .aiming, isFlickShot {
                ElasticGestureOverlay(
                    isPutt: engine.currentKind == .putt,
                    label: { power in flickLabel(power: power) },
                    onDrag: { s, c in
                        scene.showPreview(from: engine.currentSpot,
                                          direction: worldDirection(start: s, current: c),
                                          power: ElasticGestureOverlay.power(s, c),
                                          isPutt: engine.currentKind == .putt)
                    },
                    onRelease: { s, c in
                        executeFlick(dir: worldDirection(start: s, current: c),
                                     power: ElasticGestureOverlay.power(s, c))
                    },
                    onCancel: { scene.removePreview() }
                )
            }

            // Swing meter for full shots
            if case .meter = engine.currentKind, engine.phase == .aiming {
                HStack {
                    Spacer()
                    SwingMeterView(model: meter)
                        .padding(.trailing, 14)
                }
                if meter.phase == .power || meter.phase == .accuracy {
                    TouchDownCatcher { meter.tap() }
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
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("\(engine.currentPlayer.emoji) \(engine.currentPlayer.name)")
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundStyle(Palette.cream)
                Text(engine.currentLie.emoji + " " + engine.currentLie.label)
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundStyle(Palette.cream.opacity(0.8))
                Spacer()
                Text(distanceLabel)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundStyle(Palette.accent)
            }

            if case .meter(let club) = engine.currentKind, meter.phase == .idle {
                Button {
                    meter.start()
                } label: {
                    Text("\(club.emoji) SWING \(club.rawValue.uppercased())")
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .padding(14)
        .background(Palette.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
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
        // "-demoPutt" drops the ball on the green — simulator checks only.
        if CommandLine.arguments.contains("-demoPutt") {
            engine.teamSpot[0] = engine.hole.pin + CGVector(dx: -14, dy: -34)
            engine.teamLie[0] = .green
        }
        scene.placeBall(at: engine.currentSpot, onTee: engine.currentLie == .tee)
        scene.aim(spot: engine.currentSpot, aimDir: engine.aimDirection,
                  kind: engine.currentKind, animated: false)

        meter.onCommit = { power, earlyLate in
            executeMeterShot(power: power, earlyLate: earlyLate)
        }

        scene.onPuttEnded = { holed, end in
            engine.resolvePutt(holed: holed, end: end)
            if holed {
                scene.celebrate(at: engine.hole.pin)
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
        meter.reset()
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

    /// Convert a screen-space pull into a 2D hole-coords direction relative
    /// to the chase camera: screen-up fires along the aim line, screen-right
    /// fires to the aim line's right. The shot goes opposite the pull.
    private func worldDirection(start: CGPoint, current: CGPoint) -> CGVector {
        let forwardAmount = current.y - start.y      // pull down = fire forward
        let rightAmount = start.x - current.x        // pull left = fire right
        let aimU = engine.aimDirection
        return (aimU * forwardAmount
                + aimU.perpendicularRight * rightAmount).normalized
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
        scene.animateShot(from: spot, aim: aim,
                          carryYards: result.carryYards,
                          lateralYards: result.lateralYards,
                          flavor: result.flavor,
                          apexScale: club.apexScale) { end, samples in
            engine.resolveLanding(kind: .meter(club), result: result,
                                  end: end, samples: samples)
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
            scene.animateShot(from: spot,
                              aim: dir.rotated(by: angleError),
                              carryYards: result.carryYards,
                              lateralYards: 0,
                              flavor: result.flavor,
                              apexScale: Club.wedge.apexScale) { end, samples in
                engine.resolveLanding(kind: .chip, result: result,
                                      end: end, samples: samples)
            }
        case .putt:
            pendingPuttStartFt = engine.distanceToPinFeet
            engine.beginShot()
            Haptics.powerLock()
            scene.startPutt(velocity: dir.normalized * CGFloat(power * 480))
        case .meter:
            break
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

/// Fires on touch-down (not touch-up) so meter taps feel instant.
struct TouchDownCatcher: View {
    let action: () -> Void
    @State private var isDown = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDown {
                            isDown = true
                            action()
                        }
                    }
                    .onEnded { _ in isDown = false }
            )
    }
}
