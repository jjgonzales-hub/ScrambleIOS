import SwiftUI

/// Pull-back-and-flick control for chips and putts. Place a finger anywhere,
/// pull back to set direction + power (a trajectory preview draws in the
/// scene), release to fire. Screen coordinates are converted to scene
/// coordinates (y flipped) before being reported.
struct FlickOverlay: View {
    let isPutt: Bool
    /// Live preview while dragging: (scene direction, power 0–1)
    var onDrag: (CGVector, Double) -> Void
    /// Finger lifted: (scene direction, power 0–1)
    var onRelease: (CGVector, Double) -> Void
    var onCancel: () -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private let maxPull: CGFloat = 240

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if let s = start, let c = current {
                    Path { p in
                        p.move(to: s)
                        p.addLine(to: c)
                    }
                    .stroke(Palette.accent.opacity(0.8),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 8]))

                    Circle()
                        .stroke(Palette.accent, lineWidth: 3)
                        .frame(width: 34, height: 34)
                        .position(s)

                    Text("\(Int(power(s, c) * 100))%")
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundStyle(Palette.cream)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.card, in: Capsule())
                        .position(x: c.x, y: c.y - 44)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.draw.fill")
                            .font(.title2)
                        Text(isPutt ? "Pull back to read the line" : "Pull back to chip")
                            .font(.system(.callout, design: .rounded).bold())
                    }
                    .foregroundStyle(Palette.cream.opacity(0.85))
                    .padding(16)
                    .background(Palette.card.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 90)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if start == nil { start = g.startLocation }
                        current = g.location
                        if let s = start, let c = current {
                            onDrag(sceneDirection(s, c), power(s, c))
                        }
                    }
                    .onEnded { g in
                        defer { start = nil; current = nil }
                        guard let s = start else { onCancel(); return }
                        let c = g.location
                        let p = power(s, c)
                        if p > 0.06 {
                            onRelease(sceneDirection(s, c), p)
                        } else {
                            onCancel()
                        }
                    }
            )
        }
    }

    /// Shot fires opposite the pull; scene y is flipped relative to screen y.
    private func sceneDirection(_ s: CGPoint, _ c: CGPoint) -> CGVector {
        CGVector(dx: s.x - c.x, dy: c.y - s.y).normalized
    }

    private func power(_ s: CGPoint, _ c: CGPoint) -> Double {
        Double(min(s.distance(to: c) / maxPull, 1))
    }
}
