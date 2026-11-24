import SwiftUI

/// The 3-hole scorecard grid: par row, one row per team, running totals.
struct ScorecardGrid: View {
    let pars: [Int]
    let teamNames: [String]
    let teamColors: [UInt32]
    let scores: [[Int?]]
    let current: Int?

    var body: some View {
        VStack(spacing: 0) {
            row(label: "HOLE", cells: pars.indices.map { "\($0 + 1)" }, total: "TOT",
                weight: .heavy, opacity: 0.6)
            row(label: "PAR", cells: pars.map(String.init), total: "\(pars.reduce(0, +))",
                weight: .bold, opacity: 0.6)
            Divider().overlay(.white.opacity(0.15)).padding(.vertical, 4)
            ForEach(0..<teamNames.count, id: \.self) { t in
                let total = scores[t].compactMap { $0 }.reduce(0, +)
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: teamColors[t])).frame(width: 8, height: 8)
                        Text(teamNames[t]).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(pars.indices, id: \.self) { h in
                        scoreCell(scores[t][h], par: pars[h], highlight: h == current)
                    }
                    Text(total == 0 ? "–" : "\(total)")
                        .font(.system(.headline, design: .rounded).weight(.black))
                        .frame(width: 44)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 6)
            }
        }
    }

    private func row(label: String, cells: [String], total: String,
                     weight: Font.Weight, opacity: Double) -> some View {
        HStack(spacing: 0) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(cells.indices, id: \.self) { i in Text(cells[i]).frame(width: 40) }
            Text(total).frame(width: 44)
        }
        .font(.system(.caption, design: .rounded).weight(weight))
        .foregroundStyle(.white.opacity(opacity))
        .padding(.vertical, 2)
    }

    /// Golf scorecard convention: circle = under par, square = over.
    private func scoreCell(_ s: Int?, par: Int, highlight: Bool) -> some View {
        ZStack {
            if let s {
                if s < par {
                    Circle().stroke(Palette.gold, lineWidth: 1.5).frame(width: 28, height: 28)
                } else if s > par {
                    RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                }
                Text("\(s)")
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(s < par ? Palette.gold : .white)
            } else {
                Text("·").opacity(0.4)
            }
        }
        .frame(width: 40, height: 32)
        .background(highlight ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Between holes: who won the hole, the card so far, then the next tee.
struct ScorecardView: View {
    @ObservedObject var engine: MatchEngine
    let final: Bool
    let onShare: (() -> Void)?
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(headline)
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                ScorecardGrid(pars: engine.holes.map(\.par),
                              teamNames: engine.teams.map(\.name),
                              teamColors: engine.teams.map(\.colorHex),
                              scores: engine.scorecard,
                              current: engine.holeIndex)
                Text(standing)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button("Hole \(engine.holeIndex + 2) →", action: onContinue)
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
            .overlayCard()
            .padding(.horizontal, 16)
        }
    }

    private var headline: String {
        let s = engine.strokes
        if s[0] == s[1] { return "Hole \(engine.hole.number) halved" }
        let w = s[0] < s[1] ? 0 : 1
        return "\(engine.teams[w].name) take hole \(engine.hole.number)"
    }

    private var standing: String {
        let a = engine.total(team: 0), b = engine.total(team: 1)
        if a == b { return "All square with \(engine.holes.count - engine.holeIndex - 1) to play" }
        let leader = a < b ? 0 : 1
        return "\(engine.teams[leader].name) lead by \(abs(a - b))"
    }
}

/// Final whistle: scorecard, the pot, bonuses, share to the chat.
struct MatchCompleteView: View {
    @ObservedObject var engine: MatchEngine
    let summary: MatchSummary
    let onShare: () -> Void
    let onExit: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    Text(title)
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .foregroundStyle(summary.winner == 0 ? Palette.gold : .white)
                        .scaleEffect(appeared ? 1 : 0.9)
                        .opacity(appeared ? 1 : 0)
                    ScorecardGrid(pars: summary.pars, teamNames: summary.teamNames,
                                  teamColors: engine.teams.map(\.colorHex),
                                  scores: summary.scorecard.map { $0.map { Optional($0) } },
                                  current: nil)
                    VStack(spacing: 8) {
                        coinRow(summary.winner == nil ? "Match halved · wager back"
                                                      : "Wager (\(summary.pot) pot)",
                                summary.userDelta)
                        ForEach(summary.bonuses) { coinRow($0.label, $0.amount) }
                        Divider().overlay(.white.opacity(0.2))
                        coinRow("Total", summary.userTotal, bold: true)
                    }
                    .padding(14)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    Text("“\(summary.chatLine)”")
                        .font(.system(.footnote, design: .rounded).italic())
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button(action: onShare) {
                            Label("Share", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Clubhouse", action: onExit)
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(20)
                .overlayCard()
                .padding(.horizontal, 16)
                .padding(.vertical, 60)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { appeared = true }
            if summary.winner == 0 { Haptics.celebration() }
        }
    }

    private var title: String {
        guard let w = summary.winner else { return "ALL SQUARE" }
        return w == 0 ? "YOU WIN THE POT" : "\(summary.teamNames[w].uppercased()) WIN"
    }

    private func coinRow(_ label: String, _ amount: Int, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(.footnote, design: .rounded).weight(bold ? .heavy : .semibold))
                .foregroundStyle(.white.opacity(bold ? 1 : 0.8))
            Spacer()
            Text(amount >= 0 ? "+\(amount) 🪙" : "\(amount) 🪙")
                .font(.system(.footnote, design: .rounded).weight(.heavy))
                .foregroundStyle(amount >= 0 ? Palette.accent : Palette.danger)
        }
    }
}
