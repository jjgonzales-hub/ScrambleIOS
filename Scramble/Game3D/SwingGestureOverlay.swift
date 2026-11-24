import SwiftUI

/// Golf Dreams-style one-motion swing for every club. Touch anywhere, pull
/// DOWN and the golfer's backswing follows your finger; push back UP and
/// the club comes through — the ball is struck the moment your finger
/// passes back through where it started (no need to lift).
///
/// - Power = how far back you pulled (exponential, mapped by the caller).
/// - Lateral drift on the way back and through = face/path (hook/slice);
///   for chips and putts, drift aims left/right instead.
///
/// Fixes Golf Dreams' "can't judge a partial swing" complaint: the pill
/// shows the projected carry for this backswing, the landing ring in the
/// world moves with it, and there's a haptic tick every quarter.
struct SwingGestureOverlay: View {
    enum Mode { case full, chip, putt }

    let mode: Mode
    /// Pill text for the current pull 0…1.
    let label: (Double) -> String
    /// Live during the pull: (pull 0…1, aim drift -1…1).
    var onPull: (Double, Double) -> Void
    /// Committed: (pull 0…1, aim drift -1…1, shape drift -1…1, up-swipe pts/s).
    var onSwing: (Double, Double, Double, Double) -> Void
    var onCancel: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var deepest: CGPoint?
    @State private var lastQuarter = 0
    @State private var committed = false
    @State private var samples: [(t: TimeInterval, y: CGFloat)] = []

    private var maxPull: CGFloat {
        switch mode {
        case .full: return 250
        case .chip: return 210
        case .putt: return 220
        }
    }

    /// Below this up-swing speed a full swing doesn't count (stops
    /// accidental hits when you just change your mind slowly).
    private var minUpSpeed: Double {
        switch mode {
        case .full: return 160
        case .chip: return 60
        case .putt: return 0
        }
    }

    private var hint: String {
        switch mode {
        case .full: return "Pull down to swing back · push up to hit"
        case .chip: return "Pull down · push up to chip · drift to aim"
        case .putt: return "Pull back · push through · drift to aim"
        }
    }

    var body: some View {
        ZStack {
            if let s = start, let c = current {
                let pull = pullAmount(s, deepest ?? c)
                // Power strip on the left edge.
                HStack {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.black.opacity(0.28))
                        Capsule()
                            .fill(LinearGradient(colors: [Palette.accent, Color(hex: 0xF2C94C),
                                                          Color(hex: 0xF0705E)],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(height: max(220 * pull, 10))
                        ForEach([0.25, 0.5, 0.75], id: \.self) { q in
                            Rectangle().fill(.white.opacity(0.7))
                                .frame(width: 14, height: 1.5)
                                .offset(y: -220 * q)
                        }
                    }
                    .frame(width: 10, height: 220)
                    Spacer()
                }
                .padding(.leading, 14)

                // Swing axis through the start point: drift is visible.
                Path { p in
                    p.move(to: CGPoint(x: s.x, y: s.y - 60))
                    p.addLine(to: CGPoint(x: s.x, y: s.y + maxPull + 20))
                }
                .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                                 dash: [1, 9]))
                Circle().fill(.white.opacity(0.8)).frame(width: 8, height: 8).position(s)

                Circle()
                    .stroke(pull >= 1 ? Palette.accent : .white, lineWidth: 3)
                    .frame(width: 38, height: 38)
                    .position(c)
                Circle().fill(.white).frame(width: 10, height: 10).position(c)

                Text(label(pull))
                    .font(.system(.callout, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(pull >= 1 ? Palette.accent : .white, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .position(x: min(c.x + 62, 330), y: c.y - 30)
            } else {
                Text(hint)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.25), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 150)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in changed(g) }
                .onEnded { _ in ended() }
        )
    }

    private func changed(_ g: DragGesture.Value) {
        guard !committed else { return }
        if start == nil {
            start = g.startLocation
            deepest = g.startLocation
            lastQuarter = 0
            samples = []
        }
        current = g.location
        let now = g.time.timeIntervalSinceReferenceDate
        samples.append((now, g.location.y))
        samples.removeAll { now - $0.t > 0.08 }

        guard let s = start else { return }
        if g.location.y > (deepest?.y ?? -.infinity) { deepest = g.location }
        guard let d = deepest else { return }
        let pull = pullAmount(s, d)

        // Haptic ticks at each quarter of the backswing.
        let quarter = Int(pull * 4)
        if quarter > lastQuarter {
            lastQuarter = quarter
            if quarter >= 4 { Haptics.powerLock() } else { Haptics.tick() }
        }

        let returning = d.y - g.location.y
        let pulledPts = d.y - s.y
        // Strike: the finger came back up through the start point.
        if pull > 0.04 && returning > 8 && g.location.y <= s.y + pulledPts * 0.08 {
            let up = upSpeed()
            guard up >= minUpSpeed else { return }
            committed = true
            onSwing(pull, drift(s.x, g.location.x), drift(d.x, g.location.x), up)
            return
        }
        onPull(pull, drift(s.x, g.location.x))
    }

    private func ended() {
        if !committed { onCancel() }
        start = nil
        current = nil
        deepest = nil
        committed = false
        samples = []
    }

    private func upSpeed() -> Double {
        guard let first = samples.first, let last = samples.last, last.t > first.t else { return 0 }
        return max(0, Double(first.y - last.y) / (last.t - first.t))
    }

    private func pullAmount(_ s: CGPoint, _ d: CGPoint) -> Double {
        Double(min(max((d.y - s.y) / maxPull, 0), 1))
    }

    private func drift(_ a: CGFloat, _ b: CGFloat) -> Double {
        min(max(Double((b - a) / 120), -1), 1)
    }
}
