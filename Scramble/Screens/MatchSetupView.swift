import SwiftUI

/// Set up a 2v2: name the players, agree the wager, tee off.
/// v0.2: real friend invites + Supabase matchmaking; this version is
/// pass-and-play on one device.
struct MatchSetupView: View {
    @EnvironmentObject private var app: AppState

    @State private var names = ["You", "Sam", "Jake", "Riley"]
    @State private var wagerChoice: WagerChoice = .friendly
    @State private var customWager = 250
    @State private var activeMatch: MatchConfig?

    enum WagerChoice: String, CaseIterable, Identifiable {
        case friendly = "Friendly"
        case stakes = "Stakes"
        case highRoller = "High Roller"
        case custom = "Custom"

        var id: String { rawValue }

        var coins: Int? {
            switch self {
            case .friendly: return 100
            case .stakes: return 500
            case .highRoller: return 2000
            case .custom: return nil
            }
        }
    }

    private var wagerAmount: Int {
        wagerChoice.coins ?? customWager
    }

    private var canAfford: Bool { app.coins >= wagerAmount }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    teamCard(title: "🔵 YOUR TEAM", indices: [0, 1])
                    teamCard(title: "🔴 THE ENEMY", indices: [2, 3])
                    wagerCard
                    teeOffButton
                }
                .padding(18)
            }
        }
        .navigationTitle("Match Setup")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeMatch) { config in
            GameView(config: config) { activeMatch = nil }
        }
    }

    private func teamCard(title: String, indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.headline, design: .rounded).bold())
                .foregroundStyle(Palette.cream)
            ForEach(indices, id: \.self) { i in
                TextField("Player name", text: $names[i])
                    .font(.system(.body, design: .rounded).bold())
                    .foregroundStyle(Palette.cream)
                    .padding(12)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var wagerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("💰 THE WAGER")
                .font(.system(.headline, design: .rounded).bold())
                .foregroundStyle(Palette.cream)

            ForEach(WagerChoice.allCases) { choice in
                Button {
                    wagerChoice = choice
                } label: {
                    HStack {
                        Text(choice.rawValue)
                            .font(.system(.body, design: .rounded).bold())
                            .foregroundStyle(Palette.cream)
                        Spacer()
                        Text(choice.coins.map { "🪙 \($0)" } ?? "🪙 you pick")
                            .font(.system(.callout, design: .rounded).bold())
                            .foregroundStyle(Palette.accent)
                        Image(systemName: wagerChoice == choice
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Palette.accent)
                    }
                    .padding(13)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(wagerChoice == choice ? Palette.accent : .clear,
                                    lineWidth: 2)
                    )
                }
            }

            if wagerChoice == .custom {
                Stepper(value: $customWager, in: 50...10000, step: 50) {
                    Text("🪙 \(customWager)")
                        .font(.system(.body, design: .rounded).bold())
                        .foregroundStyle(Palette.accent)
                }
                .padding(.horizontal, 4)
            }

            if !canAfford {
                Text("You only have 🪙 \(app.coins) — pick a smaller wager.")
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundStyle(Palette.danger)
            }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var teeOffButton: some View {
        Button {
            startMatch()
        } label: {
            Text("⛳️ TEE OFF — 🪙 \(wagerAmount) ON THE LINE")
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(canAfford ? Palette.accent : Palette.accent.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 18))
        }
        .disabled(!canAfford)
    }

    private func startMatch() {
        let emojis = ["🏌️", "🧢", "😎", "🦩"]
        let players = names.enumerated().map { i, name in
            Player(name: name.isEmpty ? "Player \(i + 1)" : name, emoji: emojis[i])
        }
        let teams = [
            Team(name: "\(players[0].name) & \(players[1].name)",
                 players: [players[0], players[1]], colorHex: 0x6E97AC),
            Team(name: "\(players[2].name) & \(players[3].name)",
                 players: [players[2], players[3]], colorHex: 0xB5533C)
        ]
        activeMatch = MatchConfig(teams: teams, wager: wagerAmount, hole: .one())
    }
}
