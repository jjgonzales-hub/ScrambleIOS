import SwiftUI

@main
struct ScrambleApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
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
