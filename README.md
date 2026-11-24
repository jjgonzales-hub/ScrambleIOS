# ⛳️ Scramble

2v2 turn-based golf for the group chat. Real scramble rules: both
teammates hit, the team picks the best ball, both hit again from there.
Three holes, lowest total takes the pot, and every shot generates trash
talk ready to paste into the chat.

The end goal is an iMessage game (GamePigeon-style) where your partner
takes their swing whenever they pick up their phone. Today it's
pass-and-play on one phone, with the game state kept separate from the
renderer so the iMessage version can pass it between phones.

## What's in it (v0.8)

- **Golf Dreams-style one-motion swing** for every club. Pull down and the
  golfer's backswing follows your finger. Push back up and the ball is
  struck as your finger passes the start point. Backswing length is the
  power (exponential). Sideways drift going back and coming through bends
  the shot (hook/slice). A live carry readout and a landing ring in the
  world show what a partial swing will do. Haptic ticks every quarter.
- **Real ball physics** (`Core/BallPhysics.swift`): gravity, drag, lift from
  backspin, side spin, wind you can watch move the ball, surface-dependent
  bounces with wedge check-up, rolling friction per lie, green slope,
  branches that knock balls down, honest cup capture with lip-outs, and
  chip-ins with the flag in. Every shot is simulated up front. The tracer,
  putt read and landing are exactly what the ball does.
- **Putting**: pendulum stroke, where stroke length is the pace. The green
  shows a flowing slope grid, and the read line shows the first part of the
  real roll. You still have to read the rest.
- **3-hole course**: The Opener (par 4), Glass Pond (par 3 over water),
  The Long Way Home (par 5 dogleg). Flyover intro, running scorecard,
  honors, farthest-from-the-hole plays first.
- **Art**: Kenney Mini Characters (13 golfers, CC0) posed procedurally
  into a golf stance and swing. Kenney Nature Kit forests (CC0) merged into
  a few draw calls. Smooth terrain with mowing stripes, water, bloom and
  soft shadows.
- **Coins**: the wager is held at tee-off. Winner takes the pot, plus
  bonuses for birdies/eagles, clutch 20ft+ putts and the longest drive.

## Building (Mac)

```sh
brew install xcodegen
xcodegen generate
open Scramble.xcodeproj
```

Run on a real device for haptics.

### Debug launch arguments

| Arg | Does |
|---|---|
| `-demoHole` | Skip the menus, start a match (no coins) |
| `-demoHoleIndex N` | Start on hole N (0-based) |
| `-skipIntro` | Skip the flyover |
| `-demoPutt` | Drop the ball on the green |
| `-demoSwing` | Auto-play one scripted swing |
| `-autoplay` | Bot plays the whole match through the real UI (logs every shot) |
| `-fast` | 3× game speed (pair with `-autoplay`) |

`xcrun simctl launch <sim> com.jjgonzales.scramble -demoHole -autoplay -fast`
plays a full match in about two minutes.

## Project layout

```
Scramble/
├─ ScrambleApp.swift          App entry, coin bank (AppState), demo config
├─ Theme.swift                Palette, card/button styles, vector math
├─ Art/                       Golfers.usdz, Props.usdz (+ Kenney licenses)
├─ Core/                      Pure game logic, no rendering
│  ├─ Models.swift            Player, Team, Club, Lie, Wind, outcomes
│  ├─ HoleModel.swift         The 3 holes, lie map, caddie aim targets
│  ├─ BallPhysics.swift       Flight / bounce / roll / cup simulation
│  ├─ ShotEngine.swift        Swing → strike quality, carry, curve
│  ├─ MatchEngine.swift       Scramble turn flow, scorecard, settlement
│  ├─ TrashTalk.swift         Group chat lines
│  ├─ Haptics.swift / SoundFX.swift
├─ Game3D/
│  ├─ Course3DScene.swift     Terrain, forest, water, pin, camera, playback
│  ├─ GolferRig.swift         Procedural golfer posing + swing
│  ├─ SwingGestureOverlay.swift  The one-motion swing input
│  ├─ MeshMerger.swift        Bakes props into a few draw calls
│  └─ CharacterPortrait.swift Menu portraits
├─ Game/                      GameView (HUD + flow), result/pick cards
└─ Screens/                   Home, match setup, scorecard, match complete
tools/assets/                 Blender scripts that build the .usdz files
```

## Tuning

| Feel | Where |
|---|---|
| Swing power curve | `exp(2.3 × (pull − 1))` in `GameView.swingOverlay` / `fullCarry` |
| Strike forgiveness | `pow(miss, 1.35)` + tiers in `ShotEngine.meterShot` / `ShotRating` |
| Curve per club | `Club.curveYards` |
| Launch angle / spin / check per club | `BallPhysics.launchProfile` |
| Wind strength | `BallPhysics.windScale` |
| Bounce + roll per surface | `BallPhysics.bounceResponse` / `rollFriction` |
| Green speed | `BallPhysics.greenK` / `greenC`, slope per hole in `HoleModel` |
| Cup capture / lip-outs | `cap` in `BallPhysics.simulate` |
| Putt stroke → distance | `GameView.puttDistance` |
| Camera framing | `Course3DScene.aim` / `updateCamera` |

## Regenerating art

Source packs (CC0): Kenney Mini Characters and Kenney Nature Kit. With
Blender installed:

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
  --python tools/assets/convert_chars.py -- Scramble/Art/Golfers.usdz character-*.glb
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup \
  --python tools/assets/convert_props.py -- Scramble/Art/Props.usdz tree_*.glb ...
```

## Next up

- iMessage extension: serialize `MatchEngine` into `MSMessage` URLs, one
  turn per message
- Locker: outfits/colors per golfer, ball trails
- Punch and flop shots, club upgrades
- More courses (the `Hole` struct is data-driven)
