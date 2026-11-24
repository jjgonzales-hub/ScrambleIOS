import SwiftUI

@main
struct ScrambleApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                // "-demoHole" jumps straight onto the tee — used for quick
                // simulator checks without tapping through setup.
                if CommandLine.arguments.contains("-demoHole") {
                    GameView(config: .demo(), demo: true) { }
                } else {
                    HomeView()
                }
            }
            .environmentObject(app)
            .preferredColorScheme(.dark)
            .tint(Palette.accent)
        }
    }
}

extension MatchConfig {
    static func demo() -> MatchConfig {
        let players = [Player(name: "You", emoji: "🏌️", character: "male_a"),
                       Player(name: "Sam", emoji: "🧢", character: "female_b"),
                       Player(name: "Jake", emoji: "😎", character: "male_e"),
                       Player(name: "Riley", emoji: "🦩", character: "female_d")]
        let args = CommandLine.arguments
        let start = args.firstIndex(of: "-demoHoleIndex").flatMap { i in
            i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 0
        let holes = Array(Hole.course.dropFirst(min(start, Hole.course.count - 1)))
        return MatchConfig(
            teams: [Team(name: "You & Sam", players: [players[0], players[1]],
                         colorHex: 0x4F9BE0),
                    Team(name: "Jake & Riley", players: [players[2], players[3]],
                         colorHex: 0xF0705E)],
            wager: 100,
            holes: holes
        )
    }
}

/// Global app state — coin bank persists across launches.
/// v0.2: replace with Supabase-backed profile (coins, stats, head-to-head).
final class AppState: ObservableObject {
    @Published var coins: Int {
        didSet { UserDefaults.standard.set(coins, forKey: "coins") }
    }

    init() {
        if UserDefaults.standard.object(forKey: "coins") == nil {
            coins = 1000
        } else {
            coins = UserDefaults.standard.integer(forKey: "coins")
        }
    }

    /// The wager was escrowed when the match started: give it back, then
    /// apply the net result and bonuses.
    func settle(_ summary: MatchSummary) {
        coins = max(0, coins + summary.wager + summary.userTotal)
    }
}
