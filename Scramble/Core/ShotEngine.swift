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

    /// One-motion full swing (driver → wedge).
    /// - power: 0…~1.04 backswing power from the gesture (already exponential)
    /// - earlyLate: -1…1 face/path error from the swing's lateral drift.
    ///   Negative = closed (draw/hook), positive = open (fade/slice).
    /// Returns STILL-AIR carry and curve; wind is applied by the ball
    /// physics during the actual flight so you can watch it work.
    static func meterShot(club: Club, power: Double, earlyLate: Double) -> ShotResult {
        // Forgiving centre, steep edges: a small wobble still reads as a
        // clean strike, real drift costs you. (Exponent > 1 widens the
        // sweet spot — the previous 0.82 did the opposite of its comment.)
        let miss = min(max(abs(earlyLate), 0), 1)
        let accuracyPct = Int((1 - pow(miss, 1.35)) * 100)
        let rating = ShotRating(accuracyPct: accuracyPct)

        let swingSpeed = min(max(power, 0), 1.04)
        var carry = club.maxYards * swingSpeed * rating.distanceFactor
        var lateral: Double = 0
        var flavor: ShotFlavor = .pure

        switch rating {
        case .terrible:
            flavor = earlyLate < 0 ? .topped : .fat
            lateral = earlyLate * club.curveYards * 0.25
        default:
            lateral = earlyLate.sign == .minus ? -1 : 1
            lateral *= pow(miss, 1.5) * club.curveYards * (0.35 + swingSpeed * 0.65)
            switch rating {
            case .perfect:
                flavor = .pure
                if power >= 0.97 { carry *= 1.04 }   // flushed it
            case .good:
                flavor = earlyLate < 0 ? .draw : .fade
            case .miss:
                flavor = earlyLate < 0 ? .hook : .slice
            case .bad, .terrible:
                flavor = earlyLate < 0 ? .bigHook : .bigSlice
            }
        }

        carry *= Double.random(in: 0.992...1.008)

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

    /// Short-game chip with the sand wedge. Carry comes straight from the
    /// backswing (no randomness worth blaming); drift aims it. Swinging
    /// out of your shoes risks a chunk.
    static func chip(carryYards: Double, power: Double) -> ShotResult {
        var carry = carryYards * Double.random(in: 0.985...1.015)
        var flavor: ShotFlavor = .clean
        var accuracy = Int.random(in: 93...99)
        if power > 0.97 && Double.random(in: 0...1) < 0.15 {
            flavor = .chunk
            carry *= 0.4
            accuracy = Int.random(in: 10...35)
        }
        return ShotResult(
            club: .sandWedge,
            powerPct: Int(power * 100),
            accuracyPct: accuracy,
            rating: ShotRating(accuracyPct: accuracy),
            flavor: flavor,
            carryYards: max(carry, 1),
            lateralYards: 0
        )
    }
}
