import SwiftUI

/// MLB The Show-style two-tap meter. The fill rises automatically; tap once
/// to lock power (light haptic), then a diamond sweeps up the bar — tap again
/// at the center notch to lock accuracy (heavy haptic). Early = hook,
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

struct SwingMeterView: View {
    @ObservedObject var model: SwingMeterModel

    private let barHeight: CGFloat = 320
    private let barWidth: CGFloat = 46

    var body: some View {
        TimelineView(.animation) { timeline in
            let power = model.powerValue(at: timeline.date)
            let accuracy = model.accuracyPosition(at: timeline.date)

            VStack(spacing: 10) {
                readout(power: power)

                ZStack(alignment: .bottom) {
                    // Track
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Palette.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Palette.accent.opacity(0.7), lineWidth: 2.5)
                        )

                    // Sweet-spot band near the top (96%+ = distance bonus)
                    Rectangle()
                        .fill(Palette.accent.opacity(0.35))
                        .frame(width: barWidth - 8, height: barHeight * 0.06)
                        .offset(y: -barHeight * 0.94)

                    // Power fill
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: [Palette.fairway, Palette.sand, Palette.danger],
                                startPoint: .bottom, endPoint: .top
                            )
                        )
                        .frame(width: barWidth - 10,
                               height: max(barHeight * CGFloat(power), 8))
                        .padding(.bottom, 5)

                    // Accuracy center notch
                    if model.phase == .accuracy || model.phase == .done {
                        Rectangle()
                            .fill(Palette.cream)
                            .frame(width: barWidth + 14, height: 3)
                            .offset(y: -barHeight / 2)

                        // Sweeping diamond
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(diamondColor(accuracy))
                            .offset(x: 0, y: -barHeight * CGFloat(accuracy))
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                .frame(width: barWidth, height: barHeight)
            }
        }
    }

    private func readout(power: Double) -> some View {
        VStack(spacing: 2) {
            switch model.phase {
            case .power:
                Text("PWR \(Int(power * 100))%")
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundStyle(Palette.accent)
                Text("TAP!")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundStyle(Palette.cream.opacity(0.7))
            case .accuracy:
                Text("PWR \(Int(model.lockedPower * 100))%")
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundStyle(Palette.cream)
                Text("NOW THE LINE…")
                    .font(.system(.caption2, design: .rounded).bold())
                    .foregroundStyle(Palette.accent)
            case .done:
                let acc = Int((1 - abs(model.lockedEarlyLate ?? 0)) * 100)
                Text("PWR \(Int(model.lockedPower * 100))%")
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundStyle(Palette.cream)
                Text("ACC \(acc)%")
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundStyle(acc >= 95 ? Palette.fairway : Palette.accent)
            case .idle:
                Text(" ")
                    .font(.system(.callout, design: .rounded).bold())
            }
        }
        .frame(height: 40)
    }

    private func diamondColor(_ position: Double) -> Color {
        abs(position - 0.5) < 0.05 ? Palette.fairway : Palette.cream
    }
}
