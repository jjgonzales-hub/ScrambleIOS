import SwiftUI

/// Scramble's signature moment: both teammates have hit — pick the ball
/// the team plays from. The engine recommends the closest dry ball.
struct PickBallView: View {
    @ObservedObject var engine: MatchEngine

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                Text("PICK YOUR BALL")
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(Palette.accent)
                Text("\(engine.currentTeam.name) — best ball plays")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(Palette.cream.opacity(0.8))

                ForEach(engine.roundShots) { shot in
                    Button {
                        engine.pick(shot)
                    } label: {
                        HStack(spacing: 12) {
                            Text(shot.lie.emoji).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shot.playerName)
                                    .font(.system(.headline, design: .rounded).bold())
                                    .foregroundStyle(Palette.cream)
                                Text(detail(for: shot))
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(shot.penalty ? Palette.danger
                                                     : Palette.cream.opacity(0.7))
                            }
                            Spacer()
                            if shot.id == engine.recommendedBall()?.id {
                                Text("BEST")
                                    .font(.system(.caption2, design: .rounded).weight(.black))
                                    .foregroundStyle(Palette.ink)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Palette.fairway, in: Capsule())
                            }
                        }
                        .padding(14)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    shot.id == engine.recommendedBall()?.id
                                        ? Palette.fairway.opacity(0.7)
                                        : Palette.cream.opacity(0.15),
                                    lineWidth: 2
                                )
                        )
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
    }

    private func detail(for shot: ShotOutcome) -> String {
        if shot.penalty { return "In the water — +1 penalty stroke" }
        let dist = shot.lie == .green
            ? "\(Int(shot.distanceToPinYards * 3)) ft out"
            : "\(Int(shot.distanceToPinYards)) yds out"
        return "\(shot.lie.label) • \(dist)"
    }
}
