# GameDock — Frontend Design Spec

Design lead's creative direction for the console-dashboard makeover. Every
implementation decision below derives from this. The job: get a couch gamer
with a DualSense from "sat down" to "my game is running" in the fewest inputs,
feeling like a dedicated games machine — not a desktop filing menu.

## Subject & point of view

A controller-first console launcher. Its world: the games machine's own system
UI, CRT service screens, broadcast switchers, arcade operator panels. NOT
RGB-gamer, NOT a generic SaaS dashboard. The launcher is the *machine*; the
games are the *content* — the type system encodes that split.

## Palette (6) — restraint, one accent

| Token | Hex | Use |
|---|---|---|
| void | `#0B0C10` | fullscreen background (cool near-black, not pure) |
| panel | `#141418` | rail + hero frame + card well |
| raised | `#1E1E25` | active/hover surfaces |
| ivory | `#E9E6DE` | primary text — **warm** off-white, anti the cool-cyan default |
| ash | `#6E6B63` | dim labels, hairline contrast, inactive tabs |
| amber | `#F2A93B` | **the one accent** — CRT phosphor; selection, active tab, play cue only |

Hairlines: `#26262E`. No gradients on text, no glow on everything. Amber is
spent in ONE place at a time (the focus), never smeared.

## Typography — the machine vs. the content

- **Chrome** (wordmark, rail labels, position readouts, hints, captions):
  **SF Mono**, heavy/semibold, uppercase, letter-spaced. Reads like a channel
  readout / operator diagnostics. This is the distinctive move.
- **Game titles** (hero + cards): **SF Pro Display**, heavy/bold, proportional
  — the content, readable and warm.
- **Numerics** (counts, 03 / 16): SF Mono.

Mono chrome + proportional titles contrasts the launcher (machine) from the
games (content). Do not round everything; do not use `.rounded` design (the
default "friendly game UI" tell).

## Layout — vertical channel rail + hero + filmstrip

```
┌─────────────────────────────────────────────────────────────┐
│ ┌─ rail (220) ─┐ ┌─ hero (58%) ──────────────────────────┐ │
│ │ GAMEDOCK     │ │                                        │ │
│ │              │ │            [ game art, fill ]          │ │
│ │ ▌HOME        │ │                                        │ │
│ │  STEAM  16   │ │  ─────                                  │ │
│ │  PSP     1   │ │  PERSONA 2                             │ │
│ │  DS      0   │ │  INNOCENT SIN                          │ │
│ │              │ │  ▸ A · PLAY      PSP · 03 / 16         │ │
│ │              │ └────────────────────────────────────────┘ │
│ │ ● 17 games   │ ┌─ filmstrip ────────────────────────────┐ │
│ │              │ │  ▢  ⟤⌐ ⌐⌐⌐ ⟫  ▢  ▢  ▢  ▢  →           │ │
│ └──────────────┘ └──────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

- **Left rail** (fixed ~220pt, panel bg, full height): mono wordmark `GAMEDOCK`
  tracked out at top; platform list — each row a small mono label + count,
  active row gets a 3pt amber bar on its left edge + ivory text + raised bg,
  inactive rows ash. Footer: total count + a scanning dot.
- **Hero** (top ~58% of content, edge-to-edge art fill): bottom-left overlay:
  eyebrow `PSP — 03 / 16` (mono, ash) over a hairline, then the title in heavy
  proportional (up to 3 lines, never cut), then a play cue row `▸  A · PLAY`
  in amber mono. The `03 / 16` is the user's *position in the list* — structure
  as information, not decoration.
- **Filmstrip** (bottom): horizontal cards. Each card ~230×130 art (16:9 fill)
  + a **two-line** title beneath (ivory, bold). Focused card: the signature
  reticle + ~1.04 scale + soft amber glow + shadow. Unfocused: dimmed to ~62%
  brightness, hairline only.

## Signature — the focus reticle

The one memorable element: when a card is focused, four amber **L-shaped corner
brackets** spring in around it (like a viewfinder / "target lock"). It embodies
"the controller locked onto your game." Everything else stays disciplined
(hairlines, flat art, mono labels). The reticle moves with a spring between
cards; that snap is the haptic-feeling moment of the UI.

## Motion — deliberate, not ambient

- Panel switch (L1/R1): hero + filmstrip slide horizontally together, crossfade,
  ~0.32s ease-out. Rail active bar slides vertically, spring. No ambient drift,
  no parallax shimmer (that reads AI).
- Card focus: reticle springs card-to-card; hero art crossfades ~0.2s.
- Reduce-motion (`accessibilityReduceMotion`): all springs/slides → instant
  crossfade only.
- One optional orchestrated moment: on launch, the reticle does a single amber
  "acquire" flash — keep it ≤120ms or skip if it reads gimmicky.

## Text — never cut off

- Card titles: `lineLimit(2)`, card width 230, title area tall enough for two
  lines. Use `.minimumScaleFactor(0.82)` as a safety net only.
- Hero title: `lineLimit(3)`, wide overlay, heavy. Long titles wrap, don't ellipsize.
- Rail labels: short tokens (HOME/STEAM/PSP/DS) — can't cut.
- Hints: mono, padded, single line, sized to fit.
- No `.truncationMode` middle-truncation on visible titles.

## What this is NOT (anti-defaults)

- Not top tab pills (moved to the left rail).
- Not blue/violet/green accents (amber phosphor).
- Not cool-gray text (warm ivory).
- Not `.rounded` design everywhere (use modest radii: cards 10, hero 14, pills
  capsule; the reticle is sharp corners).
- Not SF-Symbols-in-circles chrome (mono type carries the chrome).
- Not ambient/parallax animation (motion only on state change).