# Scramble — Project Notes & Handoff

A running record of what's been built, key decisions, and what's next. The
full verbatim build conversation is saved alongside this file as
`conversation-log.jsonl` (open it with a text editor, or a JSONL viewer).

## What this is

Scramble — a 2v2 turn-based cartoon golf game for group chats (SwiftUI +
SpriteKit, iOS 17+). Real scramble rules: both teammates hit, the team plays
the best ball, both hit again from there. Lowest score wins the pot. Every
shot generates a trash-talk message to share into the chat.

## Status: v0.1 — core game loop complete

- Two-tap swing meter (MLB The Show style) for driver/iron
- Pull-back-and-flick chips and putts with live trajectory preview
- One full Par-4 hole with fairway, rough, bunkers, pond, green
- Full scramble flow: both hit → pick best ball → both hit again; water
  penalties with drops; mercy rule at 8 strokes
- Wind shown and factored into every shot
- Coin wagering (Friendly/Stakes/High Roller/Custom) + bonuses, bank persists
- Trash-talk share sheet after every shot and at hole end
- Haptics on power lock, accuracy lock, mishits, holed putts

## Key decisions

- **Art direction: muted & understated, NOT bright arcade.** After seeing
  calmer reference mockups, we swapped the original bright navy/gold palette
  for an earthy one (dark forest green, olive, cream, tan, slate blue). All
  colors live in `Scramble/Theme.swift` (`Palette` for SwiftUI, `SceneColors`
  for SpriteKit).
- **Animations dialed way back.** No emoji-confetti bursts. Feedback is now
  gentle ripples, small squash-and-stretch, well-damped springs, and haptics.
  Keep future effects restrained (springs damping >= 0.8, apex scales <= 1.6).
- **Windows dev, Mac build.** Code is written on Windows and synced via the
  private repo (github.com/jjgonzales-hub/ScrambleIOS). Builds happen on a Mac
  with XcodeGen: `xcodegen generate` then open `Scramble.xcodeproj`. The
  `.xcodeproj` is intentionally NOT committed — it's generated from
  `project.yml`.

## Building on the Mac

```sh
brew install gh xcodegen
gh auth login                       # GitHub.com > HTTPS > web browser
gh repo clone jjgonzales-hub/ScrambleIOS
cd ScrambleIOS
xcodegen generate
open Scramble.xcodeproj
```

Then in Xcode: select the Scramble target > Signing & Capabilities >
"Automatically manage signing" > add your Apple ID team. Pick your iPhone in
the device dropdown, press Cmd-R. First on-device run needs
Settings > General > VPN & Device Management > Trust.

Ongoing workflow: changes get pushed to the repo, then `git pull` on the Mac
and rebuild.

## Art assets (in progress)

Generating with ChatGPT/Gemini. Style reference established (painterly, muted,
soft dark-olive outlines). Assets needed, in priority order:

1. App icon (1024x1024, ball + flag on dark green, no text)
2. Home screen hero (portrait 3:4 painterly course, golden hour)
3. Four golfer avatars (head/shoulders, transparent background, one session
   so they stay consistent)
4. Top-down hole backdrop (TRUE 90-degree overhead, portrait 3:5, tee bottom /
   green top / pond right / three bunkers)

Acceptance checks: avatars must have REAL transparency (no fake checkerboard,
no white box); the hole backdrop must be a true overhead view (reject any
perspective tilt — visible tree trunks, angled cup, sky reflection in pond).

When assets are ready: add an asset catalog, wire hero + avatars into the
SwiftUI screens, and drop the backdrop under the course geometry in
`CourseScene`. The hole's hit-detection shapes in `Hole.one()` will need to be
adjusted to trace whatever the backdrop art shows.

## First thing to do once it runs

Play the hole on a real device and judge the swing meter feel. These are the
tunable constants:

| Feel | Where |
|---|---|
| Power bar rise / accuracy sweep speed | `SwingMeterModel.powerRiseTime` / `accuracySweepTime` |
| Accuracy tiers (95/80/60/40) | `ShotRating.init(accuracyPct:)` |
| Distance per tier | `ShotRating.distanceFactor` |
| Curve severity | `Club.curveYards` + `pow(…, 1.2)` in `ShotEngine.meterShot` |
| Wind strength | `0.9` / `0.55` multipliers in `ShotEngine.meterShot` |
| Putt speed / friction | `480` in `GameView.executeFlick`, `1.9` in `CourseScene.update` |

## Roadmap (v0.2+)

- 9 holes with varied par 3/4/5 layouts (`Hole` is data-driven — add more
  factory methods like `Hole.two()`)
- Supabase: profiles, coins, match history, head-to-head records, realtime
  4-player turn sync
- Push notifications ("Jake is waiting on your shot")
- iMessage extension so shots post directly into the thread
- Shop: ball trails, club skins, outfits, victory animations; StoreKit 2 coins
- Stats screen: driving accuracy, clutch rating, chokes
- Aim control before each shot (currently auto-aims at the pin)
