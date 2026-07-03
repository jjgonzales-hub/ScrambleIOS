# Swing mechanics target — Golf Dreams model (research, 2026-07-02)

JJ's direction: swing mechanics should work like *Golf Dreams* (iOS,
apps.apple.com id1551178669, dev Golf Dreams AB). This SUPERSEDES the
two-tap meter for full swings.

## How Golf Dreams' swing works (from listing + player reviews)

One continuous thumb gesture. No power meter, no timing bar, no
"peg-in-the-hole", no timers.

1. **Pull DOWN = backswing.** The golfer's club draws back in real time,
   proportional to the drag. How far back you pull = backswing length
   (power component #1).
2. **Push UP = downswing**, same touch, one motion. The speed of the
   up-swipe = swing speed (power component #2). The game surfaces a
   "swing speed" stat after every shot.
3. **Lateral offset = shot shape.** Drifting left/right on the way back
   and/or on the way up produces hook/slice — deliberately small offsets
   shape draws and fades. Perfectly straight down-and-up = pure. The game
   surfaces a "swing offset" stat after every shot.
4. **Feedback:** ball tracer arc + swing speed + offset numbers after each
   swing. Physics (wind, lie, spin) do the rest; the game "doesn't feed
   you the perfect strike."

Same gesture family drives every shot: drive, punch, flop, chip, putt.

## Known weaknesses (player complaints — we should fix, not copy)

- **Partial power is hard to judge**: "no clear indicator or feel to gauge
  how far the club is back"; a wanted 75% swing lands ~60%.
- **Short game/putting suffers**: "absolutely great for full shots …
  absolutely crippling for short game and putting."

## Mapping onto Scramble

- **Replace the meter with the one-motion swing** for driver/iron/wedge.
  We already have the two building blocks: the golfer rig tracks a
  0–1 pose in real time (`swingPoseProvider` / `setPullback`), and the
  putt gesture already reads pull distance + release velocity. The new
  full-swing gesture is the same machinery: pull down (backswing pose =
  drag), push up (power = blend of backswing length + up-swipe speed),
  release = strike at club impact.
- **Shape from lateral offset**: horizontal deviation of the up-swipe vs
  the pull axis maps onto ShotEngine's existing `earlyLate` parameter
  (negative = hook/draw, positive = slice/fade) — the curve math,
  ratings, and trash talk all carry over unchanged.
- **Fix their power-judgment flaw**: during the pull, show a small
  floating % pill + the club position IS the indicator (our rig already
  mirrors the drag). Optional faint arc ticks at 50/75/100.
- **Fix their short-game flaw**: keep Scramble's dedicated putt gesture
  (pull-back + flick with distance pill and read line) — do NOT force the
  full-swing gesture onto putting.
- **Post-shot stats**: surface "swing speed" and "offset" in the
  ResultBanner rating line, Golf Dreams-style.
- The two-tap meter code (SwingMeterModel/View) stays in the repo until
  the new gesture is validated on device, then dies.

## Status

IMPLEMENTED 2026-07-02 (`Game3D/SwingGestureOverlay.swift`) — the meter
is retired; ALL clubs use the one-motion swing (JJ asked for chips/putts
too). Mode differences: full swing drift = shot shape (hook/slice);
chip/putt drift = aim (rotate launch line up to ~31° to play break).
Green reading added: flowing slope-dot grid on the green while putting +
a physics-true curved read line during the pull (same friction/slope
integrator as the live putt; flick strength still scales final pace).
Tunables: `SwingGestureOverlay.maxPull` (260 pt), up-swipe cancel
threshold (250 pt/s), flick norm (3000 pt/s), power blend
`b * (0.5 + 0.65 * flick)`, drift-to-curve scale (130 pt = full).

Character animation quality remains the top complaint (primitive-rig
rotations judged not good enough) — real rigged character via the
Blender MCP connector is the next art milestone.
