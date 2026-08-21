# UI/UX Strategy Audit — Leblanc (GameDock)

A strategic audit of the live frontend UI, read directly from source (all file:line
citations are against the current checkout). Goes beyond `scout-ui-audit.md`
(text cutoffs/transitions) and `plan-ui-ux-improvements.md` (bugs/states) into
layout strategy, navigation friction, and the core question of *whether the XMB
is the right shell for this product*.

> Tldr up front: **The implemented shell is a different product than
> `design-spec.md` describes, and in several load-bearing ways it is the weaker
> one.** The biggest single win available is to abandon the portrait-cover
> vertical item list and move the item axis to a horizontal filmstrip/grid
> (16:9 art), keeping the category rail. The signature focus reticle should be
> brought in as the replacement for the ambient WaveField. Details + a concrete
> target layout below.

---

## 1. What's Implemented vs. What Was Specified

This is the most important finding. The spec
(`docs/design-spec.md`) and the code (`Sources/GameDock/UI/`) describe two
different UIs. The deltas are not cosmetic — they change information density,
scan-ability, and the perceived identity of the machine.

### 1.1 Layout — completely different geometry

| Element | Spec (`design-spec.md`) | Implemented | Verdict |
|---|---|---|---|
| Category nav | Left vertical rail, 220pt, panel bg, full height (`:61-64`) | Horizontal category rail at top, centered, `HStack(spacing:42)` (`XMBView.swift:84-91`) | **Spec better.** A horizontal rail at the top is the "top tab pills" the spec explicitly rejects as an anti-default (`:104`). The vertical rail carries the mono wordmark + counts + a scanning dot and reads as a *machine side panel*; the top row reads as a generic app toolbar. |
| Item axis | Horizontal filmstrip at the bottom, 16:9 cards ~230×130 (`:69-73`) | Vertical item bar, portrait covers, selected centered + neighbors peek above/below (`XMBView.swift:127-169`) | **Spec dramatically better.** See §2.1 — the vertical portrait list is the root cause of the documented overflow and the single biggest UX weakness. |
| Hero | Top ~58% of content, edge-to-edge art fill, title overlay (`:65-69`) | No hero. The "selected" cover *is* the art, at 300pt wide (`XMBView.swift:198-203`) | **Spec better.** A hero gives a large art surface + a dedicated, reserved title band that never clips. The XMB conflates "the focused item" with "the art stage," so the two fight for the same vertical budget. |
| Item aspect | 16:9 fill (`:70`) | Portrait, `itemCoverAspect = 0.78` (`Theme.swift:50-51`) | **Spec better.** Game art (Steam capsules, PSP box art) is landscape; a portrait frame forces `.fill` crops that decapitate key art. The portrait choice was made to evoke PSP/PS3 XMB icon silhouettes, but the content is landscape. |
| Selection signal | Focus reticle: four amber L-shaped corner brackets that spring card-to-card (`:76-82`) | None. Selection = size + dim + colored 2pt border + `shadow(accent.opacity(0.35))` (`XMBView.swift:239-243`) | **Spec dramatically better.** The reticle is the *one memorable element* the spec calls out as signature (`:77`). The implementation has no signature; selection is generic. |
| Background | Flat `void` near-black, no ambient motion (`:19`, `:84-87`) | `WaveField`: 5-layer animated sine field at 30fps + selection ripples (`WaveField.swift:31-53`) | **Spec explicitly forbids this.** See §2.3. |

### 1.2 Color system — warm amber phosphor vs. cool multi-accent

| Token | Spec | Implemented |
|---|---|---|
| Accent | `amber #F2A93B`, "the one accent… spent in ONE place at a time" (`:24-27`) | `signal #4FD3FF` cyan, plus per-platform accents: `steamAccent=cyan`, `psspAccent=#9B8CFF violet`, `dsAccent=#FF8C8C coral`, `homeAccent=ember`, `discordAccent=#7A86C8`, `trophy=#FFC94D` (`Theme.swift:9-24`) |
| Primary text | `ivory #E9E6DE` warm off-white, "anti the cool-cyan default" (`:22`) | `paper #EDEFF5` cool near-white (`Theme.swift:12`) |
| Background | `void #0B0C10` cool near-black (`:19`) | `void #0A0D16` blue-black (`Theme.swift:7`) |

The spec's palette is a deliberate, opinionated *anti-default*: warm amber on
warm ivory to escape "RGB-gamer / SaaS dashboard" territory
(`design-spec.md:103-110`). The implementation does almost the opposite: a cool
cyan-on-cool-white scheme that is, visually, the default macOS-app-with-an-accent
look the spec was written to avoid. The per-platform accent idea (cyan/violet/
coral) is defensible *in principle* — it lets the rail encode source at a glance
— but it violates the spec's "one accent, one place at a time" rule and, in
practice, means the selection glow, the rail underline, the count pill, the
cover border, *and* the wave tint all shift hue every category switch. That is
*six* simultaneous color changes per L1/R1, which reads as restless rather than
informative. Cyan specifically does not read as "games machine"; it reads as
"tech-product accent color #4."

### 1.3 Typography — the machine/content split is intact but the fonts differ

The spec wanted **SF Mono for chrome + SF Pro Display for titles** — a contrast
between operator-diagnostics type and warm content type (`:29-41`). The
implementation instead bundles **Chakra Petch** (display/labels) and **JetBrains
Mono** (data) via `GameDockFonts.registerAll()` (`GameDockFonts.swift:9-41`).

This is the *one* area where the implementation arguably improves on the spec.
The machine/content split is preserved and even sharpened: Chakra Petch's
techno-industrial Latin carries the "operator panel" feel better than SF Pro
Display, and JetBrains Mono is a cleaner data face than SF Mono. The split
lands: titles use `display()` (`Theme.itemTitleSelected = display(44, .bold)`,
`Theme.swift:42`), chrome/counts/clocks use `data()` (`XMBView.swift:30,40,108`).
**Verdict: keep the fonts.** The only nit is that the spec's "do not use
`.rounded` design" anti-default (`:40`) is respected (Chakra is not rounded), so
the type system is the most spec-aligned subsystem in the codebase.

### 1.4 Motion — ambient drift where the spec demanded stillness

The spec's motion section is unusually emphatic: *"No ambient drift, no
parallax shimmer (that reads AI)"* (`:86-87`), and Reduce Motion must collapse
all springs/slides to instant crossfade (`:89-90`).

The implementation ships a continuously animating full-screen Canvas
(`WaveField.swift:31-41`, `TimelineView(.periodic(by: 1.0/30))`) that redraws
five sine layers + fills every frame, *always*, behind the entire shell. The
ripples on selection (`AppEnvironment.swift:490`, emitted at a hardcoded
`x:0.5, y:0.58` — not the card's actual center) are the only state-change-driven
motion; the waves themselves are pure ambient drift. This is the single most
direct spec violation in the codebase. See §2.3 for whether it's worth keeping.

---

## 2. What's Weak in the Current UI/UX

The existing audits catalog the *symptoms* (text clipping at `XMBView.swift:177`,
unbounded subtitle, missing animations). The strategic causes are below.

### 2.1 The vertical portrait-cover list is the wrong layout for a game library

This is the root finding. The item bar is a vertical `VStack` of portrait
covers: selected ~280×360pt (capped at `selectedCoverMaxHeight = 360`,
`XMBView.swift:198-203`), neighbors 72×92pt (`XMBView.swift:192-194`), window of
5 (2 above + selected + 2 below, `XMBView.swift:133-135`), `spacing: 20`.

A full window sums to: `92 + 92 + 360 + 92 + 92 + (4 × 20) = 808pt`. The
fullscreen viewport after the hint row (`padding(.top,18)`, `XMBView.swift:46`),
clock, and category rail (`padding(.top,26)` + rail height, `:48-49`) leaves
roughly 670pt on an 800pt display. **The window overflows by ~140pt**, and the
bottom neighbors render fully under the 220pt darkening scrim
(`XMBView.swift:60-66`) — actively darkened, not merely clipped
(`scout-ui-audit.md:4.4`).

The `selectedCoverMaxHeight = 360` cap (`XMBView.swift:203`) is a band-aid that
confirms the diagnosis: the layout is fundamentally fighting the screen budget.
The cap reduced the old 429pt cover (audit 1.2, against the since-changed 0.70
aspect) to 360, but the window *still* doesn't fit. You cannot fix this by
tuning heights — a vertical list of large portrait cards in a landscape window
is geometrically mismatched.

Beyond the overflow, the vertical list is **bad for a game library specifically**:

- **Information density: ~5 items visible, but only 1 legible.** The two
  neighbors above/below are 72pt wide — title text is not shown on neighbors at
  all (`neighborView` renders cover-only, `XMBView.swift:192-194`). So at any
  moment the user sees *one* game title. Browsing means scrolling blind, reading
  one title, scrolling, reading one title.
- **Scan-ability: linear, one-at-a-time.** A 100-game Steam library cannot be
  visually scanned; you must walk it. Compare to the spec's filmstrip
  (`design-spec.md:69-73`) where ~7–9 cards with two-line titles are visible
  simultaneously and the eye can jump.
- **Portrait crop decapitates landscape art.** `ArtworkView` uses
  `.aspectRatio(contentMode: .fill)` then `.clipped()`
  (`ArtworkView.swift:24-32`). A 16:9 Steam capsule `.fill`-cropped into a 0.78
  portrait frame loses ~45% of the image — typically the top/bottom where logos
  and key art live. The library is serving the wrong-shaped art.

The XMB vertical list was designed in 2005 for media *categories* (photos, music,
videos) where items within a category were themselves few and uniform. It is the
wrong inheritance for a 100+ game library.

### 2.2 Navigation friction — the "sat down to my game running" path

The product brief (`design-spec.md:6`) frames the job as: get a couch gamer from
"sat down" to "my game is running" in the fewest inputs. Walking the actual
router (`AppEnvironment.swift:193-332`, `XMBNavModel.swift:91-167`):

**Path A — a Steam game that is NOT recent/favorited (the common cold case):**

1. Boot → lands on **Home** category (`categoryIndex = 0`, `XMBNavModel.swift:49`; Home is built first, `AppEnvironment.swift:345`).
2. Press **Right** (or **L1**) → switch to Steam category (`XMBNavModel.swift:93-99, 155-159`). *Category switch is one input — good.*
3. Press **Down** N times to reach the game. `down()` advances one item per press, wrapping (`XMBNavModel.swift:147-150`). There is **no jump-to-letter, no search, no page skip** (the plan lists search as an optional Phase 5 bet, `plan-ui-ux-improvements.md:159`). Hold-to-repeat fires at 12/s after 0.4s hold (arch skill invariant 9). So game #60 of 100 = hold Down ~5 seconds, or 59 discrete taps.
4. Press **X** → `xmbConfirm` → launch (`AppEnvironment.swift:311-316`).

**Worst case ≈ 5–8 seconds of holding Down with no visual scan aid, then X.** For
a cold game in a 100-title library this is poor. The Home category mitigates the
*warm* path (favorites + recents first, `AppEnvironment.swift:384-396`) — a
recently-played game is 2 inputs (Home already selected, Down to it, X). That
part is genuinely good. The cold path is the hole.

**Path B — a PSP game:** identical friction to Path A but you press Right *twice*
(Home → Steam → PSP, `AppEnvironment.swift:345-348`) then Down-N then X. The PSP
ROM library is typically small (tens), so the Down-N is shorter, but PSP also
hands off to the standalone PPSSPPSDL.app (`AGENTS.md` §6) — the launch itself is
a window-hide + external process, so the *post-press* latency is higher and
unavoidable.

**Path C — finding a specific game in a 100-game library with no search:** the only
mechanism is linear scroll. There is no keyboard entry (keyboard is fallback-only
when no controller is connected, `plan-ui-ux-improvements.md:86`), no
jump-to-letter rail, no filtering. This is the single biggest navigation gap and
it is *structural to the one-item-at-a-time vertical list*, not a missing feature
that patches cleanly onto it.

**Where it feels awkward, specifically:**
- **Category switch throws away item position** is *already fixed*
  (`lastItemIndexByCategory`, `XMBNavModel.swift:54, 131-140`) — good, the audit's
  3.1 is resolved. But switching category still snaps the cover morph
  (96→280pt) every time, which the audit (2.1) flags as a double-spring; that's
  unresolved.
- **The quick bar "Recently Played" lands on Home item 0**, not the first recent
  (`scout-ui-audit.md:3.2`) — still true; `selectCategory("home")` doesn't
  differentiate. Minor but it makes a redundant affordance feel broken.
- **Circle/Back is dead in XMB** (`AppEnvironment.swift:300-309`) — it only does
  something in the emulator. A user pressing Circle on the home screen gets
  nothing, which breaks the "always a way back" console convention.

### 2.3 The WaveField — helping or hurting?

The spec's anti-default is unambiguous: *"Not ambient/parallax animation (that
reads AI)"* (`design-spec.md:110`), and the motion section forbids ambient drift
(`:86-87`). The WaveField is *exactly* the thing the spec was written to exclude.

Concrete harms:
- **It reads as "AI-generated dashboard motion."** Five drifting sine layers
  tinted to the accent, continuously, behind a game library is the visual
  signature of a generated/templated UI, not a "CRT service screen / broadcast
  switcher / arcade operator panel" (`design-spec.md:11-13`). The spec's whole
  aesthetic is *machine-stillness punctuated by state-change motion*; the wave
  field is the opposite — ambient motion with state-change ripples on top.
- **It's a continuous cost.** `TimelineView(.periodic(by: 1.0/30))` redraws a
  full-screen Canvas at 30fps forever (`WaveField.swift:32`), including a fill
  path per layer (`:65-73`) — the audit flags it as "the dominant XMB CPU
  hotspot" comment in the code itself (`WaveField.swift:57-58`). On an
  always-on launcher this is real battery/CPU for zero information.
- **It collides with the reticle's job.** The spec wanted *one* signature
  moment of motion: the reticle snapping card-to-card (`:80-82`). The wave
  field + ripples already provide a "selection reacted" cue, so bringing in the
  reticle on top would be three motion systems (waves + ripples + reticle).
  Something has to give, and the wave field is the least spec-aligned.

The ripples-at-fixed-origin are also wrong: `waveField.emit(x: 0.5, y: 0.58, …)`
(`AppEnvironment.swift:490`) fires from a hardcoded screen point regardless of
which cover is selected. The ripple should originate at the focused card's
center — but in a vertical list the card moves, so a correct ripple would require
a `GeometryReader` per cover. This is friction that exists *because* of the wave
field; drop the wave field and the problem disappears.

**Verdict: the WaveField hurts. Remove the ambient waves; keep *only* a
state-change motion (the reticle, §3).** If any ambient is kept, it should be a
near-static CRT scanline/vignette, not drifting sines.

### 2.4 Color system — multi-accent is worse for a console UI

The per-platform accent (`Theme.swift:15-24`) is a reasonable *idea* (encode
source in the rail) but a poor *execution* in a console context:

- **Real consoles use one accent.** PS5 uses blue throughout; Xbox uses a single
  system accent. The "one accent, one place at a time" rule
  (`design-spec.md:27`) exists because a console UI needs a single unmistakable
  "this is focused" signal. Six shifting hues dilute that signal: when the glow,
  underline, count pill, border, and wave tint all recolor on every category
  switch, the user cannot form a single "focused = this color" association.
- **Cyan does not read as a games machine.** The spec's amber phosphor was a
  deliberate CRT-arcade reference (`:24`). Cyan is the default "modern tech
  accent" — it makes Leblanc look like a generic macOS utility, not a console.
- **The warm/cool inversion compounds it.** Spec: warm ivory text + warm amber
  accent (cohesive, warm). Impl: cool paper text + cool cyan accent (cohesive
  but cool, and cool-on-cool is the exact "SaaS dashboard" look the spec rejects).

**Verdict: revert to a single amber (or amber-equivalent) accent** for the focus
signal, and encode source via a small mono *label/icon* in the rail, not via
accent color. The per-platform colors can survive as a 3pt rail marker dot, never
as the focus glow.

### 2.5 Settings as 300pt cover cards with question-mark icons

`SettingsNavModel` builds a flat list of rows (`SettingsNavModel.swift:26-100`)
that `rebuildXMB` maps into `XMBItem`s with `action: .settings(row.kind)`
(`AppEnvironment.swift:360-367`). These render through the same `cover()`
function as games (`XMBView.swift:208-246`), which for `.action` items draws a
`Theme.ink` square with a `questionmark` SF Symbol at 16% of cover size
(`XMBView.swift:216-221, 252`). So **every settings row is a 300pt card with a
giant question mark**.

This is bad settings UX by any standard:
- **A question mark is not a glyph.** `glyph(for:)` returns `questionmark` for
  `nil` action (`XMBView.swift:248-254`) — and settings rows that aren't Discord/
  Settings-root fall through to it. The icon communicates nothing.
- **Settings are not games.** A 300pt art card is a *content* surface; settings
  are *chrome*. Forcing chrome into the content frame breaks the machine/content
  type split the spec established (`design-spec.md:29-33`). Real consoles render
  settings as compact horizontal rows (icon + label + value), never as art
  cards. The plan's 4.7 (`plan-ui-ux-improvements.md:141-142`) already identifies
  this and proposes a `.settingRow` kind — that fix is correct and should be
  prioritized regardless of the larger layout decision.
- **Detail paths (ROM folder paths, core dylib paths) are long** and render as a
  subtitle under a giant card — illegible. A compact row with middle-truncated
  mono path would be far more readable.

### 2.6 Controller hints — persistent PS/Share glyphs

`ControllerHints` (`XMBView.swift:314-333`) renders a boxed "PS" wordmark and a
share glyph, permanently, top-right, at 85% opacity.

Real consoles do *not* show persistent button hints on the home screen. PS5 shows
contextual hints *on specific screens* (e.g. "press OPTIONS for settings" appears
briefly or in a corner), and hides them on the idle home. Persistent glyphs are
noisy on a screen that should read as a calm machine surface, and they're
redundant — the Share button's function (Discord) is already discoverable via the
Share button itself and the Quick Bar.

**Verdict:** drop the persistent hints from the home screen; show contextual
hint pills only on overlays (the emulator screen already does this well,
`EmulatorScreen.swift:62-71`). If a persistent affordance is wanted, a single
small mono "⌘⇧⌥ HOME" hotkey reminder is enough — the PS/Share glyphs duplicate
hardware the user is already holding.

### 2.7 The preview panel — does it fit the XMB?

`SelectionPreviewPanel` (`SelectionPreviewPanel.swift`) is a 300pt-wide ink panel
placed `.overlay(alignment: .trailing)` to the item bar
(`XMBView.swift:156-165`), vertically centered against the selected cover, with
a 16:9 rotating screenshot + metadata + playtime
(`SelectionPreviewPanel.swift:18-53`).

It's well-engineered (debounced 350ms, disk-cached images, additive per arch
invariant 10). But in the XMB layout it is **compensating for the layout's own
deficiency**: the vertical list shows one cover + one title, so the panel was
added to surface screenshots/playtime that the layout can't. The panel works in
the sense that it doesn't break input (additive), but:

- **It competes for horizontal space with the already-overflowing vertical
  stack.** The selected cover is 280pt wide, centered; the panel adds 300pt +
  40pt trailing padding to its right. On a 1440pt display that's fine; on a
  1280pt laptop fullscreen it pushes the cover off-center toward the left,
  making the "neighbors peek above/below" asymmetric (the panel only sits to the
  right, never the left).
- **It's a second art surface.** Now the user sees the cover (portrait, cropped)
  *and* a 16:9 screenshot beside it. Two art surfaces for one game is visually
  busy and somewhat redundant — the screenshot is strictly more informative than
  the cropped portrait cover, so the cover is doing little work.
- **Its value evaporates under a better base layout.** In the spec's hero+
  filmstrip, the hero *is* the large art surface with a title overlay, and a
  rotating screenshot would live *in the hero* — no separate panel needed. The
  panel exists *because* the XMB has no hero. This is the clearest tell that the
  XMB is the wrong base: features are being bolted on to compensate for its
  missing art stage.

---

## 3. Should Leblanc Use a Different UI?

**Yes. The XMB vertical item list should be replaced with a horizontal
filmstrip for the item axis, the spec's focus reticle should be brought in as
the signature, and the WaveField should be removed.** The category navigation can
stay XMB-derived (it is genuinely good for source switching) but the *item*
presentation should not.

### 3.1 Why the XMB heritage is the wrong fit

XMB (PSP/PS3, 2005) is a media-browser design. Its vertical item list works
when items within a category are *few and uniform* (a photo album, a music
playlist). It breaks down for a large, heterogeneous game library because:

- **One-at-a-time browsing doesn't scale.** A 100-game library forces linear
  scroll with no scan (§2.2).
- **The vertical axis wastes the landscape screen.** A landscape window's
  natural scan axis is horizontal; the XMB spends its wide axis on the category
  rail (4–7 items) and its scarce vertical axis on the library (100+ items) —
  exactly inverted.
- **Modern consoles abandoned it.** PS5 and Xbox Series both use horizontal
  rows/carousels with many visible tiles *because* the library is the primary
  content. The XMB was retired for this exact use case.

### 3.2 The spec's design solves the documented problems

Mapping the spec layout onto the current pain points:

| Current problem | Spec layout resolution |
|---|---|
| Vertical overflow (§2.1, 808pt vs 670pt) | Hero (58% height) + filmstrip (bottom band) are each bounded horizontal bands; no tall portrait stack to overflow. |
| One title visible (§2.1) | Filmstrip shows ~7–9 cards with two-line titles (`design-spec.md:70-73`); eye can scan. |
| Portrait crop decapitates art (§2.1) | 16:9 fill matches Steam/PSP landscape art natively. |
| No signature (§1.1) | Focus reticle (`:76-82`) is the memorable element; selection reads as "target lock." |
| Ambient motion that "reads AI" (§2.3) | Spec forbids it; stillness + reticle snap only. |
| Multi-accent dilutes focus (§2.4) | Single amber, one place at a time (`:27`). |
| Preview panel compensating for missing hero (§2.7) | Hero *is* the art stage; rotating screenshots live in the hero; panel becomes unnecessary. |

The spec layout was not arbitrary — it was designed to solve precisely the
problems the XMB implementation re-introduced.

### 3.3 The hybrid that fits Leblanc's actual needs

The pure spec (left rail + hero + filmstrip) is the right *target*, but Leblanc
has a category structure (Home/Steam/PSP/DS/Discord/Achievements/Settings) that
the XMB rail already handles well. The recommendation is a **hybrid**: keep a
category navigation rail (it can be the spec's left vertical rail, which is
strictly better than the current top row), and use a horizontal filmstrip for
items within a category. This keeps the source-switching mental model (L1/R1 =
category) and fixes the item browsing.

**Target layout (ASCII, after `design-spec.md:44-58`):**

```
┌──────────────────────────────────────────────────────────────────────┐
│ ┌─ rail (220) ─┐ ┌─ hero (top ~58%) ──────────────────────────────┐  │
│ │ LEBLANC      │ │                                              │  │
│ │              │ │            [ 16:9 game art, fill ]            │  │
│ │ ▌STEAM  16   │ │                                              │  │
│ │  PSP     3   │ │  ───── hairline ─────                        │  │
│ │  DS      0   │ │  PERSONA 2                                   │  │
│ │  ─────       │ │  INNOCENT SIN                                │  │
│ │  DISCORD     │ │  ▸ A · PLAY        STEAM · 07 / 16   3h play  │  │
│ │  ACHIEVE     │ └──────────────────────────────────────────────┘  │
│ │  SETTINGS    │ ┌─ filmstrip (bottom) ─────────────────────────┐  │
│ │              │ │  ⟤ ⌐⌐⌐ [⌐⌐⌐] ⌐⌐⌐ ⌐⌐⌐ ⌐⌐⌐ ⌐⌐⌐ ⟫            │  │
│ │ ● 19 games   │ │  Persona1  Persona2  Persona3  ...           │  │
│ │ ◌ scanning   │ └──────────────────────────────────────────────┘  │
│ └──────────────┘                                                     │
│                                              ⌘⇧⌥ HOME · ◌ offline   │
└──────────────────────────────────────────────────────────────────────┘
   L1/R1 = category (rail)      ◀▶ = filmstrip      ▲▼ = (unused / page)
   ✕ = play                     ○ = back/up a level
```

Key properties of this target:
- **Rail (left, 220pt):** mono `LEBLANC` wordmark; platform list with mono counts;
  active row = 3pt amber bar + raised bg. Footer: total count + scanning dot +
  offline pill. This is the spec rail verbatim (`design-spec.md:61-64`) and it
  replaces the current top `HStack` (`XMBView.swift:84-91`).
- **Hero (top ~58%):** edge-to-edge 16:9 art fill; bottom-left overlay =
  hairline + title (heavy, `lineLimit(3)`, wide, never cut, `:96-98`) +
  `▸ A · PLAY` cue in amber mono + position readout `STEAM · 07 / 16` + playtime.
  The rotating screenshot (currently the preview panel) lives *here* — one art
  surface, no separate panel.
- **Filmstrip (bottom):** horizontal cards ~230×130 (16:9), two-line titles
  beneath (`:70-73`). Focused card: **reticle** (4 amber L-brackets) + ~1.04
  scale + soft amber glow + shadow. Unfocused: dimmed to ~62%, hairline only.
  Left/right walks the strip; L1/R1 switches category (rail).
- **Position readout `07 / 16`:** this is the spec's "structure as information"
  (`:69`) — the user's *place in the list*, absent from the current XMB.
- **Hints:** one small mono hotkey reminder bottom-right; no persistent PS/Share
  glyphs. Offline pill only when offline.

### 3.4 What about keep-the-XMB-but-fix-it?

If a full layout swap is declined, the minimum to make the vertical XMB viable:

1. Switch covers to 16:9 (`height = size * 9/16`) so selected ≈169pt, neighbors
   ≈54pt — the window then fits in ~560pt (`scout-ui-audit.md` 1.2 fix).
2. Show two-line titles on neighbor cards (currently cover-only,
   `XMBView.swift:192-194`) so scanning is possible.
3. Add jump-to-letter / search (currently Phase-5-optional,
   `plan-ui-ux-improvements.md:159`) — *mandatory* if the one-at-a-time list
   stays, else 100-game browsing is unusable.
4. Add the reticle anyway — it's layout-agnostic and is the missing signature.
5. Remove the WaveField (§2.3).

But this is a worse use of effort than §3.3: it patches a layout that is
geometrically mismatched to landscape game art, and it leaves the "no hero /
panel compensates" structural debt (§2.7) in place. **The recommendation is
§3.3.**

---

## 4. Prioritized Recommendations

Ranked by impact × leverage. Effort: S = ≤½ day, M = 1–2 days, L = 3+ days.

### P1 — Replace the vertical item list with a horizontal filmstrip + hero (L)
- **What:** Rebuild `XMBView.itemBar` (`XMBView.swift:127-169`) into a hero band
  (top ~58%) + horizontal filmstrip (bottom). Move the rotating-screenshot logic
  out of `SelectionPreviewPanel` and into the hero. Switch covers to 16:9
  (`Theme.itemCoverAspect` → `16/9`, `Theme.swift:50-51`). Move the category nav
  to a left rail (`XMBView.swift:84-91` → vertical, 220pt).
- **Why:** Resolves the overflow (§2.1), the one-title-visible density (§2.1),
  the portrait crop (§2.1), and makes the preview panel unnecessary (§2.7) in
  one change. This is the highest-leverage edit in the audit.
- **Effort:** L.
- **Depends on:** P2 (reticle) lands well inside this; P3 (color) should land
  with or just after. P4 (settings rows) is independent.

### P2 — Bring in the focus reticle as the signature (M)
- **What:** Add an `LBrackets`/`Reticle` view: four amber L-shaped corner
  brackets that spring to the focused card via `matchedGeometryEffect`. Wire it
  into the filmstrip focused card (and/or the hero). Remove the ripple-at-origin
  (`AppEnvironment.swift:490`) — the reticle *is* the state-change motion.
- **Why:** Gives the UI its missing memorable element (§1.1, `design-spec.md:76-82`).
  Replaces the spec-violating WaveField's "selection reacted" job with a
  spec-aligned one.
- **Effort:** M (geometry + spring wiring; not algorithmically hard).
- **Depends on:** P1 (reticle needs a focused card frame to bracket).

### P3 — Revert to a single warm accent, demote platform color to a rail marker (M)
- **What:** Make `Theme.signal` the amber `#F2A93B` (`Theme.swift:9`); make
  `paper` warm ivory `#E9E6DE` (`Theme.swift:12`). Keep per-platform colors
  (`steamAccent` etc., `Theme.swift:16-21`) *only* as a small mono label/dot in
  the rail, never as the focus glow/border/wave tint. Audit every
  `cat.accent`/`accent(for:)` usage (`XMBView.swift:17,109,112,118,141,160,241,243`)
  and route focus chrome through `Theme.signal` only.
- **Why:** Restores the "one accent, one place at a time" console rule (§2.4);
  amber reads as a games machine, cyan does not.
- **Effort:** M (mechanical but touches many call sites; needs a visual pass).
- **Depends on:** none; can land before P1 but best alongside.

### P4 — Remove the WaveField ambient waves (S)
- **What:** Delete the `drawWaves` idle loop (`WaveField.swift:45-73`) and the
  `TimelineView` 30fps driver (`:32`). Keep `WaveFieldModel`/ripples *only if*
  P2's reticle is not adopted; if P2 lands, delete ripples too
  (`AppEnvironment.swift:488-491`). Under `reduceMotion`, ensure *no* ambient
  remains.
- **Why:** Direct spec violation (`design-spec.md:86-87,110`); continuous CPU
  cost (§2.3); collides with the reticle.
- **Effort:** S.
- **Depends on:** P2 (if reticle lands, ripples are redundant and go too).

### P5 — Settings rows as compact horizontal rows, not 300pt cards (M)
- **What:** Add `XMBItem.Kind.settingRow` (or a dedicated settings surface);
  render rows as icon-capsule + title + middle-truncated mono detail path
  (`plan-ui-ux-improvements.md:141-142`). Stop routing settings through
  `cover()` (`XMBView.swift:208-246`).
- **Why:** Settings are chrome, not content (§2.5); the question-mark card is
  illegible and breaks the type split.
- **Effort:** M.
- **Depends on:** none; independent of P1 (works in either layout). Do this
  regardless of the layout decision.

### P6 — Drop persistent controller hints; add jump-to-letter/search (M)
- **What:** Remove `ControllerHints` from the XMB header (`XMBView.swift:43,314-333`);
  keep contextual hint pills only on overlays. Add a hold-Options → letter rail,
  or a Search quick-bar item, for long libraries.
- **Why:** Persistent hints are noisy and non-console-conventional (§2.6); the
  cold-path navigation friction (§2.2 Path C) is unresolvable without search.
- **Effort:** M (hints S; search M).
- **Depends on:** none for hints; search benefits from P1 (a filmstrip has a
  natural "jump to letter" position; a vertical list does too but less cleanly).

### P7 — Kill the ambient CPU cost safely (S, subset of P4)
- **What:** If P4 is deferred, at minimum pause the `TimelineView` when no
  ripples are active and gate `drawRipples` under `reduceMotion` (currently
  ripples use real `t` even when waves freeze, `scout-ui-audit.md:5.2`).
- **Why:** Cheap correctness/power win with no UX change.
- **Effort:** S.
- **Depends on:** none.

---

## 5. Risk Assessment

### 5.1 Hard invariants that must be preserved (from the arch skill)

Any layout change must not break:

1. **Selection preview panel is additive** (arch skill invariant 10) — it must
   not modify `XMBNavModel`, input routing, or the item bar layout. Under P1,
   the panel's *logic* (debounced screenshots/playtime) is reused inside the
   hero, but the *additive* contract means the hero must be driven by the same
   selection state, not a new interaction. **Risk: medium.** Mitigation: the hero
   reads `nav.selectedItem?.entry` exactly as the panel does today
   (`XMBView.swift:159`); no new input path.
2. **Hold-to-repeat** (invariant 9): d-pad/L1/R1/sticks auto-repeat at 12/s after
   0.4s; confirm/back stay edge-triggered. **Risk: low** for P1 — left/right
   walking a filmstrip repeats identically to walking a vertical list; the
   `RepeatPacer` is action-based, not axis-based. Verify confirm stays
   edge-triggered (it does, `XMBNavModel.handle` returns only on `.confirm`).
3. **`@convention(c)` / libretro ABI** (invariants 1–3): untouched by any UI
   change. **Risk: none.**
4. **Game handoff = `NSApp.hide`** (invariant 6): untouched by UI layout.
   **Risk: none.**
5. **Bundle id / naming** (AGENTS.md): untouched. **Risk: none.**

### 5.2 Blast radius of the layout change (P1)

- **`XMBView.swift`** is substantially rewritten (item bar → hero+filmstrip;
  rail moves left). This is the largest single file in the change but it is
  *pure presentation* — it consumes `XMBNavModel` (selection state) and
  `AppEnvironment` (input) which do **not** change shape. `XMBNavModel.left()/
  right()` currently switch *categories*; under P1 they would walk the
  *filmstrip* and L1/R1 would switch categories. **This is a semantic change to
  the d-pad mapping** and is the one place input behavior shifts. It must be
  verified against the DualSense muscle-memory expectation: in the spec, left/
  right = filmstrip (items), and the rail is navigated by L1/R1 or up/down on
  the rail. **Risk: medium** — get the d-pad↔shoulder mapping right or it
  regresses navigation.
- **`Theme.swift`**: `itemCoverWidth`/`itemCoverAspect` change; type tokens
  unchanged. **Risk: low.**
- **`SelectionPreviewPanel`**: logic preserved, view placement changes (into the
  hero) or the view is retired. **Risk: low** as long as `SelectionPreviewModel`
  debounce/caching is reused unchanged.
- **`AppEnvironment` router** (`AppEnvironment.swift:311-327`): the
  `.left/.right/.previousPanel/.nextPanel` mapping is the only thing that may
  move. **Risk: medium** — this is the input contract; changing it affects
  keyboard parity and the quick-bar.
- **Tests:** `make build && make test && make selftest` are the gate
  (`AGENTS.md` §4, §7). `make selftest` exercises the mock-core emulator path,
  not the XMB, so it is unaffected; `make test` (unit assertions) covers
  VDFParser/RomTitle/PixelConverter/ids/PlaytimeFormatter — none touch layout.
  **So the automated gate will *not* catch layout regressions.** This means a
  manual DualSense pass over every screen is mandatory after P1/P2/P3 — the
  plan's "DualSense pass over every screen" verification
  (`plan-ui-ux-improvements.md:170`) applies and is *not optional* here.

### 5.3 Specific risks per recommendation

- **P1 (filmstrip):** the d-pad↔shoulder remap is the real risk. If left/right
  stays "category" (current), the filmstrip can't be walked by d-pad and the UX
  is worse. Decide the mapping deliberately and document it. Secondary risk:
  the `matchedGeometryEffect` id-namespace warning (`scout-ui-audit.md:5.3`,
  ids recur across category rebuilds) must be fixed (`"\(cat.id)-cover-\(item.id)"`)
  *during* the rewrite, or it carries forward.
- **P2 (reticle):** `matchedGeometryEffect` for the brackets must share a
  namespace with the focused card; under `reduceMotion` the brackets should
  appear without the spring (spec: "instant crossfade only," `:89-90`). Risk:
  three animation systems fighting (`scout-ui-audit.md:2.4`) — pick *one*
  mechanism (matched geometry) and drop the per-view `.opacity` transitions.
- **P3 (color):** low risk, but a full visual pass is needed because `cat.accent`
  is threaded through many views; a missed site leaves a stray violet/coral.
- **P4 (remove waves):** trivially safe (it's behind everything,
  `allowsHitTesting(false)`, `WaveField.swift:40`). Only risk: if users have come
  to expect the motion, removal reads as a regression — but the spec says they
  shouldn't have it.
- **P5 (settings rows):** independent and safe; the only risk is the
  `XMBItem.Kind` enum widening affecting `switch` exhaustiveness elsewhere
  (`XMBView.cover()`, `:212-235`).
- **P6 (search):** a letter-rail overlay is additive; risk is keyboard-focus
  parity (keyboard is currently controller-fallback only,
  `plan-ui-ux-improvements.md:86`).

### 5.4 What could go wrong, summed up

The chief danger is **doing P1 without P2/P3/P4** — a filmstrip without the
reticle, still cyan, still over a wave field, is "a different bad layout" rather
than the spec's intended machine. P1, P2, P3, P4 are a *coherent set* and should
land together (or P1+P4 first, P2+P3 immediately after). Landing them piecemeal
across many milestones risks an extended period where the shell is half-spec,
half-XMB, which is worse than either pure state.

The secondary danger is **trusting the automated gate** for a layout change it
cannot see. `make build/test/selftest` will stay green through a visually broken
filmstrip. A screenshot review + DualSense pass is the real verification and
must be treated as a release blocker for P1/P2/P3.

---

### Bottom line

The implemented XMB is a defensible *prototype* that diverged from a stronger
spec, and the divergences (vertical portrait list, ambient waves, multi-accent,
no reticle, settings-as-cards) are each individually fixable but collectively
point at the same conclusion: **the item axis should be a horizontal filmstrip
with a hero art stage and an amber focus reticle, the category nav should be a
left rail, and the ambient wave field should go.** That is the spec, and the spec
was right. The fonts (Chakra Petch / JetBrains Mono) and the additive preview-
panel architecture are the parts worth keeping; nearly everything else in the
presentation layer should move toward `design-spec.md`.
