import SwiftUI

/// Post-shot card: big rating, the shot stats, where it finished, and the
/// auto-generated chat line. Sits low so the ball stays visible.
struct ResultBanner: View {
    let outcome: ShotOutcome
    let onShare: () -> Void
    let onContinue: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Text(headline)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)

                if !outcome.ratingLine.isEmpty {
                    Text(outcome.ratingLine)
                        .font(.system(.subheadline, design: .rounded).weight(.heavy))
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }

                Text(lieLine)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))

                if !outcome.message.isEmpty {
                    Text("“\(outcome.message)”")
                        .font(.system(.footnote, design: .rounded).italic())
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }

                HStack(spacing: 10) {
                    Button(action: onShare) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(width: 70)
                    Button("Continue", action: onContinue)
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(18)
            .overlayCard()
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { appeared = true }
        }
    }

    private var headline: String {
        if outcome.holed { return outcome.kind == .putt ? "SUNK IT!" : "IN THE HOLE!" }
        if outcome.penalty { return "SPLASH" }
        switch outcome.kind {
        case .putt: return outcome.ratingLine.hasPrefix("LIPPED") ? "LIPPED OUT" : "MISSED"
        case .chip: return outcome.distanceToPinYards * 3 < 4 ? "TAP-IN RANGE" : "CHIPPED"
        case .meter:
            return outcome.ratingLine.components(separatedBy: " ·").first ?? "SHOT"
        }
    }

    private var headlineColor: Color {
        if outcome.holed { return Palette.gold }
        if outcome.penalty { return Palette.danger }
        if headline == "PURE" { return Palette.gold }
        if headline == "UGLY" || headline == "DISASTER" { return Palette.danger }
        return .white
    }

    private var lieLine: String {
        if outcome.holed { return "In the cup" }
        if outcome.penalty { return "One-stroke penalty · drop near where it crossed" }
        let dist = outcome.lie == .green || outcome.distanceToPinYards < 10
            ? "\(Int(outcome.distanceToPinYards * 3)) ft to the pin"
            : "\(Int(outcome.distanceToPinYards)) yd to the pin"
        return "\(outcome.lie.label) · \(dist)"
    }
}
