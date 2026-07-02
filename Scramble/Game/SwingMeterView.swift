import SwiftUI

/// MLB The Show-style two-tap meter. The fill rises automatically; tap once
/// to lock power (light haptic), then a marker sweeps up the bar — tap again
/// at the center line to lock accuracy (heavy haptic). Early = hook,
/// late = slice, way off = topped/fat.
final class SwingMeterModel: ObservableObject {
    enum Phase: Equatable { case idle, power, accuracy, done }

    @Published var phase: Phase = .idle
    @Published private(set) var phaseStart = Date()
    @Published private(set) var lockedPower: Double = 0
    @Published private(set) var lockedEarlyLate: Double?

    var onCommit: ((Double, Double) -> Void)?
    private var autoCommit: DispatchWorkItem?

    static let powerRiseTime = 1.15
    static let accuracyDelay = 0.35
    static let accuracySweepTime = 0.62

    func start() {
        Haptics.prepare()
        lockedPower = 0
        lockedEarlyLate = nil
        phase = .power
        phaseStart = Date()
    }

    func reset() {
        autoCommit?.cancel()
        phase = .idle
        lockedEarlyLate = nil
    }

    /// Triangle wave: rises to 1.0 then falls, forever, until tapped.
    func powerValue(at date: Date) -> Double {
        guard phase == .power else { return lockedPower }
        let t = date.timeIntervalSince(phaseStart) / Self.powerRiseTime
        let m = t.truncatingRemainder(dividingBy: 2)
        return 1 - abs(1 - m)
    }

    /// Accuracy marker position 0…1 (0.5 = perfect center).
    func accuracyPosition(at date: Date) -> Double {
        switch phase {
        case .accuracy:
            let t = (date.timeIntervalSince(phaseStart) - Self.accuracyDelay)
                / Self.accuracySweepTime
            return min(max(t, 0), 1)
        case .done:
            return ((lockedEarlyLate ?? 0) + 1) / 2
        default:
            return 0
        }
    }

    func tap() {
        let now = Date()
        switch phase {
        case .power:
            lockedPower = max(powerValue(at: now), 0.05)
            Haptics.powerLock()
            SoundFX.play("ui_lock", volume: 0.55)
            phase = .accuracy
            phaseStart = now
            let work = DispatchWorkItem { [weak self] in self?.commit(sweep: 1) }
            autoCommit = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.accuracyDelay + Self.accuracySweepTime + 0.02,
                execute: work
            )
        case .accuracy:
            autoCommit?.cancel()
            commit(sweep: accuracyPosition(at: now))
        default:
            break
        }
    }

    private func commit(sweep: Double) {
        guard phase == .accuracy else { return }
        let earlyLate = (sweep - 0.5) * 2
        lockedEarlyLate = earlyLate
        phase = .done
        Haptics.accuracyLock()
        onCommit?(lockedPower, earlyLate)
    }
}

/// Sleek vertical meter: frosted capsule track, hairline ticks, flat accent
/// fill, sweet-spot band at the top, and a pill marker for the accuracy
/// sweep. No chrome, no chatter — one number and the bar.
struct SwingMeterView: View {
    @ObservedObject var model: SwingMeterModel

    private let barHeight: CGFloat = 300
    private let barWidth: CGFloat = 34

    var body: some View {
        TimelineView(.animation) { timeline in
            let power = model.powerValue(at: timeline.date)
            let accuracy = model.accuracyPosition(at: timeline.date)

            VStack(spacing: 8) {
                Text("\(Int(power * 100))")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(power > 0.94 ? Palette.danger : Palette.cream)
                    .frame(height: 24)

                ZStack(alignment: .bottom) {
                    // Frosted track
                    Capsule()
                        .fill(.ultraThinMaterial)
                    Capsule()
                        .fill(Palette.ink.opacity(0.35))
                    Capsule()
                        .strokeBorder(Palette.cream.opacity(0.35), lineWidth: 1)

                    // Hairline ticks at 25/50/75
                    ForEach([0.25, 0.5, 0.75], id: \.self) { t in
                        Rectangle()
                            .fill(Palette.cream.opacity(0.3))
                            .frame(width: 12, height: 1)
                            .offset(y: -barHeight * t)
                    }

                    // Sweet-spot band (96%+ = flushed distance bonus)
                    Capsule()
                        .fill(Palette.accent.opacity(0.55))
                        .frame(width: barWidth - 12, height: barHeight * 0.05)
                        .offset(y: -barHeight * 0.94)

                    // Power fill — flat accent, inset
                    Capsule()
                        .fill(Palette.accent.opacity(model.phase == .power ? 1 : 0.55))
                        .frame(width: barWidth - 12,
                               height: max(barHeight * CGFloat(power) - 10, 12))
                        .padding(.bottom, 5)

                    // Locked-power notch
                    if model.phase == .accuracy || model.phase == .done {
                        Capsule()
                            .fill(Palette.cream)
                            .frame(width: barWidth + 10, height: 3)
                            .offset(y: -barHeight * CGFloat(model.lockedPower))
                    }

                    // Accuracy: perfect window + center line + sweep marker
                    if model.phase == .accuracy || model.phase == .done {
                        Rectangle()
                            .fill(Palette.cream.opacity(0.14))
                            .frame(width: barWidth - 4, height: barHeight * 0.1)
                            .offset(y: -barHeight * 0.45)

                        Capsule()
                            .fill(Palette.cream)
                            .frame(width: barWidth + 16, height: 2.5)
                            .offset(y: -barHeight * 0.5)

                        marker(accuracy)
                            .offset(y: -barHeight * CGFloat(accuracy))
                    }
                }
                .frame(width: barWidth, height: barHeight)
            }
        }
    }

    private func marker(_ position: Double) -> some View {
        let hot = abs(position - 0.5) < 0.05
        return Capsule()
            .fill(hot ? Palette.accent : Palette.cream)
            .frame(width: hot ? 30 : 24, height: 9)
            .overlay(Capsule().strokeBorder(Palette.ink.opacity(0.6), lineWidth: 1.5))
    }
}
