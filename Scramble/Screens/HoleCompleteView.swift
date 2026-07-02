import SwiftUI

/// End-of-hole scorecard: team scores, wager settlement, coin bonuses,
/// and the final trash-talk line ready to share.
struct HoleCompleteView: View {
    let summary: HoleSummary
    let onShare: () -> Void
    let onExit: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Palette.ink.opacity(0.88).ignoresSafeArea()

            VStack(spacing: 18) {
                Text(titleText)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Palette.accent)
                    .multilineTextAlignment(.center)
                    .scaleEffect(appeared ? 1 : 0.94)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: appeared)

                // Scorecard
                VStack(spacing: 10) {
                    ForEach(0..<2, id: \.self) { i in
                        HStack {
                            Text(summary.teamNames[i])
                                .font(.system(.headline, design: .rounded).bold())
                                .foregroundStyle(summary.winner == i
                                                 ? Palette.accent : Palette.cream)
                            if summary.winner == i {
                                Image(systemName: "crown.fill")
                                    .foregroundStyle(Palette.accent)
                            }
                            Spacer()
                            Text(scoreText(summary.strokes[i]))
                                .font(.system(.headline, design: .rounded).bold())
                                .foregroundStyle(Palette.cream)
                        }
                        .padding(14)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                }

                // Coin settlement
                VStack(spacing: 8) {
                    row(label: summary.winner == nil ? "Hole halved — wagers returned"
                                                     : "Wager (\(summary.pot) coin pot)",
                        amount: summary.userDelta)
                    ForEach(summary.bonuses) { bonus in
                        row(label: bonus.label, amount: bonus.amount)
                    }
                    Divider().overlay(Palette.cream.opacity(0.2))
                    row(label: "Total", amount: summary.userTotal, bold: true)
                }
                .padding(14)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))

                Text("“\(summary.chatLine)”")
                    .font(.system(.subheadline, design: .rounded).italic())
                    .foregroundStyle(Palette.accent)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(action: onShare) {
                        Label("Share", systemImage: "bubble.left.and.bubble.right.fill")
                            .font(.system(.callout, design: .rounded).bold())
                            .foregroundStyle(Palette.cream)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity)
                            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button(action: onExit) {
                        Text("Back to Clubhouse")
                            .font(.system(.callout, design: .rounded).bold())
                            .foregroundStyle(Palette.ink)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(22)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Palette.accent.opacity(0.6), lineWidth: 2)
            )
            .padding(.horizontal, 16)
        }
        .onAppear {
            appeared = true
            if summary.winner == 0 { Haptics.celebration() }
        }
    }

    private var titleText: String {
        guard let w = summary.winner else { return "PUSH" }
        return w == 0 ? "YOU WIN" : "\(summary.teamNames[w].uppercased()) WINS"
    }

    private func scoreText(_ strokes: Int) -> String {
        let name = TrashTalk.scoreName(strokes - summary.par)
        return name.map { "\(strokes)  (\($0))" } ?? "\(strokes)"
    }

    private func row(label: String, amount: Int, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(.footnote, design: .rounded).weight(bold ? .bold : .regular))
                .foregroundStyle(Palette.cream.opacity(bold ? 1 : 0.8))
            Spacer()
            Text(amount >= 0 ? "+\(amount) 🪙" : "\(amount) 🪙")
                .font(.system(.footnote, design: .rounded).bold())
                .foregroundStyle(amount >= 0 ? Palette.fairway : Palette.danger)
        }
    }
}
