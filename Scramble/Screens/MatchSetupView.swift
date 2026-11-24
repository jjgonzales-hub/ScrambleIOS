import SwiftUI

/// Set up a 2v2: name the players, pick their golfers, agree the wager,
/// tee off. Pass-and-play on one phone; the iMessage version will fill
/// these from the group chat.
struct MatchSetupView: View {
    @EnvironmentObject private var app: AppState

    @State private var names = ["You", "Sam", "Jake", "Riley"]
    @State private var characters = ["male_a", "female_b", "male_e", "female_d"]
    @State private var wagerChoice: WagerChoice = .friendly
    @State private var customWager = 250
    @State private var activeMatch: MatchConfig?
    @State private var picking: PickerTarget?

    struct PickerTarget: Identifiable { let index: Int; var id: Int { index } }

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

    private var wagerAmount: Int { wagerChoice.coins ?? customWager }
    private var canAfford: Bool { app.coins >= wagerAmount }

    var body: some View {
        ZStack {
            Palette.deep.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    courseCard
                    teamCard(title: "YOUR TEAM", color: 0x4F9BE0, indices: [0, 1])
                    teamCard(title: "THE ENEMY", color: 0xF0705E, indices: [2, 3])
                    wagerCard
                    Button("Tee off · 🪙 \(wagerAmount) on the line", action: startMatch)
                        .buttonStyle(PrimaryButtonStyle(color: canAfford ? Palette.accent
                                                                         : Palette.accent.opacity(0.35)))
                        .disabled(!canAfford)
                }
                .padding(16)
            }
        }
        .navigationTitle("New Match")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.deep, for: .navigationBar)
        .fullScreenCover(item: $activeMatch) { config in
            GameView(config: config) { activeMatch = nil }
        }
        .sheet(item: $picking) { target in
            CharacterPicker(selected: $characters[target.index])
                .presentationDetents([.medium])
        }
    }

    private var courseCard: some View {
        HStack(spacing: 10) {
            ForEach(Hole.course, id: \.number) { hole in
                VStack(spacing: 2) {
                    Text("\(hole.number)")
                        .font(.system(.title3, design: .rounded).weight(.black))
                    Text("PAR \(hole.par)")
                        .font(.system(.caption2, design: .rounded).weight(.heavy))
                        .opacity(0.7)
                    Text("\(hole.yards) yd")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .opacity(0.6)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(12)
        .card()
    }

    private func teamCard(title: String, color: UInt32, indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: color)).frame(width: 10, height: 10)
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(indices, id: \.self) { i in
                HStack(spacing: 12) {
                    Button { picking = PickerTarget(index: i) } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Group {
                                if let img = CharacterPortrait.image(for: characters[i]) {
                                    Image(uiImage: img).resizable().scaledToFit()
                                } else {
                                    Image(systemName: "figure.golf").font(.title)
                                }
                            }
                            .frame(width: 60, height: 60)
                            .background(Color(hex: color).opacity(0.25),
                                        in: RoundedRectangle(cornerRadius: 14))
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Palette.ink)
                                .padding(4)
                                .background(.white, in: Circle())
                                .offset(x: 4, y: 4)
                        }
                    }
                    TextField("Player name", text: $names[i])
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .card()
    }

    private var wagerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("THE WAGER")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.7))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(WagerChoice.allCases) { choice in
                    Button { wagerChoice = choice } label: {
                        VStack(spacing: 2) {
                            Text(choice.rawValue)
                                .font(.system(.subheadline, design: .rounded).weight(.heavy))
                            Text(choice.coins.map { "🪙 \($0)" } ?? "🪙 \(customWager)")
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .opacity(0.8)
                        }
                        .foregroundStyle(wagerChoice == choice ? Palette.ink : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(wagerChoice == choice ? Palette.accent : .white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            if wagerChoice == .custom {
                Stepper(value: $customWager, in: 50...10000, step: 50) {
                    Text("🪙 \(customWager)")
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            if !canAfford {
                Text("You've got 🪙 \(app.coins) — pick a smaller wager.")
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .foregroundStyle(Palette.danger)
            }
            Text("Winner takes the pot after 3 holes. Bonuses for birdies, clutch putts and the longest drive.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(14)
        .card()
    }

    private func startMatch() {
        let emojis = ["🏌️", "🧢", "😎", "🦩"]
        let players = names.enumerated().map { i, name in
            Player(name: name.isEmpty ? "Player \(i + 1)" : name, emoji: emojis[i],
                   character: characters[i])
        }
        let teams = [
            Team(name: "\(players[0].name) & \(players[1].name)",
                 players: [players[0], players[1]], colorHex: 0x4F9BE0),
            Team(name: "\(players[2].name) & \(players[3].name)",
                 players: [players[2], players[3]], colorHex: 0xF0705E)
        ]
        activeMatch = MatchConfig(teams: teams, wager: wagerAmount, holes: Hole.course)
    }
}

/// Grid of every golfer in the roster.
struct CharacterPicker: View {
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Pick your golfer")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundStyle(.white)
                .padding(.top, 16)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(GolferRig.characters, id: \.self) { c in
                        Button {
                            selected = c
                            dismiss()
                        } label: {
                            Group {
                                if let img = CharacterPortrait.image(for: c) {
                                    Image(uiImage: img).resizable().scaledToFit()
                                } else {
                                    Image(systemName: "figure.golf")
                                }
                            }
                            .frame(height: 74)
                            .frame(maxWidth: .infinity)
                            .background(.white.opacity(selected == c ? 0.2 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .stroke(selected == c ? Palette.accent : .clear, lineWidth: 2))
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Palette.deep.ignoresSafeArea())
    }
}
