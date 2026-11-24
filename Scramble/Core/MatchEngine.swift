import Foundation
import CoreGraphics

enum GamePhase: Equatable {
    case holeIntro     // flyover + hole card
    case aiming        // waiting for the player to swing
    case ballInMotion
    case shotResult    // result card up, waiting for Continue
    case pickBall      // both teammates have hit — choose the best ball
    case holeComplete  // scorecard between holes
    case matchComplete // final settlement
}

/// Drives a 3-hole 2v2 scramble: each teammate hits from the team spot,
/// the team picks the best ball, both hit again from there. The team
/// farthest from the hole plays next. Lowest total after three holes wins
/// the pot.
///
/// The engine is pure game state (no rendering) so the iMessage version
/// can serialize it and pass it between phones.
final class MatchEngine: ObservableObject {
    let holes: [Hole]
    let teams: [Team]
    let wager: Int

    @Published var holeIndex = 0
    @Published var wind: Wind
    @Published var phase: GamePhase = .holeIntro
    @Published var activeTeam = 0
    @Published var shooter = 0                 // 0 or 1 within the team
    @Published var roundShots: [ShotOutcome] = []
    @Published var teamSpot: [CGPoint]
    @Published var teamLie: [Lie]
    @Published var strokes: [Int] = [0, 0]
    @Published var holedOut: [Bool] = [false, false]
    @Published var lastOutcome: ShotOutcome?
    /// scorecard[team][hole] — nil until that hole is finished.
    @Published var scorecard: [[Int?]]
    @Published var summary: MatchSummary?
    /// Player's club choice for this shot (nil = play the caddie's pick).
    @Published var clubOverride: Club?

    private var puttCount = [0, 0]
    private var userLongestDrive = 0.0
    private var rivalLongestDrive = 0.0
    private var userClutchPutts = 0
    private var holeBonuses: [Bonus] = []

    /// The local player is always the first player on team 0.
    var userPlayerID: UUID { teams[0].players[0].id }

    init(config: MatchConfig) {
        holes = config.holes
        teams = config.teams
        wager = config.wager
        wind = Wind.random()
        let first = config.holes[0]
        teamSpot = [first.tee, first.tee]
        teamLie = [.tee, .tee]
        scorecard = Array(repeating: Array(repeating: nil, count: config.holes.count),
                          count: 2)
    }

    // MARK: - Current turn info

    var hole: Hole { holes[holeIndex] }
    var isLastHole: Bool { holeIndex == holes.count - 1 }
    var currentTeam: Team { teams[activeTeam] }
    var currentPlayer: Player { teams[activeTeam].players[shooter] }
    var currentSpot: CGPoint { teamSpot[activeTeam] }
    var currentLie: Lie { teamLie[activeTeam] }
    var maxStrokes: Int { hole.par + 4 }

    var distanceToPinYards: Double { hole.distanceToPinYards(from: currentSpot) }
    var distanceToPinFeet: Int { Int(distanceToPinYards * 3) }

    /// Running total for a team including the hole in progress.
    func total(team: Int) -> Int {
        var sum = 0
        for (i, s) in scorecard[team].enumerated() {
            if let s { sum += s } else if i == holeIndex { sum += strokes[team] }
        }
        return sum
    }

    func parThrough(holes count: Int) -> Int {
        holes.prefix(count).reduce(0) { $0 + $1.par }
    }

    /// Caddie suggestion: shortest club that still reaches, given the lie.
    var suggestedClub: Club {
        if currentLie == .green { return .putter }
        let d = distanceToPinYards
        if currentLie == .fringe && d <= 20 { return .putter }
        if d <= 50 { return .sandWedge }
        let needed = d / max(currentLie.distanceFactor, 0.4)
        for club in Club.bag.reversed() where club.maxYards >= needed * 0.97 {
            return club
        }
        return .driver
    }

    /// Texas wedge: putter is allowed off the green from clean short lies.
    var putterAllowed: Bool {
        currentLie == .green
            || ((currentLie == .fringe || currentLie == .fairway)
                && distanceToPinYards <= 40)
    }

    var currentClub: Club {
        if currentLie == .green { return .putter }
        if let pick = clubOverride {
            if pick == .putter { return putterAllowed ? .putter : suggestedClub }
            return pick
        }
        return suggestedClub
    }

    var currentKind: ShotKind {
        switch currentClub {
        case .putter: return .putt
        case .sandWedge where distanceToPinYards <= 50: return .chip
        default: return .meter(currentClub)
        }
    }

    /// Default aim: the pin if this club gets there, otherwise down the
    /// fairway to where it lands.
    var aimDirection: CGVector {
        let target: CGPoint
        switch currentKind {
        case .putt, .chip: target = hole.pin
        case .meter(let club):
            target = hole.target(from: currentSpot,
                                 carryYards: club.maxYards * currentLie.distanceFactor)
        }
        return CGVector(from: currentSpot, to: target).normalized
    }

    // MARK: - Shot resolution

    func beginShot() {
        phase = .ballInMotion
    }

    /// Resolve any shot from its simulated trajectory.
    func resolve(kind: ShotKind, result: ShotResult?, trajectory tr: BallPhysics.Trajectory,
                 from start: CGPoint) {
        let holed = tr.finish == .holed
        let water = tr.finish == .water
        var lie: Lie = holed ? .green : hole.lie(at: tr.end)
        if water { lie = .water }
        let drop = water ? dropPoint(entry: tr.waterEntry ?? tr.end, along: tr.path, start: start) : nil
        let distYds = holed ? 0 : hole.distanceToPinYards(from: tr.end)
        let carryYds = tr.landing.map { Double($0.distance(to: start) / Hole.pointsPerYard) }
        let name = currentPlayer.name

        var message = ""
        var ratingLine = ""
        var rating: ShotRating = .good

        switch kind {
        case .meter(let club):
            guard let r = result else { break }
            rating = r.rating
            let shown = ShotResult(club: r.club, powerPct: r.powerPct, accuracyPct: r.accuracyPct,
                                   rating: r.rating, flavor: r.flavor,
                                   carryYards: carryYds ?? r.carryYards,
                                   lateralYards: r.lateralYards)
            message = holed
                ? "\(name) HOLED IT FROM \(Int(hole.distanceToPinYards(from: start))) YARDS. Call the newspaper. 🦅"
                : TrashTalk.meterShot(player: name, result: shown, lie: lie,
                                      holeNumber: hole.number)
            let mph = Int(Double(r.powerPct) / 100 * club.swingMPH)
            ratingLine = "\(r.rating.rawValue) · \(Int(carryYds ?? r.carryYards)) YD CARRY · \(mph) MPH"
            trackDrive(club: club, yards: carryYds ?? 0, start: start)
        case .chip:
            guard let r = result else { break }
            rating = r.rating
            message = holed
                ? "\(name) CHIPPED IN. Are you kidding me?! 🏌️‍♂️🔥"
                : TrashTalk.chipShot(player: name, result: r, lie: lie,
                                     distanceToPinFt: Int(distYds * 3))
            ratingLine = r.flavor == .chunk ? "CHUNKED IT" : "\(Int(carryYds ?? r.carryYards)) YD CHIP"
        case .putt:
            puttCount[activeTeam] += 1
            let startFt = Int(hole.distanceToPinYards(from: start) * 3)
            let remainingFt = Int(distYds * 3)
            if holed {
                if startFt >= 20 && currentPlayer.id == userPlayerID { userClutchPutts += 1 }
                message = TrashTalk.puttHoled(
                    player: name, startFt: startFt,
                    scoreName: TrashTalk.scoreName(strokes[activeTeam] + 1 - hole.par))
                ratingLine = "DRAINED FROM \(startFt) FT"
                rating = .perfect
            } else {
                message = TrashTalk.puttMissed(player: name, startFt: startFt,
                                               remainingFt: remainingFt,
                                               puttNumber: puttCount[activeTeam])
                ratingLine = tr.events.contains(where: { $0.event == .lipOut })
                    ? "LIPPED OUT · \(remainingFt) FT LEFT"
                    : "\(remainingFt) FT LEFT"
                rating = .miss
            }
        }

        if water {
            message = "\(name) found the water. Bring a snorkel. 🌊"
            ratingLine = "WET · +1 PENALTY"
        }

        let outcome = ShotOutcome(
            playerName: name,
            teamIndex: activeTeam,
            kind: kind,
            ratingLine: ratingLine,
            endPoint: holed ? hole.pin : tr.end,
            lie: lie,
            distanceToPinYards: distYds,
            holed: holed,
            penalty: water,
            dropPoint: drop,
            message: message
        )
        roundShots.append(outcome)
        lastOutcome = outcome
        phase = .shotResult

        if water || rating == .terrible || rating == .bad {
            Haptics.rumble()
        } else if holed {
            Haptics.celebration()
        } else if rating == .perfect {
            Haptics.pure()
        }
    }

    // MARK: - Turn flow

    /// Advance after the result card is dismissed.
    func advanceAfterResult() {
        guard let last = lastOutcome else { return }
        clubOverride = nil

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
        clubOverride = nil
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
            holedOut[activeTeam] = true    // mercy rule: pick up
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
            finishHole()
            return
        }
        // Farthest from the hole plays (golf etiquette).
        let other = 1 - activeTeam
        if holedOut[activeTeam] {
            activeTeam = other
        } else if !holedOut[other] {
            let mine = hole.pin.distance(to: teamSpot[activeTeam])
            let theirs = hole.pin.distance(to: teamSpot[other])
            if theirs >= mine { activeTeam = other }
        }
        phase = .aiming
    }

    private func finishHole() {
        for t in 0..<2 { scorecard[t][holeIndex] = strokes[t] }
        let rel = strokes[0] - hole.par
        if rel == -1 { holeBonuses.append(Bonus(label: "Birdie on \(hole.number)", amount: 50)) }
        if rel <= -2 { holeBonuses.append(Bonus(label: "Eagle on \(hole.number)", amount: 150)) }
        if isLastHole {
            settle()
        } else {
            phase = .holeComplete
        }
    }

    /// Move to the next hole. Honors: the team that won the last hole
    /// tees off first.
    func startNextHole() {
        guard !isLastHole else { return }
        let prev = strokes
        holeIndex += 1
        wind = Wind.random()
        teamSpot = [hole.tee, hole.tee]
        teamLie = [.tee, .tee]
        strokes = [0, 0]
        holedOut = [false, false]
        puttCount = [0, 0]
        roundShots = []
        shooter = 0
        clubOverride = nil
        lastOutcome = nil
        if prev[0] != prev[1] { activeTeam = prev[0] < prev[1] ? 0 : 1 }
        phase = .holeIntro
    }

    func beginHole() {
        phase = .aiming
    }

    // MARK: - Settlement

    private func settle() {
        let totals = [total(team: 0), total(team: 1)]
        let winner: Int? = totals[0] == totals[1] ? nil : (totals[0] < totals[1] ? 0 : 1)
        let pot = wager * 2
        var bonuses = holeBonuses
        if winner == 0 { bonuses.append(Bonus(label: "Match win", amount: 500)) }
        if userClutchPutts > 0 {
            bonuses.append(Bonus(label: "Clutch putt (20ft+)", amount: 75 * userClutchPutts))
        }
        if userLongestDrive > 0 && userLongestDrive >= rivalLongestDrive {
            bonuses.append(Bonus(label: "Longest drive (\(Int(userLongestDrive)) yds)",
                                 amount: 100))
        }
        let userDelta = winner.map { $0 == 0 ? wager : -wager } ?? 0
        let par = parThrough(holes: holes.count)
        summary = MatchSummary(
            pars: holes.map(\.par),
            teamNames: teams.map(\.name),
            scorecard: scorecard.map { $0.map { $0 ?? 0 } },
            totals: totals,
            winner: winner,
            pot: pot,
            wager: wager,
            userDelta: userDelta,
            bonuses: bonuses,
            chatLine: TrashTalk.matchResult(winner: winner, totals: totals,
                                            teamNames: teams.map(\.name),
                                            pot: pot, par: par)
        )
        phase = .matchComplete
    }

    // MARK: - Helpers

    private func trackDrive(club: Club, yards: Double, start: CGPoint) {
        guard club == .driver, start.distance(to: hole.tee) < 30 else { return }
        if currentPlayer.id == userPlayerID {
            userLongestDrive = max(userLongestDrive, yards)
        } else if activeTeam == 1 {
            rivalLongestDrive = max(rivalLongestDrive, yards)
        }
    }

    /// Walk the flight path backwards from the splash to find dry land,
    /// then drop the ball a touch further back.
    private func dropPoint(entry: CGPoint, along path: [CGPoint], start: CGPoint) -> CGPoint {
        for p in path.reversed() where hole.lie(at: p) != .water && p.distance(to: entry) > 4 {
            let back = CGVector(from: entry, to: p).normalized
            var drop = p + back * 10
            var attempts = 0
            while hole.lie(at: drop) == .water && attempts < 10 {
                drop = drop + back * 10
                attempts += 1
            }
            return drop
        }
        return start
    }
}
