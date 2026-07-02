import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ink.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        header
                        coinCard
                        NavigationLink {
                            MatchSetupView()
                        } label: {
                            quickMatchCard
                        }
                        comingSoonRow
                    }
                    .padding(18)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Palette.accent)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("SCRAMBLE")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(Palette.cream)
            Text("2v2 golf for the group chat")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Palette.cream.opacity(0.7))
        }
        .padding(.top, 10)
    }

    private var coinCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR BANK")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(Palette.cream.opacity(0.6))
                Text("🪙 \(app.coins)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(Palette.cream)
            }
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title)
                .foregroundStyle(Palette.accent)
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Palette.accent.opacity(0.5), lineWidth: 2)
        )
    }

    private var quickMatchCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("⛳️ QUICK MATCH")
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(Palette.ink)
                Text("2v2 scramble • pick your wager • winner takes the pot")
                    .font(.system(.footnote, design: .rounded).bold())
                    .foregroundStyle(Palette.ink.opacity(0.75))
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right.circle.fill")
                .font(.title)
                .foregroundStyle(Palette.ink)
        }
        .padding(20)
        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 22))
    }

    private var comingSoonRow: some View {
        HStack(spacing: 12) {
            soonCard("🛍️", "Shop")
            soonCard("📊", "Stats")
            soonCard("🔥", "Daily")
        }
    }

    private func soonCard(_ emoji: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Text(emoji).font(.title)
            Text(title)
                .font(.system(.footnote, design: .rounded).bold())
                .foregroundStyle(Palette.cream)
            Text("SOON")
                .font(.system(.caption2, design: .rounded).bold())
                .foregroundStyle(Palette.accent.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Palette.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
    }
}
