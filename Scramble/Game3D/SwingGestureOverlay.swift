import SwiftUI

/// Golf Dreams-style one-motion swing for full shots. No meter, no timing
/// bar: pull DOWN and the golfer's backswing tracks your finger; rip UP in
/// the same touch and he swings. Power = backswing length × up-swipe
/// speed. Lateral drift on the way up opens or closes the face —
/// hook/slice — so dead straight is pure.
///
/// Fixes Golf Dreams' known flaw (partial power is unreadable there): a
/// floating pill shows the backswing % live, and a faint vertical axis
/// through the touch point makes drift visible.
struct SwingGestureOverlay: View {
    /// Live backswing 0…1 while pulling.
    var onPull: (Double) -> Void
    /// Committed swing: (power 0…1, earlyLate -1…1; negative = hook).
    var onSwing: (Double, Double) -> Void
    var onCancel: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @State private var deepest: CGPoint?
    @State private var peaked = false

    static let maxPull: CGFloat = 260

    var body: some View {
        ZStack {
            if let s = start, let c = current {
                // Swing axis — drift off this line is hook/slice
                Path { p in
                    p.move(to: CGPoint(x: s.x, y: s.y - 70))
                    p.addLine(to: CGPoint(x: s.x, y: s.y + Self.maxPull + 30))
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

                Text("\(Int(backswing(s, deepest ?? c) * 100))")
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
                Text("pull down · rip up to swing")
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
                    let b = backswing(s, d)
                    if b >= 1, !peaked {
                        peaked = true
                        Haptics.powerLock()   // felt: you're at the top
                    }
                    onPull(b)
                }
                .onEnded { g in
                    defer { start = nil; current = nil; deepest = nil; peaked = false }
                    guard let s = start, let d = deepest else { onCancel(); return }
                    let b = backswing(s, d)
                    let upSpeed = max(0, -Double(g.velocity.height))
                    // No real up-swipe = no swing. Ease back to address.
                    guard b > 0.08, upSpeed > 250 else { onCancel(); return }

                    let flick = min(upSpeed / 3000, 1)
                    let power = min(b * (0.5 + 0.65 * flick), 1)
                    // Face control: lateral drift from the top of the
                    // backswing to release. Right = slice, left = hook.
                    let drift = Double(g.location.x - d.x)
                    let earlyLate = min(max(drift / 130, -1), 1)
                    onSwing(power, earlyLate)
                }
        )
    }

    private func backswing(_ s: CGPoint, _ d: CGPoint) -> Double {
        Double(min(max((d.y - s.y) / Self.maxPull, 0), 1))
    }
}
