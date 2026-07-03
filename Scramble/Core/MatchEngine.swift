import Foundation
import CoreGraphics

enum GamePhase: Equatable {
    case aiming        // waiting for the player to swing / flick
    case ballInMotion
    case shotResult    // banner up, waiting for Continue / Share
    case pickBall      // both teammates have hit — choose the best ball
    case holeComplete
}

/// Drives one hole of 2v2 scramble: each teammate hits from the team spot,
/// the team picks the best ball, both hit again from there. Teams alternate
/// strokes. Lowest team score wins the pot.
/// v0.2: sync this state through Supabase realtime for cross-device play.
final class MatchEngine: ObservableObject {
    let hole: Hole
    let teams: [Team]
    let wager: Int
    let wind: Wind

    @Published var phase: GamePhase = .aiming
    @Published var activeTeam = 0
    @Published var shooter = 0                 // 0 or 1 within the team
    @Published var roundShots: [ShotOutcome] = []
    @Published var teamSpot: [CGPoint]
    @Published var teamLie: [Lie]
    @Published var strokes: [Int] = [0, 0]
    @Published var holedOut: [Bool] = [false, false]
    @Published var lastOutcome: ShotOutcome?
    @Published var summary: HoleSummary?

    private var puttCount = [0, 0]
    private var pendingPuttStartFt = 0
    private var userLongestDrive = 0.0
    private var rivalLongestDrive = 0.0
    private var userClutchPutt = false
    private let maxStrokes = 8

    /// The local player is always the first player on team 0.
    var userPlayerID: UUID { teams[0].players[0].id }

    init(config: MatchConfig) {
        hole = config.hole
        teams = config.teams
        wager = config.wager
        wind = Wind.random()
        teamSpot = [config.hole.tee, config.hole.tee]
        teamLie = [.tee, .tee]
    }

    // MARK: - Current turn info

    var currentTeam: Team { teams[activeTeam] }
    var currentPlayer: Player { teams[activeTeam].players[shooter] }
    var currentSpot: CGPoint { teamSpot[activeTeam] }
    var currentLie: Lie { teamLie[activeTeam] }

    var distanceToPinYards: Double { hole.distanceToPinYards(from: currentSpot) }
    var distanceToPinFeet: Int { Int(distanceToPinYards * 3) }

    var currentKind: ShotKind {
        let dist = distanceToPinYards
        if currentLie == .green { return .putt }
        if dist <= 60 { return .chip }
        if dist > 210 && (currentLie == .tee || currentLie == .fairway) {
            return .meter(.driver)
        }
        return .meter(.iron)
    }

    var aimDirection: CGVector {
        CGVector(from: currentSpot, to: hole.pin).normalized
    }

    // MARK: - Shot resolution

    func beginShot() {
        pendingPuttStartFt = distanceToPinFeet
        phase = .ballInMotion
    }

    /// Called when a meter shot or chip finishes its flight animation.
    /// `samples` are points along the flight path, used to find where a
    /// water ball crossed the bank so we can place the drop.
    func resolveLanding(kind: ShotKind, result: ShotResult, end: CGPoint,
                        samples: [CGPoint]) {
        var lie = hole.lie(at: end)
        var penalty = false
        var drop: CGPoint? = nil

        if lie == .water {
            penalty = true
            drop = dropPoint(entryNear: end, along: samples)
        }

        // A chip that finishes in the cup is a chip-in; a full shot that
        // lands dead on the pin holes out too. Rare, glorious.
        let holed = lie != .water && end.distance(to: hole.pin) <= hole.cupRadius
        if holed { lie = .green }

        let distYds = hole.distanceToPinYards(from: end)
        let message: String
        let ratingLine: String
        switch kind {
        case .meter(let club):
            message = TrashTalk.meterShot(player: playerName(), result: result,
                                          lie: lie, holeNumber: hole.number)
            // Golf Dreams-style swing feedback: carry + swing speed.
            let mph = Int(Double(result.powerPct) / 100
                          * (club == .driver ? 122 : 96))
            ratingLine = "\(result.rating.rawValue) • \(Int(result.carryYards)) YDS • \(mph) MPH"
            trackDrive(club: club, yards: result.carryYards)
        case .chip:
            message = holed
                ? "\(playerName()) CHIPPED IN. Are you kidding me?! 🏌️‍♂️🔥"
                : TrashTalk.chipShot(player: playerName(), result: result,
                                     lie: lie, distanceToPinFt: Int(distYds * 3))
            ratingLine = "\(result.rating.rawValue) • \(Int(result.carryYards)) YDS"
        case .putt:
            message = ""
            ratingLine = ""
        }

        let outcome = ShotOutcome(
            playerName: playerName(),
            teamIndex: activeTeam,
            kind: kind,
            ratingLine: ratingLine,
            endPoint: end,
            lie: lie,
            distanceToPinYards: distYds,
            holed: holed,
            penalty: penalty,
            dropPoint: drop,
            message: message
        )
        finish(outcome, rating: result.rating, water: penalty)
    }

    func resolvePutt(holed: Bool, end: CGPoint) {
        puttCount[activeTeam] += 1
        let startFt = pendingPuttStartFt
        let remainingFt = Int(hole.distanceToPinYards(from: end) * 3)

        var scoreNameIfHoled: String? = nil
        if holed {
            scoreNameIfHoled = TrashTalk.scoreName(strokes[activeTeam] + 1 - hole.par)
            if startFt >= 20 && currentPlayer.id == userPlayerID {
                userClutchPutt = true
            }
        }

        let message = holed
            ? TrashTalk.puttHoled(player: playerName(), startFt: startFt,
                                  scoreName: scoreNameIfHoled)
            : TrashTalk.puttMissed(player: playerName(), startFt: startFt,
                                   remainingFt: remainingFt,
                                   puttNumber: puttCount[activeTeam])

        let outcome = ShotOutcome(
            playerName: playerName(),
            teamIndex: activeTeam,
            kind: .putt,
            ratingLine: holed ? "SUNK FROM \(startFt) FT" : "\(remainingFt) FT LEFT",
            endPoint: holed ? hole.pin : end,
            lie: .green,
            distanceToPinYards: holed ? 0 : Double(remainingFt) / 3,
            holed: holed,
            penalty: false,
            dropPoint: nil,
            message: message
        )
        finish(outcome, rating: holed ? .perfect : .miss, water: false)
    }

    private func finish(_ outcome: ShotOutcome, rating: ShotRating, water: Bool) {
        roundShots.append(outcome)
        lastOutcome = outcome
        phase = .shotResult

        if water || rating == .terrible || rating == .bad {
            Haptics.rumble()
        } else if outcome.holed {
            Haptics.celebration()
        } else if rating == .perfect {
            Haptics.pure()
        }
    }

    // MARK: - Turn flow

    /// Advance after the result banner is dismissed.
    func advanceAfterResult() {
        guard let last = lastOutcome else { return }

        if last.holed {
            strokes[activeTeam] += 1
            holedOut[activeTeam] = true
            roundShots = []
            shooter = 0
            nextTeamOrFinish()
            return
        }

        if shooter == 0 {
            shooter = 1
            phase = .aiming
        } else {
            phase = .pickBall
        }
    }

    /// The team picks which of the two balls to play from.
    func pick(_ outcome: ShotOutcome) {
        strokes[activeTeam] += 1 + (outcome.penalty ? 1 : 0)
        if outcome.penalty, let drop = outcome.dropPoint {
            teamSpot[activeTeam] = drop
            teamLie[activeTeam] = hole.lie(at: drop)
        } else {
            teamSpot[activeTeam] = outcome.endPoint
            teamLie[activeTeam] = outcome.lie
        }
        if teamLie[activeTeam] != .green { puttCount[activeTeam] = 0 }
        roundShots = []
        shooter = 0

        if strokes[activeTeam] >= maxStrokes {
            holedOut[activeTeam] = true    // mercy rule: pick up at 8
        }
        nextTeamOrFinish()
    }

    /// Default recommendation: closest to the pin, water balls last.
    func recommendedBall() -> ShotOutcome? {
        roundShots.min { a, b in
            let aDist = a.penalty ? a.distanceToPinYards + 1000 : a.distanceToPinYards
            let bDist = b.penalty ? b.distanceToPinYards + 1000 : b.distanceToPinYards
            return aDist < bDist
        }
    }

    private func nextTeamOrFinish() {
        if holedOut[0] && holedOut[1] {
            settle()
            return
        }
        let other = 1 - activeTeam
        if !holedOut[other] { activeTeam = other }
        phase = .aiming
    }

    // MARK: - Settlement

    private func settle() {
        let winner: Int?
        if strokes[0] == strokes[1] { winner = nil }
        else { winner = strokes[0] < strokes[1] ? 0 : 1 }

        let pot = wager * 2
        var userDelta = 0
        var bonuses: [Bonus] = []

        if let w = winner {
            userDelta = w == 0 ? wager : -wager
        }

        // Coin bonuses land on the local player (team 0, player 0).
        if winner == 0 {
            bonuses.append(Bonus(label: "Match win", amount: 500))
        }
        let teamScore = strokes[0] - hole.par
        if teamScore == -1 { bonuses.append(Bonus(label: "Birdie", amount: 50)) }
        if teamScore <= -2 { bonuses.append(Bonus(label: "Eagle", amount: 150)) }
        if userClutchPutt {
            bonuses.append(Bonus(label: "Clutch putt (20ft+)", amount: 75))
        }
        if userLongestDrive > 0 && userLongestDrive >= rivalLongestDrive {
            bonuses.append(Bonus(label: "Longest drive (\(Int(userLongestDrive)) yds)",
                                 amount: 100))
        }

        let winnerName = winner.map { teams[$0].name }
        summary = HoleSummary(
            par: hole.par,
            teamNames: teams.map(\.name),
            strokes: strokes,
            winner: winner,
            pot: pot,
            userDelta: userDelta,
            bonuses: bonuses,
            chatLine: TrashTalk.holeResult(winner: winnerName, strokes: strokes,
                                           teamNames: teams.map(\.name),
                                           pot: pot, par: hole.par)
        )
        phase = .holeComplete
    }

    // MARK: - Helpers

    private func playerName() -> String { currentPlayer.name }

    private func trackDrive(club: Club, yards: Double) {
        guard club == .driver else { return }
        if currentPlayer.id == userPlayerID {
            userLongestDrive = max(userLongestDrive, yards)
        } else {
            rivalLongestDrive = max(rivalLongestDrive, yards)
        }
    }

    /// Walk the flight path backwards from the splash to find dry land,
    /// then drop the ball a touch further back.
    private func dropPoint(entryNear end: CGPoint, along samples: [CGPoint]) -> CGPoint {
        for p in samples.reversed() where hole.lie(at: p) != .water {
            let back = CGVector(from: end, to: p).normalized
            var drop = p + back * 22
            var attempts = 0
            while hole.lie(at: drop) == .water && attempts < 6 {
                drop = drop + back * 22
                attempts += 1
            }
            return drop
        }
        return currentSpot
    }
}
