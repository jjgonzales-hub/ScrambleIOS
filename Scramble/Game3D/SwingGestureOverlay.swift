import SwiftUI

/// Golf Dreams-style one-motion swing — now for EVERY club. Pull DOWN and
/// the golfer's swing (or putter) mirrors your finger; rip UP in the same
/// touch to strike. Power = pull length × up-swipe speed.
///
/// Lateral drift means different things by mode:
/// - full swing: drift from the top of the backswing to release opens or
///   closes the face — hook/slice. Dead straight is pure.
/// - chip/putt: drift AIMS the shot left/right of the pin, so you can
///   play the break you read on the green.
///
/// Fixes Golf Dreams' known flaw (partial power unreadable): a floating
/// pill shows the live pull (% or projected ft/yds), and a faint dashed
/// axis through the touch point makes drift visible.
struct SwingGestureOverlay: View {
    enum Mode { case full, chip, putt }

    let mode: Mode
    /// Pill text for the current pull amount 0…1.
    let label: (Double) -> String
    /// Live during the pull: (pull 0…1, aim drift -1…1).
    var onPull: (Double, Double) -> Void
    /// Committed: (pull 0…1, aim drift -1…1, shape drift -1…1, up-swipe pts/s).
    var onSwing: (Double, Double, Double, Double) -> Void
    var onCancel: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var deepest: CGPoint?
    @State private var peaked = false

    private var maxPull: CGFloat {
        switch mode {
        case .full: return 260
        case .chip: return 210
        case .putt: return 230
        }
    }

    /// A putt can be released gently (finesse); chips need a flick;
    /// a drive needs a real rip.
    private var minUpSpeed: Double {
        switch mode {
        case .full: return 250
        case .chip: return 150
        case .putt: return 90
        }
    }

    private var hint: String {
        switch mode {
        case .full: return "pull down · rip up to swing"
        case .chip: return "pull down · flick up to chip"
        case .putt: return "pull down · flick up · drift to aim"
        }
    }

    var body: some View {
        ZStack {
            if let s = start, let c = current {
                Path { p in
                    p.move(to: CGPoint(x: s.x, y: s.y - 70))
                    p.addLine(to: CGPoint(x: s.x, y: s.y + maxPull + 30))
                }
                .stroke(Palette.cream.opacity(0.35),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                           dash: [1, 10]))

                Circle()
                    .fill(Palette.cream.opacity(0.7))
                    .frame(width: 9, height: 9)
                    .position(s)

                Circle()
                    .stroke(peaked ? Palette.accent : Palette.cream, lineWidth: 3.5)
                    .frame(width: 34, height: 34)
                    .position(c)
                Circle()
                    .fill(Palette.cream)
                    .frame(width: 9, height: 9)
                    .position(c)

                Text(label(pull(s, deepest ?? c)))
                    .font(.system(.callout, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        (peaked ? Palette.accent : Palette.cream).opacity(0.95),
                        in: Capsule())
                    .position(x: c.x + 58, y: c.y - 26)
            } else {
                Text(hint)
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundStyle(Palette.cream.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottom)
                    .padding(.bottom, 118)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if start == nil {
                        start = g.startLocation
                        deepest = g.startLocation
                        peaked = false
                    }
                    current = g.location
                    if g.location.y > (deepest?.y ?? -.infinity) {
                        deepest = g.location
                    }
                    guard let s = start, let d = deepest else { return }
                    let b = pull(s, d)
                    if b >= 1, !peaked {
                        peaked = true
                        Haptics.powerLock()
                    }
                    onPull(b, drift(from: s.x, to: g.location.x))
                }
                .onEnded { g in
                    defer { start = nil; current = nil; deepest = nil; peaked = false }
                    guard let s = start, let d = deepest else { onCancel(); return }
                    let b = pull(s, d)
                    let upSpeed = max(0, -Double(g.velocity.height))
                    guard b > 0.08, upSpeed > minUpSpeed else { onCancel(); return }
                    onSwing(b,
                            drift(from: s.x, to: g.location.x),
                            drift(from: d.x, to: g.location.x),
                            upSpeed)
                }
        )
    }

    private func pull(_ s: CGPoint, _ d: CGPoint) -> Double {
        Double(min(max((d.y - s.y) / maxPull, 0), 1))
    }

    private func drift(from a: CGFloat, to b: CGFloat) -> Double {
        min(max(Double((b - a) / 130), -1), 1)
    }
}
