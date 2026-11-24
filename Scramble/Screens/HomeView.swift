import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1C5A3B), Palette.deep],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        golfers
                        coinCard
                        NavigationLink { MatchSetupView() } label: { quickMatchCard }
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
                .font(.system(size: 46, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("2v2 golf for the group chat")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.top, 14)
    }

    private var golfers: some View {
        HStack(spacing: -14) {
            ForEach(["male_a", "female_b", "male_e", "female_d"], id: \.self) { c in
                if let img = CharacterPortrait.image(for: c) {
                    Image(uiImage: img).resizable().scaledToFit().frame(width: 96, height: 96)
                }
            }
        }
    }

    private var coinCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR BANK")
                    .font(.system(.caption, design: .rounded).weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.6))
                Text("🪙 \(app.coins)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            Spacer()
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title)
                .foregroundStyle(Palette.gold)
        }
        .padding(18)
        .card()
    }

    private var quickMatchCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK MATCH")
                    .font(.system(.title2, design: .rounded).weight(.black))
                Text("3 holes · 2v2 scramble · winner takes the pot")
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .opacity(0.75)
                    .multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "arrow.right.circle.fill").font(.largeTitle)
        }
        .foregroundStyle(Palette.ink)
        .padding(20)
        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 22))
    }

    private var comingSoonRow: some View {
        HStack(spacing: 12) {
            soonCard("tshirt.fill", "Locker")
            soonCard("chart.bar.fill", "Stats")
            soonCard("message.fill", "iMessage")
        }
    }

    private func soonCard(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white.opacity(0.8))
            Text(title)
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
            Text("SOON")
                .font(.system(.caption2, design: .rounded).weight(.heavy))
                .foregroundStyle(Palette.gold.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .card(radius: 18)
    }
}
