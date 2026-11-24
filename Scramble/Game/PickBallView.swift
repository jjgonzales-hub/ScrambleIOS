import SwiftUI

/// The scramble decision: both teammates have hit, pick which ball the
/// team plays next. Both balls are marked on the course behind this card.
struct PickBallView: View {
    @ObservedObject var engine: MatchEngine

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("PICK YOUR BALL")
                        .font(.system(.title3, design: .rounded).weight(.black))
                        .foregroundStyle(.white)
                    Text("\(engine.currentTeam.name) · best ball plays")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }

                ForEach(engine.roundShots) { shot in
                    let best = shot.id == engine.recommendedBall()?.id
                    Button {
                        engine.pick(shot)
                    } label: {
                        HStack(spacing: 12) {
                            Text(shot.lie.emoji).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(shot.playerName)'s ball")
                                    .font(.system(.headline, design: .rounded).weight(.heavy))
                                    .foregroundStyle(.white)
                                Text(detail(for: shot))
                                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                                    .foregroundStyle(shot.penalty ? Palette.danger : .white.opacity(0.7))
                            }
                            Spacer()
                            if best {
                                Text("BEST")
                                    .font(.system(.caption2, design: .rounded).weight(.black))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Palette.accent, in: Capsule())
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(14)
                        .background(.white.opacity(best ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(best ? Palette.accent.opacity(0.8) : .clear, lineWidth: 2))
                    }
                }
            }
            .padding(18)
            .overlayCard()
            .padding(.horizontal, 14)
            .padding(.bottom, 18)
        }
    }

    private func detail(for shot: ShotOutcome) -> String {
        if shot.holed { return "In the hole!" }
        if shot.penalty { return "Water · +1 penalty, drop" }
        let dist = shot.lie == .green
            ? "\(Int(shot.distanceToPinYards * 3)) ft"
            : "\(Int(shot.distanceToPinYards)) yd"
        return "\(shot.lie.label) · \(dist) to the pin"
    }
}
