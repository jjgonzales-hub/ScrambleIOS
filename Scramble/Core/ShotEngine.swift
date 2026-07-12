import Foundation
import CoreGraphics

enum ShotRating: String {
    case perfect = "PURE"
    case good = "GOOD"
    case miss = "MISS"
    case bad = "UGLY"
    case terrible = "DISASTER"

    init(accuracyPct: Int) {
        switch accuracyPct {
        case 95...: self = .perfect
        case 80...94: self = .good
        case 60...79: self = .miss
        case 40...59: self = .bad
        default: self = .terrible
        }
    }

    var distanceFactor: Double {
        switch self {
        case .perfect: return 1.0
        case .good: return 0.92
        case .miss: return 0.76
        case .bad: return 0.6
        case .terrible: return 0.3
        }
    }
}

enum ShotFlavor: Equatable {
    case pure, fade, draw, slice, hook, bigSlice, bigHook, topped, fat, chunk, clean
}

struct ShotResult {
    let club: Club
    let powerPct: Int
    let accuracyPct: Int
    let rating: ShotRating
    let flavor: ShotFlavor
    let carryYards: Double
    let lateralYards: Double   // + curves right, - curves left
}

enum ShotEngine {

    /// Two-tap meter shot (driver / iron).
    /// - power: 0–1 from the first tap
    /// - earlyLate: -1…1 from the second tap. Negative = early = hook/topped,
    ///   positive = late = slice/fat. 0 = dead center.
    /// - aim: unit vector toward the target in scene coords (for wind math)
    static func meterShot(club: Club, power: Double, earlyLate: Double,
                          wind: Wind, aim: CGVector) -> ShotResult {
        let accuracyPct = Int((1 - abs(earlyLate)) * 100)
        let rating = ShotRating(accuracyPct: accuracyPct)

        var carry = club.maxYards * power * rating.distanceFactor
        var lateral: Double = 0
        var flavor: ShotFlavor = .pure

        switch rating {
        case .terrible:
            // Topped (way early) skitters along the ground; fat (way late) goes nowhere.
            flavor = earlyLate < 0 ? .topped : .fat
            lateral = Double.random(in: -8...8)
        default:
            let curve = signed(earlyLate) * pow(abs(earlyLate), 1.2)
                * club.curveYards * (0.5 + power / 2)
            lateral = curve
            switch rating {
            case .perfect:
                flavor = .pure
                let perfectPower = power >= 0.96
                if perfectPower { carry *= 1.08 }   // flushed it — distance bonus
            case .good:
                flavor = earlyLate < 0 ? .draw : .fade
            case .miss:
                flavor = earlyLate < 0 ? .hook : .slice
            case .bad, .terrible:
                flavor = earlyLate < 0 ? .bigHook : .bigSlice
            }
        }

        // Wind: head/tail changes carry, crosswind pushes the ball offline.
        let aimU = aim.normalized
        let w = wind.vector
        let head = Double(w.dot(aimU))
        let cross = Double(w.dot(aimU.perpendicularRight))
        carry += head * Double(wind.speed) * 0.9 * (carry / club.maxYards)
        lateral += cross * Double(wind.speed) * 0.55 * (carry / 250)

        // Tiny natural variance so no two swings are identical.
        carry *= Double.random(in: 0.98...1.02)

        return ShotResult(
            club: club,
            powerPct: Int(power * 100),
            accuracyPct: accuracyPct,
            rating: rating,
            flavor: flavor,
            carryYards: max(carry, 4),
            lateralYards: lateral
        )
    }

    /// Flick chip. Direction comes from the pull vector; the engine adds
    /// distance noise and an angle error — plus a chance to chunk it when
    /// you swing out of your shoes.
    /// Returns carry in yards and an angle error in radians to rotate the aim.
    static func chip(power: Double) -> (result: ShotResult, angleError: Double) {
        var carry = Club.sandWedge.maxYards * power
        var flavor: ShotFlavor = .clean
        var accuracy = Int.random(in: 88...100)

        var angleError = Double.random(in: -0.045...0.045)
        carry *= Double.random(in: 0.93...1.07)

        if power > 0.92 && Double.random(in: 0...1) < 0.3 {
            // Chunked it. Painful, as requested.
            flavor = .chunk
            carry *= 0.35
            accuracy = Int.random(in: 10...35)
        } else if power < 0.12 {
            flavor = .fat
            accuracy = Int.random(in: 30...50)
        }

        let result = ShotResult(
            club: .sandWedge,
            powerPct: Int(power * 100),
            accuracyPct: accuracy,
            rating: ShotRating(accuracyPct: accuracy),
            flavor: flavor,
            carryYards: max(carry, 2),
            lateralYards: 0
        )
        return (result, angleError)
    }

    private static func signed(_ v: Double) -> Double { v < 0 ? -1 : 1 }
}
