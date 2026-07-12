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

/// The bag — Golf Dreams style: you pick the club, each shows its carry,
/// and distance control comes from matching club + backswing to the shot.
enum Club: String, CaseIterable, Equatable {
    case driver = "Driver"
    case wood3 = "3 Wood"
    case iron5 = "5 Iron"
    case iron7 = "7 Iron"
    case iron9 = "9 Iron"
    case pitchWedge = "Pitch Wedge"
    case sandWedge = "Sand Wedge"
    case putter = "Putter"

    /// Full-swing clubs, longest first (the picker order).
    static let bag: [Club] = [.driver, .wood3, .iron5, .iron7, .iron9,
                              .pitchWedge, .sandWedge]

    /// Full-swing carry at 100% with a clean strike.
    var maxYards: Double {
        switch self {
        case .driver: return 265
        case .wood3: return 235
        case .iron5: return 195
        case .iron7: return 165
        case .iron9: return 135
        case .pitchWedge: return 105
        case .sandWedge: return 70
        case .putter: return 40
        }
    }

    /// How far a full mishit curves offline, in yards.
    var curveYards: Double {
        switch self {
        case .driver: return 55
        case .wood3: return 45
        case .iron5: return 34
        case .iron7: return 26
        case .iron9: return 18
        case .pitchWedge: return 12
        case .sandWedge: return 8
        case .putter: return 0
        }
    }

    var apexScale: CGFloat {
        switch self {
        case .driver: return 1.6
        case .wood3: return 1.5
        case .iron5: return 1.45
        case .iron7: return 1.4
        case .iron9: return 1.38
        case .pitchWedge: return 1.32
        case .sandWedge: return 1.25
        case .putter: return 1.0
        }
    }

    /// Clean-strike swing speed at 100%, for the post-shot stat line.
    var swingMPH: Double {
        switch self {
        case .driver: return 118
        case .wood3: return 112
        case .iron5: return 102
        case .iron7: return 96
        case .iron9: return 90
        case .pitchWedge: return 86
        case .sandWedge: return 82
        case .putter: return 0
        }
    }

    var shortLabel: String {
        switch self {
        case .driver: return "DR"
        case .wood3: return "3W"
        case .iron5: return "5I"
        case .iron7: return "7I"
        case .iron9: return "9I"
        case .pitchWedge: return "PW"
        case .sandWedge: return "SW"
        case .putter: return "PT"
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
