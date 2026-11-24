import SwiftUI
import SceneKit

struct GameView: View {
    let onExit: () -> Void

    @EnvironmentObject private var app: AppState
    @StateObject private var engine: MatchEngine
    @State private var scene: Course3DScene?
    @State private var showShare = false
    @State private var showBag = false
    @State private var aimOffset = 0.0
    @State private var aimDragStart: Double?
    @State private var escrowed = false
    @State private var settled = false
    @State private var confirmQuit = false
    @State private var turnBanner: String?
    @State private var shape: ShotShape = .straight
    @State private var readView = false
    /// Partner's putt this round, left on the green as the read.
    @State private var partnerRead: (path: [CGPoint], color: UInt32, name: String)?
    /// Full-stroke distance for this putt (pts) — scales with the putt so
    /// short ones get fine control.
    @State private var viewPitch: CGFloat = 0
    @State private var pitchDragStart: CGFloat?

    enum ShotShape: String, CaseIterable { case draw = "Draw", straight = "Straight", fade = "Fade" }

    private let demoMode: Bool

    /// Live aim line: the caddie line rotated by the player's adjustment.
    private var aimU: CGVector {
        engine.aimDirection.rotated(by: CGFloat(aimOffset))
    }

    init(config: MatchConfig, demo: Bool = false, onExit: @escaping () -> Void) {
        self.onExit = onExit
        self.demoMode = demo
        let engine = MatchEngine(config: config)
        _engine = StateObject(wrappedValue: engine)
    }

    var body: some View {
        ZStack {
            Color(hex: 0x8EC3EC).ignoresSafeArea()

            if let scene {
                SceneView(scene: scene.scene, pointOfView: scene.cameraNode,
                          options: [], preferredFramesPerSecond: 60,
                          antialiasingMode: .multisampling4X)
                    .id(engine.holeIndex)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                loadingCard
            }

            if engine.phase == .aiming && scene != nil { swingOverlay }
            if engine.phase == .aiming && scene != nil { aimStrip }

            VStack(spacing: 0) {
                hud
                Spacer()
                if engine.phase == .aiming { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
            .animation(.easeOut(duration: 0.25), value: engine.phase)

            if let banner = turnBanner {
                Text(banner)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if engine.phase == .holeIntro && scene != nil { holeIntroCard }

            if engine.phase == .shotResult, let outcome = engine.lastOutcome {
                ResultBanner(outcome: outcome,
                             onShare: { showShare = true },
                             onContinue: { engine.advanceAfterResult() })
            }

            if engine.phase == .pickBall {
                PickBallView(engine: engine)
            }

            if engine.phase == .holeComplete {
                ScorecardView(engine: engine, final: false, onShare: nil,
                              onContinue: { engine.startNextHole() })
            }

            if engine.phase == .matchComplete, let summary = engine.summary {
                MatchCompleteView(engine: engine, summary: summary,
                                  onShare: { showShare = true }, onExit: onExit)
            }
        }
        .statusBarHidden()
        .onAppear(perform: wire)
        .onDisappear { scene?.tearDown() }
        .onChange(of: engine.phase) { _, newPhase in handlePhaseChange(newPhase) }
        .onChange(of: engine.holeIndex) { _, _ in loadHoleScene() }
        .sheet(isPresented: $showShare) { ShareSheet(text: shareText) }
        .confirmationDialog("Leave the match?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Forfeit \(engine.wager) coins and leave", role: .destructive, action: onExit)
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("Your wager stays in the pot if you walk off.")
        }
    }

    private var shareText: String {
        if engine.phase == .matchComplete { return engine.summary?.chatLine ?? "" }
        return engine.lastOutcome?.message ?? ""
    }

    // MARK: - Swing input

    @ViewBuilder private var swingOverlay: some View {
        let kind = engine.currentKind
        switch kind {
        case .meter(let club):
            SwingGestureOverlay(
                mode: .full,
                onPull: { b, _ in
                    resetLook()
                    scene?.setBackswing(CGFloat(b), kind: kind)
                },
                onSwing: { b, aimDrift, shapeDrift, upSpeed in
                    // Golf Dreams model: backswing length is the power and
                    // it's exponential; swing speed is a ±4% tempo nudge.
                    let tempo = 0.96 + 0.08 * min(upSpeed / 2400, 1)
                    let power = min(exp(2.3 * (b - 1)) * tempo, 1.04)
                    // Face from both phases: back drift at 40%, through
                    // drift at full weight.
                    let backDrift = aimDrift - shapeDrift
                    let earlyLate = min(max(shapeDrift + 0.4 * backDrift, -1), 1)
                    executeFullSwing(club: club, power: power, earlyLate: earlyLate)
                },
                onCancel: {
                    scene?.setBackswing(nil, kind: kind)
                    showDefaultAim()
                }
            )
        case .chip, .putt:
            let isPutt = kind == .putt
            SwingGestureOverlay(
                mode: isPutt ? .putt : .chip,
                onPull: { b, _ in
                    resetLook()
                    scene?.setBackswing(CGFloat(b), kind: kind)
                },
                onSwing: { b, aimDrift, _, _ in
                    let dir = aimedDirection(drift: aimDrift)
                    if isPutt {
                        executePutt(dir: dir, distance: puttDistance(b), pull: b)
                    } else {
                        executeChip(dir: dir, carry: chipCarry(b), pull: b)
                    }
                },
                onCancel: {
                    scene?.setBackswing(nil, kind: kind)
                    showDefaultAim()
                }
            )
        }
    }

    /// Free look: drag across the top half of the screen to swing the
    /// camera (and your aim) all the way around the ball; drag down to lift
    /// the camera and look down range, up to come back to the ball.
    private var aimStrip: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    Text("drag to look & aim")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.bottom, 6)
                }
                .frame(height: geo.size.height * 0.46)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { g in
                            if aimDragStart == nil { aimDragStart = aimOffset; pitchDragStart = viewPitch }
                            let sens: Double
                            switch engine.currentKind {
                            case .putt: sens = 0.0016
                            case .chip: sens = 0.0026
                            case .meter: sens = 0.0038
                            }
                            aimOffset = (aimDragStart ?? 0) - Double(g.translation.width) * sens
                            viewPitch = min(max((pitchDragStart ?? 0) + g.translation.height / 260, 0), 1)
                            scene?.aim(spot: engine.currentSpot, aimDir: aimU,
                                       kind: engine.currentKind, animated: true, pitch: viewPitch)
                            showDefaultAim()
                        }
                        .onEnded { _ in aimDragStart = nil; pitchDragStart = nil }
                )
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    /// Starting a swing brings the camera back down behind the ball.
    private func resetLook() {
        guard viewPitch > 0 else { return }
        viewPitch = 0
        scene?.aim(spot: engine.currentSpot, aimDir: aimU, kind: engine.currentKind, animated: true)
    }

    // MARK: - Power models

    /// Still-air carry for a full swing at this backswing (what the pill
    /// and landing ring show).
    private func fullCarry(club: Club, pull: Double) -> Double {
        club.maxYards * exp(2.3 * (pull - 1)) * engine.currentLie.distanceFactor
    }

    private func chipCarry(_ pull: Double) -> Double {
        let carry = 62 * pow(pull, 1.5) * engine.currentLie.distanceFactor
        return max(carry, 1)
    }

    /// Flat-green roll distance (pts) for a putting stroke. Golf Dreams
    /// style: the same stroke always rolls the same distance, so you build
    /// real feel. Quadratic, so short putts get most of the thumb travel
    /// (a quarter stroke ≈ 13 ft, half ≈ 52 ft, full ≈ 210 ft).
    static let maxPutt: CGFloat = 140
    private func puttDistance(_ pull: Double) -> CGFloat {
        0.4 + GameView.maxPutt * CGFloat(pull * pull)
    }

    private func puttPull(forDistance d: CGFloat) -> Double {
        (Double(max(d - 0.4, 0.01) / GameView.maxPutt)).squareRoot()
    }

    /// Sideways thumb drift nudges the line: barely on putts (aim with the
    /// top-of-screen drag instead), a little on chips.
    private func aimedDirection(drift: Double) -> CGVector {
        let k: Double = engine.currentKind == .putt ? 0.05 : 0.2
        return aimU.rotated(by: CGFloat(-drift * k))
    }

    /// Intentional curve for draw/fade, in yards (+ = right).
    private func shapeCurve(_ club: Club) -> Double {
        let amount = max(4, club.curveYards * 0.32)
        switch shape {
        case .draw: return -amount
        case .straight: return 0
        case .fade: return amount
        }
    }

    /// Start line for a shaped shot: aim away from the curve so it bends
    /// back onto the target line.
    private func startLine(club: Club, carry: Double) -> CGVector {
        aimU.rotated(by: CGFloat(shapeCurve(club) / max(carry, 1)))
    }

    private func previewFull(club: Club, carry: Double) {
        guard shape != .straight else {
            scene?.showAim(from: engine.currentSpot, direction: aimU, carryYards: carry)
            return
        }
        let tr = BallPhysics.strike(from: engine.currentSpot, aim: startLine(club: club, carry: carry),
                                    club: club, carryYards: carry, lateralYards: shapeCurve(club),
                                    grounded: false, wind: Wind(speed: 0, angle: 0),
                                    course: engine.hole.course)
        scene?.showFlightPreview(tr, from: engine.currentSpot, ring: false)
    }

    // MARK: - Green reading

    /// Plain-English read of the putt: uphill/downhill and which way it
    /// breaks, from the slope along the line to the hole.
    private var puttRead: String {
        let spot = engine.currentSpot, pin = engine.hole.pin
        let dir = CGVector(from: spot, to: pin).normalized
        var avg = CGVector.zero
        for i in 0..<10 {
            let t = (CGFloat(i) + 0.5) / 10
            avg = avg + engine.hole.slope(at: CGPoint(x: spot.x + (pin.x - spot.x) * t,
                                                      y: spot.y + (pin.y - spot.y) * t)) * 0.1
        }
        let along = avg.dot(dir), side = avg.dot(dir.perpendicularRight)
        let hill: String
        switch along {
        case ..<(-2.4): hill = "Uphill"
        case ..<(-0.8): hill = "Slightly uphill"
        case ..<0.8: hill = "Flat"
        case ..<2.4: hill = "Slightly downhill"
        default: hill = "Downhill"
        }
        let breakText: String
        switch abs(side) {
        case ..<1.0: breakText = "straight"
        case ..<3.2: breakText = side > 0 ? "a little right" : "a little left"
        default: breakText = side > 0 ? "big break right" : "big break left"
        }
        return "\(hill) · \(breakText)"
    }

    /// What's riding on this putt, when it matters.
    private var stakesText: String? {
        guard engine.currentKind == .putt else { return nil }
        let t = engine.activeTeam, o = 1 - t
        guard engine.holedOut[o] else { return nil }
        if engine.isLastHole {
            let mine = engine.total(team: t) + 1, theirs = engine.total(team: o)
            if mine < theirs { return "MAKE IT TO WIN THE MATCH" }
            if mine == theirs { return "MAKE IT TO TIE THE MATCH" }
        }
        let mine = engine.strokes[t] + 1, theirs = engine.strokes[o]
        if mine < theirs { return "MAKE IT TO WIN THE HOLE" }
        if mine == theirs { return "MAKE IT TO HALVE THE HOLE" }
        return nil
    }

    // MARK: - HUD

    private var hud: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                Button { confirmQuit = true } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.28), in: Circle())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("HOLE \(engine.hole.number) · PAR \(engine.hole.par)")
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                    Text("\(engine.hole.name) · \(engine.hole.yards) yd")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                Spacer()
                windBadge
            }
            HStack(spacing: 8) {
                scoreChip(team: 0)
                scoreChip(team: 1)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var windBadge: some View {
        // Arrow relative to where you're aiming: up = helping, down = into you.
        let aimAngle = atan2(Double(aimU.dy), Double(aimU.dx))
        let rel = engine.wind.angle - aimAngle
        return VStack(spacing: 2) {
            Image(systemName: "location.north.fill")
                .font(.system(size: 18, weight: .bold))
                .rotationEffect(.radians(-rel))
                .opacity(engine.wind.speed == 0 ? 0.3 : 1)
            Text("\(engine.wind.speed) mph")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .monospacedDigit()
        }
        .foregroundStyle(engine.wind.speed >= 10 ? Color(hex: 0xFFD27A) : .white)
        .frame(width: 62, height: 54)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
    }

    private func scoreChip(team: Int) -> some View {
        let total = engine.total(team: team)
        let par = engine.parThrough(holes: engine.holeIndex)
            + (engine.holedOut[team] ? engine.hole.par : 0)
        let rel = total - par
        let relText = engine.holeIndex == 0 && !engine.holedOut[team]
            ? "E" : (rel == 0 ? "E" : (rel > 0 ? "+\(rel)" : "\(rel)"))
        return HStack(spacing: 6) {
            Circle().fill(Color(hex: engine.teams[team].colorHex)).frame(width: 9, height: 9)
            Text(engine.teams[team].name)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .lineLimit(1)
            Text("\(engine.strokes[team])")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.white.opacity(0.2), in: Capsule())
            Text(relText)
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(engine.activeTeam == team ? 0.42 : 0.22), in: Capsule())
        .overlay(Capsule().stroke(engine.activeTeam == team ? .white.opacity(0.7) : .clear, lineWidth: 1.5))
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let stakes = stakesText {
                Text(stakes)
                    .font(.system(.subheadline, design: .rounded).weight(.black))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Palette.gold, in: Capsule())
            }
            if showBag { bagRow }
            if case .meter = engine.currentKind { shapeRow }
            if engine.currentKind == .putt { puttRow }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.currentPlayer.name)
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                    Text(engine.currentLie.label.uppercased())
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(.spring(duration: 0.25)) { showBag.toggle() }
                } label: {
                    VStack(spacing: 0) {
                        Text(engine.currentClub.shortLabel)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                        Text(engine.currentClub == .putter ? "PUTTER" : "\(Int(engine.currentClub.maxYards)) YD")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .opacity(0.75)
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(width: 74, height: 56)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                }

                VStack(alignment: .trailing, spacing: 2) {
                    Text(distanceLabel)
                        .font(.system(.title3, design: .rounded).weight(.heavy))
                        .monospacedDigit()
                    Text("TO PIN")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var shapeRow: some View {
        HStack(spacing: 6) {
            ForEach(ShotShape.allCases, id: \.self) { option in
                Button {
                    shape = option
                    showDefaultAim()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: option == .draw ? "arrow.turn.up.left"
                              : option == .fade ? "arrow.turn.up.right" : "arrow.up")
                            .font(.system(size: 11, weight: .heavy))
                        Text(option.rawValue)
                            .font(.system(.caption, design: .rounded).weight(.heavy))
                    }
                    .foregroundStyle(shape == option ? Palette.ink : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(shape == option ? .white : .white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var puttRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill").font(.caption).foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(partnerRead == nil ? "Read the green" : "Use your partner's read")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .foregroundStyle(.white)
                if let read = partnerRead {
                    Text("\(read.name)'s line is on the green")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color(hex: read.color))
                }
            }
            Spacer()
            Button {
                readView.toggle()
                scene?.setReadView(readView, spot: engine.currentSpot)
            } label: {
                Text(readView ? "BACK" : "READ")
                    .font(.system(.caption, design: .rounded).weight(.black))
                    .foregroundStyle(readView ? Palette.ink : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(readView ? .white : .white.opacity(0.16), in: Capsule())
            }
        }
    }

    private var bagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableClubs, id: \.self) { club in
                    Button {
                        engine.clubOverride = club
                        withAnimation(.spring(duration: 0.25)) { showBag = false }
                        aimOffset = 0
                        scene?.aim(spot: engine.currentSpot, aimDir: aimU,
                                  kind: engine.currentKind, animated: true)
                        showDefaultAim()
                    } label: {
                        VStack(spacing: 1) {
                            Text(club.shortLabel)
                                .font(.system(.callout, design: .rounded).weight(.heavy))
                            Text(club == .putter ? "putt" : "\(Int(club.maxYards))")
                                .font(.system(.caption2, design: .rounded).bold())
                                .opacity(0.75)
                        }
                        .foregroundStyle(engine.currentClub == club ? Palette.ink : .white)
                        .frame(width: 52)
                        .padding(.vertical, 7)
                        .background(engine.currentClub == club ? .white : .white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private var availableClubs: [Club] {
        engine.putterAllowed && engine.currentLie != .green ? Club.bag + [.putter] : Club.bag
    }

    private var distanceLabel: String {
        engine.currentKind == .putt
            ? "\(engine.distanceToPinFeet) ft"
            : "\(Int(engine.distanceToPinYards)) yd"
    }

    private var holeIntroCard: some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                Text("HOLE \(engine.hole.number)")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .tracking(2)
                    .opacity(0.8)
                Text(engine.hole.name)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                Text("PAR \(engine.hole.par) · \(engine.hole.yards) YARDS")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .opacity(0.9)
                Text("\(engine.currentTeam.name) tee off")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .opacity(0.75)
                    .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 18)
            .padding(.horizontal, 28)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24))
            .padding(.bottom, 70)
            Text("tap to skip")
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { scene?.skipIntro() }
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("Walking to hole \(engine.hole.number)…")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(hex: 0x1C5A3B), Palette.deep],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// Build the hole off the main thread, then hand it to SwiftUI.
    private func buildScene(then ready: @escaping () -> Void) {
        let hole = engine.hole
        let character = engine.currentPlayer.character
        DispatchQueue.global(qos: .userInitiated).async {
            let built = Course3DScene(hole: hole, character: character)
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) { scene = built }
                built.start()
                ready()
            }
        }
    }

    // MARK: - Wiring

    private func wire() {
        if CommandLine.arguments.contains("-fast") { Course3DScene.timeScale = 3 }
        SoundFX.prepare()
        Haptics.prepare()
        if !escrowed && !demoMode {
            escrowed = true
            app.coins = max(0, app.coins - engine.wager)
        }
        buildScene { afterLoad() }
    }

    private func afterLoad() {
        let args = CommandLine.arguments
        if args.contains("-demoPutt") {
            engine.teamSpot[0] = engine.hole.pin + CGVector(dx: -10, dy: -30)
            engine.teamLie[0] = .green
        }
        if args.contains("-autoplay") { autoplay(.holeIntro) }
        if args.contains("-skipIntro") {
            prepareTurn(animated: false)
            engine.beginHole()
        } else {
            startHoleIntro()
        }
        if args.contains("-demoLook") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                aimOffset = 0.5
                viewPitch = 1
                scene?.aim(spot: engine.currentSpot, aimDir: aimU, kind: engine.currentKind,
                           animated: true, pitch: 1)
                showDefaultAim()
            }
        }
        if args.contains("-demoRead") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                readView = true
                scene?.setReadView(true, spot: engine.currentSpot)
            }
        }
        if args.contains("-demoSwing") {
            let kind = engine.currentKind
            for (t, b) in [(1.0, 0.3), (1.3, 0.6), (1.6, 0.85), (1.9, 0.95)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    scene?.setBackswing(CGFloat(b), kind: kind)
                    if case .meter(let club) = kind {
                        scene?.showAim(from: engine.currentSpot, direction: aimU,
                                      carryYards: fullCarry(club: club, pull: b))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                if case .meter(let club) = engine.currentKind {
                    executeFullSwing(club: club, power: 0.9, earlyLate: 0.05)
                } else if engine.currentKind == .putt {
                    executePutt(dir: aimU, distance: puttDistance(0.5), pull: 0.5)
                }
            }
        }
    }

    private func loadHoleScene() {
        scene?.tearDown()
        scene = nil
        aimOffset = 0
        buildScene { startHoleIntro() }
    }

    private func startHoleIntro() {
        prepareTurn(animated: false)
        scene?.playIntro {
            if engine.phase == .holeIntro { engine.beginHole() }
        }
    }

    private func handlePhaseChange(_ phase: GamePhase) {
        if CommandLine.arguments.contains("-autoplay") { autoplay(phase) }
        switch phase {
        case .matchComplete:
            if let summary = engine.summary, !settled {
                settled = true
                if !demoMode { app.settle(summary) }
            }
        case .aiming:
            prepareTurn(animated: true)
            showTurnBanner()
        default:
            break
        }
    }

    /// Set up the scene for whoever is up: their golfer, their ball, the
    /// other balls on the course as markers, and the caddie's aim.
    private func prepareTurn(animated: Bool) {
        aimOffset = 0
        showBag = false
        shape = .straight
        if readView { readView = false; scene?.setReadView(false, spot: engine.currentSpot) }
        viewPitch = 0
        if engine.shooter == 0 { partnerRead = nil }
        if let read = partnerRead, engine.currentKind == .putt {
            scene?.showPartnerRead(read.path, colorHex: read.color)
        } else {
            scene?.clearPartnerRead()
        }
        scene?.clearPreview()
        scene?.clearMarkers()
        scene?.setCharacter(engine.currentPlayer.character)
        // Teammate's ball from this round.
        for shot in engine.roundShots where !shot.holed {
            scene?.addMarker(at: shot.penalty ? (shot.dropPoint ?? shot.endPoint) : shot.endPoint,
                            teamColorHex: engine.teams[shot.teamIndex].colorHex)
        }
        // The other team's ball.
        let other = 1 - engine.activeTeam
        if !engine.holedOut[other] && engine.teamLie[other] != .tee {
            scene?.addMarker(at: engine.teamSpot[other], teamColorHex: engine.teams[other].colorHex)
        }
        scene?.placeBall(at: engine.currentSpot, onTee: engine.currentLie == .tee)
        scene?.aim(spot: engine.currentSpot, aimDir: aimU, kind: engine.currentKind, animated: animated)
        showDefaultAim()
    }

    /// Direction only — no distance aids. Shaped shots show their curve.
    private func showDefaultAim() {
        switch engine.currentKind {
        case .meter(let club):
            let carry = club.maxYards * engine.currentLie.distanceFactor
            if shape == .straight {
                scene?.showAim(from: engine.currentSpot, direction: aimU, carryYards: nil,
                               lineYards: carry * 0.55)
            } else {
                previewFull(club: club, carry: carry)
            }
        case .chip:
            scene?.showAim(from: engine.currentSpot, direction: aimU, carryYards: nil,
                           lineYards: min(engine.distanceToPinYards * 0.6, 30))
        case .putt:
            scene?.showAim(from: engine.currentSpot, direction: aimU, carryYards: nil,
                           lineYards: min(engine.distanceToPinYards * 0.6, 12))
        }
    }

    private func showTurnBanner() {
        let text = "\(engine.currentPlayer.name.uppercased())'S SHOT"
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { turnBanner = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if turnBanner == text { withAnimation(.easeOut(duration: 0.3)) { turnBanner = nil } }
        }
    }

    // MARK: - Autoplay (playtest bot)

    /// Plays the whole match through the real UI flow with a reasonable
    /// bot golfer: right club, sensible distances, human-sized errors.
    private func autoplay(_ phase: GamePhase) {
        let pace = 1 / Course3DScene.timeScale
        func later(_ t: Double, _ run: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t * pace, execute: run)
        }
        switch phase {
        case .holeIntro:
            later(0.6) { scene?.skipIntro() }
        case .aiming:
            let hole = engine.holeIndex, team = engine.activeTeam, shooter = engine.shooter
            let strokes = engine.strokes
            later(1.4) {
                guard engine.phase == .aiming, engine.holeIndex == hole, engine.activeTeam == team,
                      engine.shooter == shooter, engine.strokes == strokes else { return }
                botShot()
            }
        case .shotResult:
            if let o = engine.lastOutcome {
                NSLog("SCRAMBLE shot h%d %@ %@ lie=%@ %.0fyd holed=%d pen=%d", engine.hole.number,
                      o.playerName, o.ratingLine, o.lie.label, o.distanceToPinYards,
                      o.holed ? 1 : 0, o.penalty ? 1 : 0)
            }
            later(1.6) { if engine.phase == .shotResult { engine.advanceAfterResult() } }
        case .pickBall:
            later(1.0) {
                if engine.phase == .pickBall, let best = engine.recommendedBall() { engine.pick(best) }
            }
        case .holeComplete:
            NSLog("SCRAMBLE hole %d done: %@", engine.hole.number, "\(engine.strokes)")
            later(1.8) { if engine.phase == .holeComplete { engine.startNextHole() } }
        case .matchComplete:
            NSLog("SCRAMBLE match done: card=%@ totals=%@", "\(engine.scorecard)",
                  "\(engine.summary?.totals ?? [])")
        case .ballInMotion:
            break
        }
    }

    private func botShot() {
        let noise = { (s: Double) in (Double.random(in: -1...1) + Double.random(in: -1...1)) / 2 * s }
        switch engine.currentKind {
        case .meter(let club):
            let lf = engine.currentLie.distanceFactor
            let want = min(engine.distanceToPinYards, club.maxYards * lf)
            let b = min(max(1 + log(want / (club.maxYards * lf)) / 2.3 + noise(0.04), 0.3), 1)
            executeFullSwing(club: club, power: min(exp(2.3 * (b - 1)), 1.04),
                             earlyLate: noise(0.35))
        case .chip:
            let lf = engine.currentLie.distanceFactor
            let want = engine.distanceToPinYards * 0.72
            let b = min(max(pow(want / 62 / lf, 1 / 1.5) + noise(0.05), 0.05), 1)
            executeChip(dir: aimedDirection(drift: noise(0.05)), carry: chipCarry(b), pull: b)
        case .putt:
            let d = CGFloat(engine.distanceToPinYards) * Hole.pointsPerYard + 1.2
            let b = min(max(puttPull(forDistance: d) + noise(0.04), 0.02), 1)
            executePutt(dir: aimU.rotated(by: CGFloat(noise(0.05))), distance: puttDistance(b), pull: b)
        }
    }

    // MARK: - Shot execution

    private func executeFullSwing(club: Club, power: Double, earlyLate: Double) {
        guard engine.phase == .aiming else { return }
        let raw = ShotEngine.meterShot(club: club, power: power, earlyLate: earlyLate)
        let result = applyLie(raw)
        let spot = engine.currentSpot
        let grounded = result.flavor == .topped || result.flavor == .fat
        // Draw/fade: start away from the curve, bend back to the line.
        let curve = grounded ? 0 : shapeCurve(club)
        let aim = grounded ? aimU : startLine(club: club, carry: result.carryYards)
        let tr = BallPhysics.strike(from: spot, aim: aim, club: club,
                                    carryYards: result.carryYards,
                                    lateralYards: result.lateralYards + curve,
                                    grounded: grounded, wind: engine.wind,
                                    course: engine.hole.course)
        engine.beginShot()

        let quality: Course3DScene.SwingQuality
        switch result.rating {
        case .perfect: quality = .pure
        case .good: quality = .clean
        default: quality = .mishit
        }
        SoundFX.play("whoosh", volume: 0.45 + Float(power) * 0.3)
        scene?.swingRelease(power: power, kind: .meter(club), quality: quality) {
            Haptics.accuracyLock()
            playHitSound(result: result, club: club)
            scene?.playImpactEffect(perfect: result.rating == .perfect)
            scene?.play(tr, aim: aim, speed: 1.3,
                       tracerHex: result.rating == .perfect ? 0xFFD98A : 0xFFFFFF) { tr in
                engine.resolve(kind: .meter(club), result: result, trajectory: tr, from: spot)
                react(to: tr, rating: result.rating)
                gallery(tr, from: spot)
            }
        }
    }

    private func executeChip(dir: CGVector, carry: Double, pull: Double) {
        guard engine.phase == .aiming else { return }
        let result = ShotEngine.chip(carryYards: carry, power: pull)
        let spot = engine.currentSpot
        let tr = BallPhysics.strike(from: spot, aim: dir, club: .sandWedge,
                                    carryYards: result.carryYards, lateralYards: 0,
                                    grounded: false, wind: engine.wind,
                                    course: engine.hole.course)
        engine.beginShot()
        scene?.swingRelease(power: pull, kind: .chip, quality: .clean) {
            SoundFX.play(result.flavor == .chunk ? "mishit" : "hit_chip", volume: 0.75)
            scene?.playImpactEffect(perfect: false)
            scene?.play(tr, aim: dir, speed: 1.15, tracerHex: nil) { tr in
                engine.resolve(kind: .chip, result: result, trajectory: tr, from: spot)
                react(to: tr, rating: result.rating)
                gallery(tr, from: spot)
            }
        }
    }

    private func executePutt(dir: CGVector, distance: CGFloat, pull: Double) {
        guard engine.phase == .aiming else { return }
        let spot = engine.currentSpot
        let tr = BallPhysics.putt(from: spot, direction: dir,
                                  speed: BallPhysics.puttSpeed(forDistance: distance),
                                  course: engine.hole.course)
        engine.beginShot()
        scene?.clearPreview()
        scene?.swingRelease(power: pull, kind: .putt, quality: .clean) {
            SoundFX.play("hit_putt", volume: 0.8)
            Haptics.tick()
            let firstOfTeam = engine.shooter == 0
            let team = engine.activeTeam
            let name = engine.currentPlayer.name
            scene?.play(tr, aim: dir, speed: 1.0, tracerHex: nil) { tr in
                if firstOfTeam && tr.finish != .holed {
                    partnerRead = (tr.path, engine.teams[team].colorHex, name)
                }
                engine.resolve(kind: .putt, result: nil, trajectory: tr, from: spot)
                react(to: tr, rating: tr.finish == .holed ? .perfect : .miss)
                gallery(tr, from: spot)
            }
        }
    }

    private func react(to tr: BallPhysics.Trajectory, rating: ShotRating) {
        let good = tr.finish == .holed || (rating == .perfect && tr.finish == .rest)
        let bad = tr.finish == .water || rating == .bad || rating == .terrible
        scene?.react(celebrate: good, dejected: bad)
    }

    /// Strike sound by contact: the titanium crack / crisp click when
    /// it's pure, duller when it's not, a clank or a thud when it's ugly.
    private func playHitSound(result: ShotResult, club: Club) {
        let wood = club == .driver || club == .wood3
        switch result.flavor {
        case .topped:
            SoundFX.play("mishit_thin", volume: 0.85)
        case .fat, .chunk:
            SoundFX.play("mishit", volume: 0.9)
        default:
            switch result.rating {
            case .perfect:
                SoundFX.play(wood ? "hit_driver_pure" : "hit_iron_pure", volume: 1.0)
            case .good:
                SoundFX.play(wood ? "hit_driver" : "hit_iron", volume: 0.85)
            case .miss:
                SoundFX.play(wood ? "hit_driver" : "hit_iron", volume: 0.65)
            case .bad, .terrible:
                SoundFX.play("mishit_thin", volume: 0.75)
            }
        }
    }

    /// The gallery: applause for holed shots (big for long ones), a groan
    /// for the water.
    private func gallery(_ tr: BallPhysics.Trajectory, from spot: CGPoint) {
        switch tr.finish {
        case .holed:
            let long = spot.distance(to: engine.hole.pin) / Hole.pointsPerYard * 3 >= 15
                || tr.landing != nil
            SoundFX.play(long ? "applause_big" : "applause", volume: 0.8, after: 0.35)
        case .water:
            SoundFX.play("crowd_ohh", volume: 0.6, after: 0.3)
        case .rest:
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
