import Foundation
import CoreGraphics

struct Player: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var emoji: String
}

struct Team: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var players: [Player]
    var colorHex: UInt32
}

struct MatchConfig: Identifiable {
    let id = UUID()
    let teams: [Team]
    let wager: Int
    let hole: Hole
}

enum Club: String, CaseIterable, Equatable {
    case driver = "Driver"
    case iron = "Iron"
    case wedge = "Wedge"
    case putter = "Putter"

    var maxYards: Double {
        switch self {
        case .driver: return 290
        case .iron: return 185
        case .wedge: return 65
        case .putter: return 40
        }
    }

    /// How far a full mishit curves offline, in yards.
    var curveYards: Double {
        switch self {
        case .driver: return 55
        case .iron: return 32
        case .wedge: return 10
        case .putter: return 0
        }
    }

    var apexScale: CGFloat {
        switch self {
        case .driver: return 1.6
        case .iron: return 1.45
        case .wedge: return 1.25
        case .putter: return 1.0
        }
    }

    var emoji: String {
        switch self {
        case .driver: return "🏌️"
        case .iron: return "⛳️"
        case .wedge: return "🪁"
        case .putter: return "🥅"
        }
    }
}

enum Lie: Equatable {
    case tee, fairway, rough, bunker, water, trees, fringe, green

    var label: String {
        switch self {
        case .tee: return "Tee"
        case .fairway: return "Fairway"
        case .rough: return "Rough"
        case .bunker: return "Bunker"
        case .water: return "Water"
        case .trees: return "Trees"
        case .fringe: return "Fringe"
        case .green: return "Green"
        }
    }

    var emoji: String {
        switch self {
        case .tee: return "🏌️"
        case .fairway: return "🟩"
        case .rough: return "🌿"
        case .bunker: return "🏖️"
        case .water: return "🌊"
        case .trees: return "🌲"
        case .fringe: return "🌱"
        case .green: return "⛳️"
        }
    }

    /// Distance multiplier applied to shots hit from this lie.
    var distanceFactor: Double {
        switch self {
        case .tee, .fairway, .green: return 1.0
        case .fringe: return 0.95
        case .rough: return 0.85
        case .bunker: return 0.7
        case .trees: return 0.55
        case .water: return 0
        }
    }
}

enum ShotKind: Equatable {
    case meter(Club)
    case chip
    case putt
}

struct Wind {
    /// Miles per hour, 0–14.
    let speed: Int
    /// Radians in scene coordinates — the direction the wind blows TOWARD.
    /// (+x is right, +y is toward the pin.)
    let angle: Double

    var vector: CGVector { CGVector(dx: cos(angle), dy: sin(angle)) }

    static func random() -> Wind {
        Wind(speed: Int.random(in: 0...14), angle: Double.random(in: 0..<(2 * .pi)))
    }
}

struct ShotOutcome: Identifiable {
    let id = UUID()
    let playerName: String
    let teamIndex: Int
    let kind: ShotKind
    let ratingLine: String
    let endPoint: CGPoint
    let lie: Lie
    let distanceToPinYards: Double
    let holed: Bool
    let penalty: Bool
    let dropPoint: CGPoint?
    let message: String
}

struct Bonus: Identifiable {
    let id = UUID()
    let label: String
    let amount: Int
}

struct HoleSummary {
    let par: Int
    let teamNames: [String]
    let strokes: [Int]
    let winner: Int?          // nil = push
    let pot: Int
    let userDelta: Int        // wager result for the local player
    let bonuses: [Bonus]
    let chatLine: String

    var userTotal: Int { userDelta + bonuses.reduce(0) { $0 + $1.amount } }
}
