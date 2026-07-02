# ⛳️ Scramble

2v2 turn-based cartoon golf for the group chat. Real scramble rules — both
teammates hit, the team picks the best ball, both hit again from there.
Lowest score wins the pot, and every shot generates trash talk ready to
paste into the chat.

**This is v0.1 — the core game loop**, built to get the swing feel right
before anything else:

- 🏌️ **Two-tap swing meter** (MLB The Show style) for driver and iron —
  tap to lock power on the rising bar, tap again as the diamond crosses the
  center line. Early = hook, late = slice, way off = topped/fat. Perfect
  timing on both = distance bonus.
- 🤏 **Pull-back-and-flick** chips and putts with a live trajectory preview.
  Chips can be chunked. Putts obey green slope, can lip out, and missing a
  short one stings through the haptics.
- 🌬️ **Wind** displayed before every shot and factored into the result.
- 🏆 **Full scramble flow** — 4 players pass-and-play, pick-the-best-ball
  after each round of team shots, water penalties with drops, mercy rule at 8.
- 💰 **Coin wagering** — Friendly (100) / Stakes (500) / High Roller (2000) /
  Custom. Winner takes the pot, plus bonuses for birdies (50), eagles (150),
  clutch 20ft+ putts (75), longest drive (100), match win (500). Bank
  persists between launches.
- 💬 **Trash-talk share sheet** after every shot and at hole end.
- 📳 Haptics everywhere: light tap on power lock, heavy snap on accuracy
  lock, triple-thud rumble on mishits, celebration pattern on holed putts.

**Art direction:** cartoony but understated — muted earthy palette (dark
forest greens, olive, cream, tan), soft dark outlines, and restrained
animation. Feedback comes as gentle ripples, small squash-and-stretch, and
haptics rather than confetti and emoji bursts. All colors live in
`Theme.swift` (`Palette` for SwiftUI, `SceneColors` for SpriteKit).

## Building (requires a Mac)

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd Scramble
xcodegen generate
open Scramble.xcodeproj
```

No XcodeGen? Create a new iOS App project in Xcode named `Scramble`
(SwiftUI, iOS 17+), delete the template `ContentView.swift`/`App.swift`,
and drag the `Scramble/` source folder in.

**Run it on a real device.** The swing meter is tuned around haptics and
they don't exist in the simulator.

## Project layout

```
Scramble/
├─ ScrambleApp.swift          App entry + coin bank (AppState)
├─ Theme.swift                Palette + CGPoint/CGVector math helpers
├─ Core/
│  ├─ Models.swift            Player, Team, Club, Lie, Wind, ShotOutcome…
│  ├─ HoleModel.swift         Hole geometry + lie detection (2pts = 1yd)
│  ├─ ShotEngine.swift        Power + accuracy + wind → shot result
│  ├─ MatchEngine.swift       Scramble turn flow, wagering, settlement
│  ├─ TrashTalk.swift         Auto-generated group chat messages
│  └─ Haptics.swift           The feel
├─ Game/
│  ├─ CourseScene.swift       SpriteKit: course render, ball flight, putt sim
│  ├─ GameView.swift          SwiftUI shell wiring scene ↔ engine ↔ inputs
│  ├─ SwingMeterView.swift    Two-tap meter (model + view)
│  ├─ FlickOverlay.swift      Pull-back gesture for chips/putts
│  ├─ ResultBanner.swift      Post-shot reaction card
│  ├─ PickBallView.swift      Best-ball picker
│  └─ ShareSheet.swift        UIActivityViewController wrapper
└─ Screens/
   ├─ HomeView.swift          Coin balance + quick match
   ├─ MatchSetupView.swift    Players, wager, tee off
   └─ HoleCompleteView.swift  Scorecard + settlement
```

## Tuning the feel

All the numbers that matter live in a few places:

| What | Where |
|---|---|
| Power bar rise speed, accuracy sweep speed | `SwingMeterModel.powerRiseTime` / `accuracySweepTime` |
| Accuracy → result tiers (95/80/60/40) | `ShotRating.init(accuracyPct:)` |
| Distance factors per tier | `ShotRating.distanceFactor` |
| Curve severity | `Club.curveYards` + the `pow(…, 1.2)` in `ShotEngine.meterShot` |
| Wind strength | the `0.9` / `0.55` multipliers in `ShotEngine.meterShot` |
| Putt speed/friction | `480` (max velocity) in `GameView.executeFlick`, `1.9` (friction) in `CourseScene.update` |
| Chunk chance on hard chips | `ShotEngine.chip` |

## Roadmap (v0.2+)

- 9 holes with varied par 3/4/5 layouts (the `Hole` struct is already
  data-driven — add more `Hole.two()`, `Hole.three()`… factories)
- Supabase: profiles, coins, match history, head-to-head records
  ("Jake leads the all-time series 14-2"), realtime 4-player turn sync
- Push notifications ("Jake is waiting on your shot")
- iMessage extension so shots post directly into the thread
- Shop: ball trails (fire/rainbow/money/ghost), club skins, outfits,
  victory animations; StoreKit 2 coin packs
- Stats screen: driving accuracy, clutch rating, chokes (3-putts inside 5ft)
- Aim control before each shot (currently auto-aims at the pin)
