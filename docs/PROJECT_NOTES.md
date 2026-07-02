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

## v0.2 direction — first on-device playtest feedback (2026-07-01)

JJ played v0.1 on a real iPhone. Verdict: core meter is fun, everything else
needs to change. This supersedes parts of the notes below.

- **Go 3D, third-person behind the ball.** The 2D top-down view killed it —
  "super weird to actually play." Camera sits low behind your cartoon
  golfer: see the character, gauge the wind, then swing.
- **Art direction (RESOLVED 2026-07-01): "indie golf game" — halfway
  between Super Battle Golf and a real golf sim.** The cartoon lives in the
  CHARACTERS: chunky proportions, customization, personality (Super Battle
  Golf energy, dialed back from over-the-top). The COURSE stays grounded:
  naturalistic stylized 3D, earthy greens, believable hole proportions,
  soft/golden-hour light — the original muted palette in `Theme.swift`
  carries into 3D. No neon, no arcade saturation. Restrained-animation
  rules from v0.1 still apply.
- **Keep the two-tap swing meter** — driver and irons "felt satisfying."
  Polish its look, and run it WHILE the character takes their backswing so
  meter timing and animation read as one motion.
- **Chipping and putting were not playable in 2D.** Rework both around the
  behind-the-ball camera (reading the green from behind your avatar).
- **Flick gesture misread.** Intended feel: pull finger back slightly, then
  flick UP; the flick expresses intended strength. Current
  pull-back-and-drag mechanic "lost in translation."
- **This is an iMessage game, not a standalone app.** Target experience:
  take your swing at work, put the phone away, partner swings later,
  trash talk lands in the group chat. Async turn-based via an iMessage
  extension (MSMessagesAppViewController + MSSession) is the end state;
  pass-and-play remains the feel-testing harness for now.
- JJ is supplying reference images for avatar look behind the ball and
  behind putts, drawn from Super Battle Golf's art style.

## v0.2 progress — 3D milestone SHIPPED to working tree (2026-07-01)

The SpriteKit top-down renderer is replaced. What's in:

- `Scramble/Game3D/Course3DScene.swift` — SceneKit scene: chase camera
  behind the ball, banded golden-hour sky, fog, warm directional light with
  shadows, painted ground plane (the 2D hole map rendered to a texture, so
  visuals match `Hole.lie(at:)` exactly), primitive-built trees, pin/cup,
  and a chunky primitive golfer (the captain: cream polo, brick backwards
  cap). ALL gameplay simulation still runs in 2D hole coords — flight path,
  putt friction (1.9), slope drift, lip-outs are byte-identical to v0.1;
  the 3D layer only renders those coords (mapping: world = (x, h, -y)).
- `Scramble/Game3D/ElasticGestureOverlay.swift` — the v2 card-free gesture:
  thumb ring, taut band with tension ticks, floating ft/yds pill, in-scene
  ghost dots along the line. Screen pull is converted to a world direction
  relative to the chase camera in `GameView.worldDirection`.
- `GameView` now hosts `SceneView` + the new overlay; meter flow, banners,
  pick-ball, wagering, share sheet all unchanged.
- Camera framing per shot kind (back/height/aside) lives in
  `Course3DScene.aim` — tuned via simulator screenshots.
- Debug launch args: `-demoHole` boots straight onto the tee,
  `-demoPutt` (with it) drops the ball on the green. Used for simulator
  screenshot checks: `xcrun simctl launch <sim> com.scramble.golf -demoHole`.
- Legacy 2D files (`Game/CourseScene.swift`, `Game/FlickOverlay.swift`)
  still compile but are unused — delete once 3D is validated on device.
- Not yet done: aim control, terrain height, character variants per player.

### Animation + sound + polish pass (2026-07-01, same day)

- **Swing animation synced to the meter.** The golfer's arms + club live in
  a `swingNode` pivoted at the shoulders; while the power bar rises the
  backswing tracks it in real time (`swingPoseProvider` polled per frame,
  eased), holds at the top through the accuracy sweep, then
  `swingRelease(impact:)` plays downswing → impact (ball launches HERE, not
  at the tap) → follow-through → settle.
- **Putt/chip pull-and-flick now reads the flick.** The putter mirrors the
  finger during the drag (`setPullback`); on release, DragGesture's
  velocity decides firmness: power = pull × (0.55 + 0.9 × flickNorm),
  flickNorm = upwardSpeed/2600. No flick = soft lag at ~55% of the preview
  line; full snap plays ~40% past it. `strokeRelease(power:impact:)`
  animates the stroke, ball moves at contact.
- **Club swap**: driver model for meter shots/chips, upright flat-blade
  putter on the green (toggled in `Course3DScene.aim`).
- **Meter redesigned**: frosted capsule track, hairline ticks (25/50/75),
  flat accent fill, sweet-spot band, locked-power notch, perfect-window
  band + pill sweep marker that flares on-center, single big power number.
  Only appears once SWING is tapped (spring transition).
- **Sound effects** — all procedurally synthesized, no external assets:
  `tools/gen_sounds.py` writes the WAVs into `Scramble/Sounds/`
  (hit_driver/iron/chip/putt, mishit, whoosh, cup_drop, splash, ui_lock,
  pure_chime). `Core/SoundFX.swift` plays them via AVAudioPlayer, ambient
  session (never interrupts the player's music, respects silent switch).
  Hooks: power-lock tick, downswing whoosh, per-club impact, mishit thud,
  chime on PURE and holed putts, cup rattle, splash.
- **Scene polish**: grass speckle grain in the ground texture (skips
  sand/water), waving flag cloth, glossy ball (blinn), golfer blob shadow,
  cleaner bottom bar (lie pill, capsule SWING button, no emoji soup).
- Verified in simulator via `-demoSwing` (auto-plays a full meter swing):
  backswing-at-85 frame, follow-through frame, PURE 248-yd banner, putter
  on green.

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

## Art assets (REVISED for 3D direction)

The old 2D asset plan is superseded — the top-down hole backdrop (old item 4)
is OBSOLETE with the move to 3D; don't generate it. Style target: "indie
golf game" — cartoony characters on a grounded course (see v0.2 direction
above).

Still useful as 2D images (ChatGPT/Gemini, painterly, muted, soft
dark-olive outlines):

1. App icon (1024x1024, ball + flag on dark green, no text)
2. Home screen hero (portrait 3:4 painterly course, golden hour)
3. Concept art for the four golfers — now doubles as the modeling reference
   for 3D avatars (full body, chunky proportions, one session so they stay
   consistent)

New 3D needs (approach TBD — likely simple low-poly models, SceneKit):

4. Golfer character model + swing/backswing animation set
5. Stylized course kit: tee box, fairway/rough/green materials, bunkers,
   water, low-poly trees, flag/pin

Acceptance checks: avatar concepts must have REAL transparency (no fake
checkerboard, no white box); course materials must stay in the earthy
`Theme.swift` palette — reject anything neon or arcade-bright.

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
