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
                    GameView(config: .demo()) { }
                } else {
                    HomeView()
                }
            }
            .environmentObject(app)
            .preferredColorScheme(.dark)
        }
    }
}

extension MatchConfig {
    static func demo() -> MatchConfig {
        let players = [Player(name: "You", emoji: "🏌️"),
                       Player(name: "Sam", emoji: "🧢"),
                       Player(name: "Jake", emoji: "😎"),
                       Player(name: "Riley", emoji: "🦩")]
        return MatchConfig(
            teams: [Team(name: "You & Sam", players: [players[0], players[1]],
                         colorHex: 0x6E97AC),
                    Team(name: "Jake & Riley", players: [players[2], players[3]],
                         colorHex: 0xB5533C)],
            wager: 100,
            hole: .one()
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

    func apply(_ summary: HoleSummary) {
        coins = max(0, coins + summary.userTotal)
    }
}
