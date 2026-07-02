import Foundation

/// Auto-generated group chat messages. Every shot produces one; the share
/// sheet pre-populates with it so it can be pasted into any group chat.
enum TrashTalk {

    static func meterShot(player: String, result: ShotResult, lie: Lie,
                          holeNumber: Int) -> String {
        let yds = Int(result.carryYards)
        if lie == .water {
            return pick([
                "\(player) donated their ball to the fish on hole \(holeNumber) 🐟",
                "\(player) found the water. The fish send their thanks.",
                "SPLASH. \(player)'s ball is sleeping with the fishes."
            ])
        }
        switch result.flavor {
        case .pure:
            return pick([
                "\(player) absolutely nuked it \(yds) yards straight down the middle 💣",
                "\(player) just hit the shot of their life. \(yds) yards. Frame it.",
                "FLUSHED. \(player) sends one \(yds) yards down the pipe."
            ])
        case .fade, .draw:
            return pick([
                "\(player) hits a buttery \(result.flavor == .draw ? "draw" : "fade"), \(yds) yards. Respectable.",
                "\(player) shapes one out there \(yds) yards. The lessons are paying off."
            ])
        case .hook, .bigHook:
            return pick([
                "\(player) introduced their ball to some very confused squirrels in the trees 🐿️",
                "\(player) snap-hooked it into another zip code.",
                "\(player)'s ball hung a HARD left. It's not coming back."
            ])
        case .slice, .bigSlice:
            return pick([
                "\(player) sliced it so hard it needs a passport 🛂",
                "\(player)'s ball is currently trespassing on the neighboring property.",
                "That slice from \(player) had its own weather system."
            ])
        case .topped:
            return pick([
                "\(player) topped it \(yds) yards. The tee had a better flight.",
                "\(player) just hit a screaming worm burner. The worms are furious."
            ])
        case .fat, .chunk:
            return pick([
                "\(player) hit the earth first. The earth won. \(yds) yards.",
                "\(player) took a divot the size of a small dog and moved it \(yds) yards."
            ])
        case .clean:
            return "\(player) puts it out there \(yds) yards."
        }
    }

    static func chipShot(player: String, result: ShotResult, lie: Lie,
                         distanceToPinFt: Int) -> String {
        if lie == .water {
            return "\(player) chipped it into the water. From THERE. 🌊"
        }
        switch result.flavor {
        case .chunk, .fat:
            return pick([
                "\(player) chunked a chip. It moved 6 feet. Devastating.",
                "\(player) just laid the sod over it. Chip of shame."
            ])
        default:
            if lie == .green && distanceToPinFt <= 4 {
                return "\(player) drops a chip stone dead. Tap-in territory. 🎯"
            }
            if lie == .green {
                return "\(player) chips on, \(distanceToPinFt) feet left."
            }
            return "\(player) chips it to the \(lie.label.lowercased()). Adventure golf."
        }
    }

    static func puttHoled(player: String, startFt: Int, scoreName: String?) -> String {
        if startFt >= 20 {
            return pick([
                "\(player) DRAINED A \(startFt)-FOOT BOMB 💣💣💣 The group chat goes silent.",
                "\(player) buried it from \(startFt) feet. Absolutely disgusting.",
                "\(startFt) FEET. CENTER CUP. \(player) is him."
            ])
        }
        if let score = scoreName {
            switch score {
            case "Eagle": return "\(player) made an EAGLE. The group chat goes silent. 🦅"
            case "Birdie": return "\(player) rolls in the birdie putt. Money. 🐦"
            default: break
            }
        }
        return "\(player) cleans it up from \(max(startFt, 1)) feet."
    }

    static func puttMissed(player: String, startFt: Int, remainingFt: Int,
                           puttNumber: Int) -> String {
        if puttNumber >= 3 && startFt <= 5 {
            return "\(player) just 3-putted from \(startFt) feet. Career defining. 🤡"
        }
        if startFt <= 5 {
            return pick([
                "\(player) MISSED FROM \(startFt) FEET. I can't watch. 💀",
                "\(player) lipped out a gimme. Someone check on them."
            ])
        }
        if remainingFt <= 2 {
            return "\(player) lags it close from \(startFt) feet. Tap-in left."
        }
        return pick([
            "\(player) leaves the putt \(remainingFt) feet short-side. Yikes.",
            "\(player) sends it \(remainingFt) feet past. Aggressive. Very aggressive."
        ])
    }

    static func holeResult(winner: String?, strokes: [Int], teamNames: [String],
                           pot: Int, par: Int) -> String {
        guard let winner else {
            return "Hole halved at \(strokes[0]) apiece. Nobody gets paid. Boring."
        }
        let winIdx = teamNames.firstIndex(of: winner) ?? 0
        let score = strokes[winIdx] - par
        let scoreText = scoreName(score).map { " with a \($0.lowercased())" } ?? ""
        return "\(winner) takes the hole\(scoreText) and \(pot) coins 💰 Pay up."
    }

    static func scoreName(_ relativeToPar: Int) -> String? {
        switch relativeToPar {
        case ...(-3): return "Albatross"
        case -2: return "Eagle"
        case -1: return "Birdie"
        case 0: return "Par"
        case 1: return "Bogey"
        case 2: return "Double Bogey"
        default: return nil
        }
    }

    private static func pick(_ options: [String]) -> String {
        options.randomElement() ?? options[0]
    }
}
