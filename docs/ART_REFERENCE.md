# Scramble — art reference spec

## PALETTE V2 (2026-07-14, from JJ's style board — CURRENT)

JJ supplied a full visual style board ("SCRAMBLE — 2v2 golf over
iMessage"). Direction: warm, friendly, inviting; soft shadows, subtle
gradients. This supersedes the strictly-muted v1 palette below.

| Hex | Use |
|---|---|
| 1F3B2E | deepest green — backdrop, tree margins |
| 2E5E3E | rough, pine tier 1 |
| 3C7A4C | pine tier 2 |
| 4CAF50 | UI accent, pine tier 3, fairway family |
| 66A852 / 74B45F | fairway mow stripes |
| A8D672 | putting green |
| F5E6C8 / EAD2A0 | cream / sand |
| FF6B6B | coral — flag, wind warning, danger |
| 5D9FD6 | water |
| 7FB9E0 → F2DCA4 | sky gradient, blue overhead to warm horizon |

Implemented in-engine (v0.7): gradient sky + drifting cartoon clouds,
3-tier pines, dashed white aim line to target, pull power strip
(green→amber→coral), golden tracer on PURE strikes, cup sparkle burst,
coral flag on white pole. Board items needing the asset pipeline:
course themes (beach/desert/mountain/garden/night), avatar celebration
animations, icon button row.

# v1 spec (v0.2, 3D direction) — historical

Style target: "indie golf game" — halfway between Super Battle Golf and a
real golf sim. Chunky cartoon characters, grounded course, golden-hour
light, soft dark-olive outlines (never black).

## Palette (canonical hex)

| Swatch | Hex | Use |
|---|---|---|
| Forest | `#2E4A33` | Deep shadows, tree darks, UI ink |
| Olive | `#6B7C4A` | Rough, tee boxes, hats |
| Green | `#9CAF70` | Putting greens, distant green |
| Fairway | `#7E9055` | Fairway base (`#8A9C5F` mow stripes) |
| Cream | `#F2E8D5` | UI chips, polos, shoes |
| Sand | `#D9C08F` | Bunkers, tan shirts |
| Slate | `#6E97AC` | Water, pants, team blue |
| Brick | `#B5533C` | Flags, caps, accents, team red |
| Outline | `#3A4030` | ALL outlines — dark olive, never black |
| Sky (golden hour) | `#F3DCA9 → #E9C384` | Banded, not gradient |

## Characters

Proportions: head ≈ 1/3 of total height, tiny body, stubby limbs, thick
soft outlines, dot eyes, simple mouths. Four archetypes (customization
seeds — each is one hat/hair/shirt swap from a new character):

1. **The captain** — backwards brick cap, cream polo w/ olive stripe,
   driver. The player default.
2. **The menace** — olive bucket hat, sunglasses, tan tee, holds a ball.
3. **The grinder** — cream visor over dark hair, slate-blue polo, white
   glove, putter. Flat serious mouth.
4. **The showboat** — high ponytail, dusty-coral polo (`#C97B63`), cream
   shorts, iron over the shoulder, wink.

Skin tones vary across: `#E8B98A`, `#C68A5C`, `#8C5A3C`, `#F0C8A0`.

## Camera / framing

- **Drive view:** low chase camera behind the golfer, ball ahead at his
  front foot, fairway narrowing to the distant green + pin. Wind chip
  top-left, club/yardage chip bottom-left, vertical swing meter chip
  right of the golfer (runs during the backswing).
- **Putt view:** same behind-ball framing on the green. Slope shown with
  thin contour lines + small chevrons pointing downhill; dotted cream
  read-line curving to the cup. Distance/break chip top-left.
- **Putt/chip gesture (v2 — no UI card):** the gesture lives in the
  world. Thumb-down shows a soft cream ring under the thumb; pulling
  back stretches a taut elastic band from the ball to the ring (with
  small tension ticks); ghost chevrons along the read line brighten and
  extend to preview how far the current tension sends the ball; a tiny
  borderless pill floats by the thumb with the projected distance.
  Release = flick. JJ rejected the earlier boxed pull/flick hint card as
  clunky — never bring boxed gesture tutorials back.

## UI language

Cream (`#F6EEDA`) rounded chips, 1.5px dark-olive stroke, ~97% opacity.
Meter: cream card, tan track, amber (`#C98A3C`) power fill, brick diamond
for accuracy on a dark center line. HUD should feel painted into the
scene, not overlaid.

## Reference mockups

Live SVG mockups were generated in the 2026-07-01 Claude session (drive
view, putt view, character lineup + swatch strip). Reproduce from this
spec when prompting image generators — include: "chunky cartoon golfer,
oversized head, soft dark-olive outlines, muted earthy palette, golden
hour, painterly indie game art, NOT neon, NOT arcade-bright."
