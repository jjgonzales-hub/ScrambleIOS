import SwiftUI

/// Post-shot overlay: big exaggerated rating, the auto-generated group chat
/// message, and Share / Continue actions.
struct ResultBanner: View {
    let outcome: ShotOutcome
    let onShare: () -> Void
    let onContinue: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Text(headline)
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .scaleEffect(appeared ? 1 : 0.94)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8),
                               value: appeared)

                if !outcome.ratingLine.isEmpty {
                    Text(outcome.ratingLine)
                        .font(.system(.headline, design: .rounded).bold())
                        .foregroundStyle(Palette.cream)
                }

                HStack(spacing: 8) {
                    Text(outcome.lie.emoji)
                    Text(lieLine)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Palette.cream.opacity(0.85))
                }

                if !outcome.message.isEmpty {
                    Text("“\(outcome.message)”")
                        .font(.system(.subheadline, design: .rounded).italic())
                        .foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 12) {
                    Button(action: onShare) {
                        Label("Share to Chat", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(.callout, design: .rounded).bold())
                            .foregroundStyle(Palette.cream)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button(action: onContinue) {
                        Text("Continue")
                            .font(.system(.callout, design: .rounded).bold())
                            .foregroundStyle(Palette.ink)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Palette.accent.opacity(0.5), lineWidth: 2)
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .onAppear { appeared = true }
    }

    private var headline: String {
        if outcome.holed {
            return outcome.kind == .putt ? "SUNK IT" : "HOLED OUT"
        }
        if outcome.penalty { return "IN THE WATER" }
        switch outcome.kind {
        case .putt: return "MISSED"
        default: return outcome.ratingLine.components(separatedBy: " •").first ?? "SHOT"
        }
    }

    private var headlineColor: Color {
        if outcome.holed { return Palette.fairway }
        if outcome.penalty { return Palette.water }
        return Palette.cream
    }

    private var lieLine: String {
        if outcome.holed { return "In the cup!" }
        if outcome.penalty { return "Penalty — drop coming" }
        let dist = outcome.lie == .green
            ? "\(Int(outcome.distanceToPinYards * 3)) ft to the pin"
            : "\(Int(outcome.distanceToPinYards)) yds to the pin"
        return "\(outcome.lie.label) • \(dist)"
    }
}
