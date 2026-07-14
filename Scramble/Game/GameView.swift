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
    @State private var showBag = false
    @State private var aimOffset = 0.0
    @State private var aimDragStart: Double?

    /// Live aim line: the pin line rotated by the player's aim adjustment.
    private var aimU: CGVector {
        engine.aimDirection.rotated(by: CGFloat(aimOffset))
    }

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
                        onSwing: { b, aimDrift, shapeDrift, upSpeed in
                            // Golf Dreams power model (dev-confirmed):
                            // backswing length is the power and it's
                            // EXPONENTIAL — margins are small. Swipe speed
                            // is only a ±4% tempo nudge.
                            let tempo = 0.96 + 0.08 * min(upSpeed / 2600, 1)
                            let power = min(exp(2.3 * (b - 1)) * tempo, 1.04)
                            // Face control from BOTH phases, like Golf
                            // Dreams: drift going back counts at 40%,
                            // drift through impact at full weight.
                            let backDrift = aimDrift - shapeDrift
                            let earlyLate = min(max(shapeDrift + 0.4 * backDrift,
                                                    -1), 1)
                            executeMeterShot(power: power, earlyLate: earlyLate)
                        },
                        onCancel: { scene.setBackswing(nil) }
                    )
                case .chip, .putt:
                    let isPutt = engine.currentKind == .putt
                    SwingGestureOverlay(
                        mode: isPutt ? .putt : .chip,
                        label: { b in
                            flickLabel(power: isPutt ? puttPower(b)
                                                     : chipPower(b, upSpeed: nil))
                        },
                        onPull: { b, aimDrift in
                            // Golf Dreams 1:1 takeaway: chips mirror the
                            // finger with a real half-backswing; putts use
                            // the pendulum stroke.
                            if isPutt {
                                scene.setPullback(CGFloat(b))
                            } else {
                                scene.setBackswing(CGFloat(b) * 0.55)
                            }
                            let dir = aimedDirection(drift: aimDrift)
                            if isPutt {
                                scene.showPuttPreview(from: engine.currentSpot,
                                                      direction: dir,
                                                      power: puttPower(b))
                            } else {
                                scene.showPreview(from: engine.currentSpot,
                                                  direction: dir,
                                                  power: chipPower(b, upSpeed: nil),
                                                  isPutt: false)
                            }
                        },
                        onSwing: { b, aimDrift, _, upSpeed in
                            // Putting is pure pendulum: stroke length IS
                            // the pace, no flick multiplier — so the read
                            // line is the literal truth and short putts
                            // are finesse, not reflexes. Chips use the
                            // same exponential model as full swings.
                            let power = isPutt
                                ? max(puttPower(b), 0.015)
                                : chipPower(b, upSpeed: upSpeed)
                            executeFlick(dir: aimedDirection(drift: aimDrift),
                                         power: power)
                        },
                        onCancel: {
                            scene.setPullback(nil)
                            scene.setBackswing(nil)
                            scene.removePreview()
                        }
                    )
                }
            }

            // Aim strip — drag horizontally across the top of the screen to
            // rotate the aim line (Golf Dreams: pick your line against the
            // wind). Sits above the swing overlay so it wins up here.
            if engine.phase == .aiming {
                VStack(spacing: 4) {
                    Text("‹ drag to aim ›")
                        .font(.system(.caption2, design: .rounded).bold())
                        .foregroundStyle(Palette.cream.opacity(0.45))
                        .padding(.top, 96)
                    Color.clear
                        .frame(height: 150)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { g in
                                    if aimDragStart == nil { aimDragStart = aimOffset }
                                    aimOffset = min(max((aimDragStart ?? 0)
                                        - Double(g.translation.width) * 0.0011,
                                        -0.55), 0.55)
                                    scene.aim(spot: engine.currentSpot, aimDir: aimU,
                                              kind: engine.currentKind, animated: false)
                                    if engine.currentKind == .putt {
                                        scene.showPuttPreview(from: engine.currentSpot,
                                                              direction: aimU,
                                                              power: puttPower(0.5))
                                    } else {
                                        scene.showPreview(from: engine.currentSpot,
                                                          direction: aimU, power: 0.55,
                                                          isPutt: false)
                                    }
                                }
                                .onEnded { _ in
                                    aimDragStart = nil
                                    scene.removePreview()
                                }
                        )
                    Spacer()
                }
                .ignoresSafeArea()
            }

            // HUD + bottom bar sit ABOVE the swing overlay so the bag
            // button and chips stay tappable (the overlay eats everything
            // underneath it).
            VStack {
                hud
                Spacer()
                if engine.phase == .aiming { bottomBar }
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
            if showBag { bagRow }

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

                // The bag — tap to choose a club, Golf Dreams style.
                // Carry yardage is how you judge distance; no meter.
                Button {
                    withAnimation(.spring(duration: 0.25)) { showBag.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(clubChipLabel)
                            .font(.system(.caption, design: .rounded).bold())
                        Image(systemName: showBag ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .heavy))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Palette.accent.opacity(0.92), in: Capsule())
                }

                Spacer()
                Text(distanceLabel)
                    .font(.system(.headline, design: .rounded).bold())
                    .monospacedDigit()
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding(16)
        .background(Palette.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var clubChipLabel: String {
        let club = engine.currentClub
        if club == .putter { return "PUTTER" }
        return "\(club.shortLabel) · \(Int(club.maxYards)) YD"
    }

    private var bagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableClubs, id: \.self) { club in
                    Button {
                        engine.clubOverride = club
                        withAnimation(.spring(duration: 0.25)) { showBag = false }
                        scene.aim(spot: engine.currentSpot, aimDir: aimU,
                                  kind: engine.currentKind, animated: true)
                    } label: {
                        VStack(spacing: 1) {
                            Text(club.shortLabel)
                                .font(.system(.callout, design: .rounded).weight(.heavy))
                            Text(club == .putter ? "green" : "\(Int(club.maxYards)) yd")
                                .font(.system(.caption2, design: .rounded).bold())
                                .opacity(0.75)
                        }
                        .foregroundStyle(engine.currentClub == club
                                         ? Palette.ink : Palette.cream)
                        .frame(width: 62)
                        .padding(.vertical, 7)
                        .background(engine.currentClub == club
                                    ? Palette.accent
                                    : Palette.ink.opacity(0.55),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private var availableClubs: [Club] {
        engine.putterAllowed && engine.currentLie != .green
            ? Club.bag + [.putter]
            : Club.bag
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
        scene.aim(spot: engine.currentSpot, aimDir: aimU,
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
        aimOffset = 0
        showBag = false
        scene.removePreview()
        if engine.roundShots.isEmpty {
            scene.clearMarkers()
        } else if let first = engine.roundShots.last, !first.holed {
            // Teammate's ball stays visible while the second player hits.
            scene.addMarker(at: first.endPoint,
                            teamColorHex: engine.teams[first.teamIndex].colorHex)
        }
        scene.placeBall(at: engine.currentSpot, onTee: engine.currentLie == .tee)
        scene.aim(spot: engine.currentSpot, aimDir: aimU,
                  kind: engine.currentKind, animated: true)
    }

    // MARK: - Gesture → world mapping

    /// Chip/putt aim: lateral drift steers the launch line left/right of
    /// the current aim line (up to ~31° at full drift) to play the break.
    private func aimedDirection(drift: Double) -> CGVector {
        (aimU + aimU.perpendicularRight * CGFloat(drift * 0.6)).normalized
    }

    /// Pendulum putt pace: gentle curve for feel at short range, full
    /// pull rolls out the putter's 40-yd max. The same number drives the
    /// stroke, the read line, and the pill — they can never disagree.
    private func puttPower(_ b: Double) -> Double {
        pow(b, 1.6) * 0.317
    }

    /// Chips are little swings: same exponential backswing model as full
    /// shots, with the same tiny tempo nudge when there's a real rip.
    private func chipPower(_ b: Double, upSpeed: Double?) -> Double {
        let tempo = upSpeed.map { 0.96 + 0.08 * min($0 / 2600, 1) } ?? 1.0
        return min(exp(2.0 * (b - 1)) * tempo, 1.0)
    }

    private func flickLabel(power: Double) -> String {
        if engine.currentKind == .putt {
            // Projected roll: v0/k in points, 2 pts = 1 yd, 3 ft = 1 yd.
            let feet = Int(power * 480 / 1.9 / 2 * 3)
            return "\(feet) ft"
        }
        return "\(Int(power * Club.sandWedge.maxYards)) yds"
    }

    // MARK: - Shot execution

    private func executeMeterShot(power: Double, earlyLate: Double) {
        guard case .meter(let club) = engine.currentKind else { return }
        let raw = ShotEngine.meterShot(club: club, power: power,
                                       earlyLate: earlyLate,
                                       wind: engine.wind,
                                       aim: aimU)
        let result = applyLie(raw)
        let spot = engine.currentSpot
        let aim = aimU
        engine.beginShot()

        // The swing quality drives the animation: pure = tall balanced
        // finish, mishit = truncated finish + a lurch toward the miss.
        // You should read the strike from the body before the ball lands.
        let quality: Course3DScene.SwingQuality
        switch result.flavor {
        case .pure:
            quality = .pure
        case .topped, .fat, .chunk, .bigHook, .bigSlice:
            quality = .mishit(lateral: earlyLate >= 0 ? 1 : -1)
        default:
            quality = abs(earlyLate) > 0.33
                ? .mishit(lateral: earlyLate > 0 ? 1 : -1)
                : .clean
        }

        SoundFX.play("whoosh", volume: 0.5 + Float(power) * 0.3)
        scene.swingRelease(power: power, quality: quality) {
            if case .mishit = quality {
                Haptics.rumble()
            } else {
                Haptics.accuracyLock()
            }
            playHitSound(result: result, club: club)
            scene.animateShot(from: spot, aim: aim,
                              carryYards: result.carryYards,
                              lateralYards: result.lateralYards,
                              flavor: result.flavor,
                              apexScale: club.apexScale,
                              rollFactor: CGFloat(club.rollFactor),
                              tracerHex: result.rating == .perfect
                                  ? 0xFFD98A : 0xF5EFDA) { end, samples in
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
                // Chips release and run out — a bump-and-run rolls a
                // healthy fraction of its carry on the green.
                scene.animateShot(from: spot,
                                  aim: dir.rotated(by: angleError),
                                  carryYards: result.carryYards,
                                  lateralYards: 0,
                                  flavor: result.flavor,
                                  apexScale: Club.sandWedge.apexScale,
                                  rollFactor: 0.22) { end, samples in
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
