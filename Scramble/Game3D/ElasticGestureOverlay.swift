import SwiftUI

/// v2 putt/chip gesture — the gesture lives in the world, no boxed hints.
/// Touch down: a soft cream ring appears under the thumb. Pull back: a taut
/// elastic band with tension ticks stretches from the touch point, while the
/// scene draws ghost dots along the projected line. Release: fires opposite
/// the pull. Raw screen points are reported; GameView converts them into a
/// world direction relative to the chase camera.
struct ElasticGestureOverlay: View {
    let isPutt: Bool
    /// Projected distance readout for the floating pill, e.g. "11 ft".
    let label: (Double) -> String
    var onDrag: (CGPoint, CGPoint) -> Void
    /// (start, end, release velocity in pts/s) — the upward flick speed at
    /// release is what turns a lag putt into a firm one.
    var onRelease: (CGPoint, CGPoint, CGSize) -> Void
    var onCancel: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    static let maxPull: CGFloat = 240

    static func power(_ s: CGPoint, _ c: CGPoint) -> Double {
        Double(min(s.distance(to: c) / maxPull, 1))
    }

    var body: some View {
        ZStack {
            if let s = start, let c = current {
                // Taut elastic band with tension ticks
                Path { p in
                    p.move(to: s)
                    p.addLine(to: c)
                }
                .stroke(Palette.cream.opacity(0.9),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

                ForEach([0.4, 0.7], id: \.self) { t in
                    tick(s: s, c: c, t: t)
                }

                // Anchor dot where the pull started
                Circle()
                    .fill(Palette.cream.opacity(0.7))
                    .frame(width: 9, height: 9)
                    .position(s)

                // Thumb ring
                Circle()
                    .stroke(Palette.cream, lineWidth: 3.5)
                    .frame(width: 34, height: 34)
                    .position(c)
                Circle()
                    .fill(Palette.cream)
                    .frame(width: 9, height: 9)
                    .position(c)

                // Floating distance pill by the thumb
                Text(label(Self.power(s, c)))
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Palette.cream.opacity(0.95), in: Capsule())
                    .position(x: c.x + 58, y: c.y - 26)
            } else {
                // Unboxed one-line hint — no cards, per the art direction
                Text(isPutt ? "pull back · flick up to putt"
                            : "pull back · flick up to chip")
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
                    if start == nil { start = g.startLocation }
                    current = g.location
                    if let s = start, let c = current {
                        onDrag(s, c)
                    }
                }
                .onEnded { g in
                    defer { start = nil; current = nil }
                    guard let s = start else { onCancel(); return }
                    let c = g.location
                    if Self.power(s, c) > 0.06 {
                        onRelease(s, c, g.velocity)
                    } else {
                        onCancel()
                    }
                }
        )
    }

    /// Short line across the band at fraction `t` — reads as tension.
    private func tick(s: CGPoint, c: CGPoint, t: Double) -> some View {
        let mid = CGPoint(x: s.x + (c.x - s.x) * t, y: s.y + (c.y - s.y) * t)
        let v = CGVector(from: s, to: c).normalized
        let perp = CGVector(dx: -v.dy, dy: v.dx)
        return Path { p in
            p.move(to: mid + perp * 7)
            p.addLine(to: mid + perp * -7)
        }
        .stroke(Palette.cream.opacity(0.8),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
    }
}
