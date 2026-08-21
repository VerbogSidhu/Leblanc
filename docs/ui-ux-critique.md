# Leblanc UI/UX Critique — Spec-vs-Implementation Gap & Paradigm Evaluation

**Scope**: Read-only audit of the live SwiftUI shell (`Sources/GameDock/UI/*.swift`), the input router (`AppEnvironment.swift`), the design spec (`docs/design-spec.md`), and existing audit work (`scout-ui-audit.md`, `plan-ui-ux-improvements.md`, `audit-preview-qol.md`). No source files were edited. All claims cite real code.

---

## 1. The Spec-vs-Implementation Gap (lead finding)

The shipped UI is **not** the UI in `docs/design-spec.md`. They differ on every axis that defines a product's visual identity: layout, palette, typography, signature element, and motion philosophy. This is not a partial implementation with a few tokens drifted — it is a different design.

### 1.1 Layout: rail+hero+filmstrip vs. horizontal-rail+vertical-cover-list

| Aspect | Design spec (`design-spec.md`) | Implemented (`XMBView.swift`) |
|---|---|---|
| Category nav | Left vertical rail, fixed ~220pt, full height (lines 61–64) | Horizontal `HStack` at the top (`XMBView.swift:85`) |
| Primary showcase | Hero, top ~58%, edge-to-edge art fill, title overlay (lines 65–69) | No hero. Selected item is a centered portrait cover + title below (`XMBView.swift:171–190`) |
| Item browse | Horizontal filmstrip of 16:9 cards (~230×130), bottom (lines 70–73) | Vertical `VStack` of portrait covers, 2 above / selected / 2 below (`XMBView.swift:136–153`) |
| Position readout | `03 / 16` mono eyebrow on hero (line 68) | Count badge on the rail tab only (`XMBView.swift:106–113`); no per-item position |

The spec's layout is a magazine-spread: rail frames the left, hero dominates, filmstrip previews neighbors horizontally. The implementation is a PSP/PS3 XMB: categories march across the top, items stack vertically beneath the selected one. These are structurally incompatible — you cannot get from one to the other by adjusting tokens.

### 1.2 Palette: warm amber phosphor vs. cool cyan signal

| Token | Spec hex | Implemented hex (`Theme.swift:7–13`) | Drift |
|---|---|---|---|
| Background (void) | `#0B0C10` | `#0A0D16` | Cooled toward blue |
| Panel | `#141418` | `#12172A` (ink) | Cooled toward blue |
| Accent | `#F2A93B` (amber) | `#4FD3FF` (signal, cyan) | **Inverted hue family** — warm → cool |
| Primary text | `#E9E6DE` (ivory, warm) | `#EDEFF5` (paper, cool) | Warm → cool |
| Dim text | `#6E6B63` (ash, warm) | `#8B93A7` (mist, cool) | Warm → cool |

The spec's entire identity thesis is "amber phosphor, warm ivory, anti the cool-cyan default" (lines 22–24, 106–107). The implementation **is** the cool-cyan default the spec explicitly rejects. `Theme.signal` (cyan) is used for selection, focus, active tabs, the empty-state CTA button, the volume bar, the "PAUSED" pill, and the quick-bar selected pill — exactly the "smeared accent" the spec warns against ("Amber is spent in ONE place at a time, the focus, never smeared" — line 27).

The secondary accents compound the drift: PSP is muted violet (`#9B8CFF`), DS is soft coral (`#FF8C8C`), Discord is periwinkle (`#7A86C8`). The spec envisioned a single-accent discipline; the implementation has six accent colors in play.

### 1.3 Typography: SF Mono + SF Pro Display vs. Chakra Petch + JetBrains Mono

The spec's "distinctive move" is **SF Mono** for all chrome (wordmark, rail labels, position readouts, hints) contrasted with **SF Pro Display** for game titles — "the launcher (machine) vs. the games (content)" (lines 31–38). It explicitly warns against `.rounded` and "friendly game UI" tells.

The implementation uses **Chakra Petch** (a techy angular geometric sans) for display/labels and **JetBrains Mono** for data (`GameDockFonts.swift:26–41`). Neither is an Apple system font. Chakra Petch is a reasonable choice for a "machine" aesthetic, but it is not the spec's choice, and it carries a different personality — angular/military rather than the spec's broadcast-operator-readout feel. `Theme.body` and `Theme.caption` fall back to `Font.system(size:)` (lines 46–47), so the type system is also inconsistent: custom fonts for titles/labels, system font for body text.

### 1.4 Signature element: the focus reticle is absent

The spec's "one memorable element" is the **focus reticle** — four amber L-shaped corner brackets that spring onto the focused card "like a viewfinder / target lock" (lines 75–81). A grep for `reticle` across all Swift sources returns **zero matches**. A grep for `filmstrip` returns **zero matches**. The signature moment of the entire design does not exist in the codebase.

The closest implementation equivalent is `matchedGeometryEffect(id: "cover-\(item.id)")` on the cover (`XMBView.swift:245`), which animates the cover scaling between neighbor and selected states. This is a smooth crossfade/scale, not a reticle snap. It is competent but not memorable.

### 1.5 Motion philosophy: "no ambient drift" vs. a permanent ambient wave field

The spec is explicit: "No ambient drift, no parallax shimmer (that reads AI)" (line 87). Motion is reserved for state changes only — panel switch, card focus, hero crossfade.

The implementation ships **`WaveField`** (`WaveField.swift`): five overlapping sine layers rendered at 30fps via `TimelineView(.periodic(from: .now, by: 1.0/30))` (line 32), perpetually animating behind everything, tinted toward the platform accent. This is exactly the "ambient drift" the spec prohibits. It also has a real CPU cost — the scout audit flagged it as "the dominant XMB CPU hotspot" (mitigated by widening the stride to 10px, `WaveField.swift:59`, but still a continuous 30fps redraw of a full-screen Canvas).

### 1.6 Verdict on the gap

This is not "the spec wasn't fully built." The spec was **superseded** by a different design direction (XMB + cyan + Chakra Petch + wave field) that was implemented in its entirety. The `design-spec.md` file is stale documentation describing a product that does not exist. Either the spec or the implementation is wrong about what Leblanc is — and right now, nobody reading both would know which is authoritative.

---

## 2. Weaknesses in the Current UI (beyond existing audits)

The existing audits (`scout-ui-audit.md`, `plan-ui-ux-improvements.md`) document text-cutoff bugs, missing animation scopes, and missing states. This section addresses **UX-level structural problems** not covered there.

### 2.1 A vertical portrait-cover list is the wrong model for a game library

The item bar renders portrait covers at `Theme.itemCoverWidth = 300` with `itemCoverAspect = 0.78` (`Theme.swift:50–51`), making the selected cover ~385pt tall. Neighbors render at 72pt (~92pt tall). Five items stack in a `VStack(spacing: 20)` (`XMBView.swift:136`).

The fundamental problem: **portrait capsule art is a Steam-grid convention, not a browsing convention.** Every successful console frontend uses landscape-oriented cards or tiles:

- **Steam Big Picture**: dense grid of portrait capsules, but many per screen (8–12 visible), not one-at-a-time.
- **PS5**: horizontal carousel of landscape cards, big hero on selection.
- **Switch**: grid of portrait tiles, but 12+ visible simultaneously.
- **Xbox**: hero + vertical list of landscape art.

Leblanc's model shows **one game prominently with two slivers above and below** — the lowest information density of any of these. In a 200-game Steam library, reaching game #150 requires ~150 d-pad-down presses (hold-to-repeat at 12/s = ~12.5 seconds of holding). There is no search, no jump-to-letter, no filtering, no sorting. A grep for `search` in the UI layer returns no search UI — only unrelated matches.

The portrait aspect also wastes the horizontal axis. On a 16:9 TV (1920×1080), the item bar occupies the center ~460pt column (`frame(maxWidth: 460)` on the title, `XMBView.swift:180`), leaving ~700pt of horizontal space on each side empty except for the preview panel on the right (300pt, `SelectionPreviewPanel.swift:18`). The left ~700pt is dead space.

### 2.2 The horizontal category rail fights DualSense left/right muscle memory — then rescues it

The category rail is an `HStack` at the top (`XMBView.swift:85`). D-pad left/right maps to `previousCategory`/`nextCategory` (`XMBNavModel.swift:93–94, 159–160`), and L1/R1 also switch categories (`XMBNavModel.swift:161–162`).

This is **internally consistent** with PSP/PS3 XMB muscle memory, where categories march horizontally and items stack vertically. The grammar is clean: left/right = which column, up/down = which row. This is the one thing the XMB gets right.

But discoverability suffers. The rail has no visual affordance that it extends beyond the visible tabs — there's no fade, no chevron, no "more" indicator. With 7 categories (Home, Steam, PSP, DS, Discord, Achievements, Settings) at `HStack(spacing: 42)` (`XMBView.swift:85`), the rail is wide but not obviously bounded. A new user cannot tell whether L1/R1 or d-pad left/right will do something at the edges (it wraps — `XMBNavModel.swift:104, 111` — but nothing communicates this). The wrap-around is a surprise, not a signal.

### 2.3 Settings-as-giant-cards is a UX category error

Settings rows (`SettingsNavModel.swift`) are rendered through the same `XMBItem` pipeline as games. `rebuildXMB()` maps each settings row to an `XMBItem(id: "setting-\(row.id)", ..., action: .settings(row.kind))` (`AppEnvironment.swift:362–367`). In `XMBView.cover()`, these resolve to `kind == .action`, rendering a 300pt-wide portrait card with a `Theme.ink` fill and a single SF Symbol glyph (`XMBView.swift:215–221`).

This means **"PSP ROM folders", "DS core", "RA Hardcore mode", "Rescan libraries"** each appear as a 385pt-tall card with a gearshape icon. The detail text (a file path like `/Users/verbog/Downloads/ROMS`) is the `subtitle`, rendered in 13pt JetBrains Mono below the title at `maxWidth: 520` (`XMBView.swift:186`).

This is wrong on multiple levels:
- **Scale mismatch**: a toggle ("RA Hardcore mode: on") occupies the same screen real estate as a game's cover art. The visual weight says "this is important content" when it's a boolean preference.
- **No interaction affordance**: there's no visible toggle, no checkbox, no "on/off" pill on the card. The user must know to press Cross to cycle it. The detail text "on"/"off" is the only signal.
- **File paths as subtitles**: long paths wrap freely (no `lineLimit` on the subtitle, flagged in `scout-ui-audit.md` §1.4), pushing the layout around.
- **No section structure**: "PSP ROM folders" header, folder rows, and "PPSSPP app" are all flat items in one list with no visual grouping.

The `plan-ui-ux-improvements.md` §4.7 already prescribes the fix (compact rows with `XMBItem.kind == .settingRow`), but it remains unimplemented.

### 2.4 The quick bar's discoverability and semantic overlap with the pause menu

The quick bar is summoned by the PS button (`GamepadUIAction.openQuickBar`, `AppEnvironment.swift:293–295`). It slides in from the top as a horizontal pill strip (`QuickBarView.swift:77–113`).

**Discoverability**: The PS button's existence is communicated only by the `ControllerHints` view — a "PS" wordmark in a 34×34 outlined box (`XMBView.swift:317–322`). There is no text label saying "quick bar" or "menu". A user who has never held a DualSense will not know what "PS" does. The Share glyph (`square.and.arrow.up.fill`) is even more opaque — nothing indicates it opens Discord.

**Semantic overlap**: While emulating, the quick bar (PS button) and the pause menu (Circle button, `AppEnvironment.swift:306–308`) are two different overlays that both pause the game and both offer overlapping actions:

| Action | Quick bar (PS) | Pause menu (Circle) |
|---|---|---|
| Save State | ✓ (`.saveState`) | ✓ (`.saveState`) |
| Load State | ✓ (`.loadState`) | ✓ (`.loadState`) |
| Reset | ✓ (`.reset`) | ✓ (`.reset`) |
| Core Options | ✓ (`.coreOptions`) | ✓ (`.coreOptions`) |
| Resume | — (dismiss via PS) | ✓ (`.resume`) |
| Quit Game | — | ✓ (`.quit`) |
| Go to Home/Discord/Settings | ✓ | — |

Two overlays with 4 overlapping actions is confusing. The user must remember that PS = "system stuff + save/load" and Circle = "game stuff + save/load." There is no visual or haptic signal distinguishing them when both are closed. The quick bar's contextual item list also changes between XMB and emulator contexts (`visibleQuickBarItems`, `AppEnvironment.swift:180–189`), so the same button surfaces different options depending on where you are — a hidden state change.

### 2.5 No search, no filtering, no sorting — unscalable past ~50 games

Confirmed by grep: no search field, no filter chips, no sort selector anywhere in the UI layer. The only library organization is the category split (Home/Steam/PSP/DS) and the Home category's favorites-first-then-recent ordering (`AppEnvironment.swift:384–396`).

Within a category, items are in whatever order `LibraryStore` returns them. For Steam, that's likely alphabetical by title or by appid. For ROMs, it's filesystem order. There is no:
- Text search (critical for 200+ Steam libraries)
- Genre/source filter
- Sort by name / last played / playtime / install date
- Jump-to-letter (hold Options → alphabet rail, as the plan §5.4 suggests)
- Favorites-only view (favorites are mixed into Home, not isolatable)

The hold-to-repeat pacer (12/s, `RepeatPacer`) makes scrolling tolerable up to ~50 items. Beyond that, the lack of any acceleration or jump becomes a real friction point. This is the single biggest scalability defect in the current design.

### 2.6 The wave field is an anti-pattern per the spec, and a CPU cost

`WaveField` (`WaveField.swift`) runs a 30fps `TimelineView` with a full-screen `Canvas` drawing 5 sine-wave paths, each filled to the bottom (lines 45–73). It is always animating, always present, behind everything.

The spec says: "No ambient drift, no parallax shimmer (that reads AI)" (`design-spec.md:87`). The wave field is ambient drift. It is also:
- **A CPU hotspot**: the scout audit flagged it; the mitigation was widening the stride from 5px to 10px (`WaveField.swift:59`), which halves but does not eliminate the cost. On a 1920px-wide screen, that's 192 line segments × 5 layers = 960 path operations per frame, 30 times per second, continuously, even when the user is idle.
- **Not paused when not visible**: `WaveField` does not check whether the XMB is on screen. While emulating (`screen == .emulator`), the XMB view is not rendered (RootView switches, `RootView.swift:9–18`), so SwiftUI stops drawing it — but only because RootView uses a `switch`, not an overlay. If the XMB were ever kept alive underneath, the wave field would keep burning CPU.
- **Reduce-motion only freezes `t`**: `reduceMotion ? 0 : context.date...` (`WaveField.swift:34`) freezes the wave phase but the `TimelineView` still fires 30fps and redraws identical frames. It should `pause` the TimelineView entirely under reduce-motion.

The ripples (`drawRipples`, lines 78–97) are the defensible part — they're event-driven (selection change emits a ripple, `WaveFieldModel.emit`). The idle sine layers are the anti-pattern.

### 2.7 Controller hints are unlabelled glyphs

`ControllerHints` (`XMBView.swift:314–333`) shows two glyphs: a "PS" wordmark box and a Share (`square.and.arrow.up.fill`) box. No text labels. The emulator screen has text hints (`EmulatorScreen.swift:67–71`: "PS · QUICK BAR", "SHARE · DISCORD", "TOUCHPAD · CAPTURE"), but the XMB — the screen a new user lands on — has only glyphs.

This fails learnability for anyone who hasn't internalized DualSense iconography. The glyphs also don't hint at the most important navigation actions (d-pad, Cross, Circle) at all. A first-time user sees a grid of game covers and two mysterious icons in the corner. Compare to PS5's always-present hint bar at the bottom showing context-relevant button→action mappings in text.

---

## 3. Would Leblanc Be Better With a Different UI?

### 3.1 Paradigm comparison

| Paradigm | Library fit | Art showcase | Nav grammar | Complexity | Verdict for Leblanc |
|---|---|---|---|---|---|
| **Current XMB** (vertical portrait covers) | Poor — 1 game prominent, slow scroll | Poor — portrait cover only, no hero | Good — matches PSP/PS3 muscle memory | Low | Works for <50 games, breaks at scale |
| **Spec** (rail + hero + filmstrip) | Good — filmstrip browses fast | Excellent — edge-to-edge hero + reticle | Medium — needs d-pad left/right = filmstrip, L1/R1 = rail | Medium-High | Best art showcase; 16:9 cards clash with portrait Steam capsules |
| **Steam Big Picture** (dense grid) | Excellent — 8–12 visible | Medium — no hero | Poor — grid nav is awkward on d-pad | Medium | Overkill for a console feel; desktop-y |
| **PS5** (horizontal carousel + hero) | Good — carousel scrolls fast | Excellent — big hero on selection | Good — left/right natural on d-pad | Medium | Strong contender; similar to spec but horizontal |
| **Hybrid** (XMB nav grammar + spec visual language) | Good — keep up/down items | Good — add hero above the list | Good — preserves muscle memory | Medium | **Recommended** — see §4 |

### 3.2 The XMB's real strength: the nav grammar, not the layout

The current XMB's one defensible virtue is its **navigation grammar**: left/right = categories, up/down = items, L1/R1 = accelerated category switch. This maps cleanly to the DualSense d-pad and matches PSP/PS3 muscle memory. The `XMBNavModel` routing (`XMBNavModel.swift:155–167`) and the hold-to-repeat pacer make this feel good in the thumb.

But the grammar is **orthogonal to the visual layout**. You can keep left/right=categories + up/down=items while changing everything else: the cover aspect ratio, the hero presence, the palette, the reticle, the wave field. The grammar doesn't require portrait covers in a vertical stack.

### 3.3 The spec's real strength: the hero + reticle, not necessarily the filmstrip

The spec's best ideas are:
1. **The hero** — edge-to-edge art that showcases a game's key art at scale. The current XMB has no hero; the selected cover is a 300pt portrait thumbnail. Steam games have landscape hero art (library hero banners, 460×215) that is completely unused.
2. **The focus reticle** — a signature, memorable interaction moment. The current UI has no signature moment; `matchedGeometryEffect` is invisible to anyone who isn't a SwiftUI developer.
3. **Position readout** (`03 / 16`) — structure as information. The current UI shows a count on the tab but no per-item position, so you never know where you are in a long list.

The spec's weak point is the **16:9 filmstrip of cards** (line 70: "~230×130 art (16:9 fill)"). Steam's primary capsule art is portrait (600×900, `p.png`), and the `ArtworkLoader` already prioritizes it (`ArtworkLoader` resolves `.cover` as portrait). Forcing 16:9 cards means either cropping portrait art (loses the cover composition) or letterboxing (the spec bans letterboxing, line 25 of `ArtworkView.swift`: "never `.fit`, which letterboxes"). PSP/DS box art is often square or portrait. The 16:9 assumption is Steam-landscape-centric and breaks for the emulator categories.

### 3.4 The wave field should go regardless of paradigm

Whether Leblanc keeps the XMB or adopts the spec, the ambient wave field should be removed or radically reduced. It contradicts the spec, costs CPU, and reads as decorative noise. The ripples (event-driven) can stay as a subtle selection-feedback layer; the idle sine layers cannot.

---

## 4. Concrete Recommendations (ranked by impact)

### R1. Adopt a hybrid: XMB nav grammar + spec visual language (HIGH impact, MEDIUM effort)

**Keep**: left/right = categories, up/down = items, L1/R1 = accelerated category switch. The `XMBNavModel` and `AppEnvironment.gamepad` routing stay as-is.

**Change the item bar** from a vertical portrait-cover stack to:
- A **hero zone** (top ~50% of the content area) showing the selected game's landscape hero art edge-to-edge, with the title overlay (heavy, proportional, `lineLimit(3)`) and a `03 / 16` position readout in mono. Use `ArtworkView(style: .banner)` — the banner style already exists (`ArtworkView.swift:7`) and `ArtworkLoader.banner(for:)` already resolves Steam header art.
- A **horizontal filmstrip** (bottom ~30%) of cards. Use portrait covers for games (matches Steam capsule art), 16:9 cards only where the art is landscape. Focused card gets the reticle (R2 below) + scale to 1.04 + accent glow.

This eliminates the vertical-space waste (portrait covers stacking), gives every game a hero showcase, and adds the position readout. The nav grammar is untouched.

**Files**: `XMBView.swift` (rewrite `itemBar`, `selectedItemView`, `neighborView` — lines 127–194), `Theme.swift` (add hero/filmstrip layout tokens). `XMBNavModel.swift` needs no change.

### R2. Implement the focus reticle (HIGH impact, LOW effort)

Add four L-shaped corner bracket views that spring onto the focused card. The spec describes them precisely (lines 75–81): amber, sharp corners, spring between cards.

```
// Pseudocode for the reticle, added to the focused card's overlay
ForEach([.topLeading, .topTrailing, .bottomLeading, .bottomTrailing], id: \.self) { corner in
    ReticleBracket(corner: corner, color: accent)
        .transition(.scale.combined(with: .opacity))
}
```

This is the signature moment. It is ~40 lines of SwiftUI and transforms the UI from "generic list" to "controller locked onto your game." The `@Namespace` (`XMBView.swift:12`) is already present and can drive the spring.

**File**: new `Reticle.swift` in `UI/`, wired into `XMBView.cover()` for the non-dimmed case (line 239).

### R3. Switch the palette to amber + ivory (HIGH impact, LOW effort)

This is a `Theme.swift`-only change (lines 7–13):

| Token | Current | Change to |
|---|---|---|
| `signal` | `#4FD3FF` (cyan) | `#F2A93B` (amber) — becomes the single accent |
| `paper` | `#EDEFF5` (cool) | `#E9E6DE` (warm ivory) |
| `mist` | `#8B93A7` (cool) | `#6E6B63` (warm ash) |
| `void` | `#0A0D16` (blue-black) | `#0B0C10` (neutral near-black) |
| `ink` | `#12172A` (blue) | `#141418` (neutral) |
| `ember` | `#FF9F4A` | Keep as a secondary "recently played" marker, or merge into amber |

Then audit every use of `Theme.signal` and ensure it appears in **one place at a time** (the focus), not smeared across the empty-state CTA, volume bar, PAUSED pill, and quick-bar selection simultaneously. The platform accents (pspAccent, dsAccent, etc.) can remain as small per-category tints, but the primary selection accent should be amber only.

**File**: `Theme.swift:7–24`.

### R4. Add search + jump-to-letter (HIGH impact, MEDIUM effort)

Without search, the library doesn't scale. Implement:
- **Hold Options (Start) → letter rail overlay**: a vertical A–Z strip on the right edge; d-pad up/down selects a letter; releasing jumps to the first title starting with that letter in the current category.
- **Triangle button → search**: a text field with on-screen keyboard (or keyboard input if connected). Filters the current category's items by substring match on title.

`GamepadUIAction` needs a `.search` case (Triangle is currently unmapped — `GamepadInput.swift` maps it to libretro id 1 but no UI action). The `XMBNavModel` needs a `filter(query:)` method that re-derives the visible items without rebuilding categories.

**Files**: `GamepadInput.swift` (add `.search`), `AppEnvironment.swift` (route Triangle), `XMBNavModel.swift` (filter state), new `SearchOverlay.swift`.

### R5. Render settings as compact rows, not cards (MEDIUM impact, LOW effort)

Already prescribed in `plan-ui-ux-improvements.md` §4.7. Add `XMBItem.Kind.settingRow` and render it as a horizontal row: glyph capsule + title + detail (mono, head-truncated path) + toggle pill for booleans. Section headers become non-selectable styled headers. This stops "RA Hardcore mode: on" from occupying 385pt of screen.

**Files**: `XMBNavModel.swift` (add `.settingRow` to `Kind`), `XMBView.swift` (new `settingRowView` in `itemBar`), `SettingsNavModel.swift` (mark rows with kind).

### R6. Remove or freeze the idle wave field (MEDIUM impact, LOW effort)

Delete the idle sine layers (`WaveField.drawWaves`, lines 45–73). Keep the ripples (`drawRipples`, lines 78–97) as a subtle selection-feedback layer, but freeze them under `accessibilityReduceMotion` (currently only the wave phase freezes, `WaveField.swift:34` — the TimelineView still fires). Alternatively, replace the wave field entirely with a static `Theme.void` background and let the reticle + hero art carry the visual interest.

**File**: `WaveField.swift` (remove `drawWaves` call at line 35, or delete the file and remove the `WaveField` reference at `XMBView.swift:17`).

### R7. Add context-relevant text hints to the XMB (MEDIUM impact, LOW effort)

Replace the glyph-only `ControllerHints` with a bottom hint bar mirroring `EmulatorScreen`'s pattern: "◀▶ CATEGORIES · ▲▼ BROWSE · ✕ PLAY · ○ BACK · PS MENU". Update dynamically based on context (e.g., "✕ OPEN" when an action item is selected vs "✕ PLAY" for a game). This makes the UI learnable without a manual.

**File**: `XMBView.swift:314–333` (`ControllerHints`).

### R8. Resolve the quick-bar / pause-menu semantic overlap (MEDIUM impact, MEDIUM effort)

Make the quick bar **system-only** (Home, Recently Played, Discord, Settings, Volume) and the pause menu **game-only** (Resume, Save, Load, Reset, Options, Quit). Remove Save/Load/Reset/Options from the quick bar's emulator item list (`AppEnvironment.swift:182`). This gives each overlay a single, non-overlapping responsibility: PS = "where do I go", Circle = "what do I do with this game."

**File**: `AppEnvironment.swift:180–189` (`visibleQuickBarItems`).

---

## 5. Summary Recommendation

Leblanc should **not** ship the current XMB as-is for a v1 aimed at real Steam libraries. The vertical portrait-cover list doesn't scale, wastes horizontal space, has no search, and renders settings as giant cards. But it also should **not** blindly implement the spec — the 16:9 filmstrip assumption breaks for portrait Steam capsules and emulator box art.

The right path is the **hybrid** (R1): keep the XMB's nav grammar (it's the one thing it gets right), but adopt the spec's visual language — hero art showcase, the focus reticle, the amber/ivory palette, and the position readout. Kill the wave field. Add search. Fix settings. This preserves the controller muscle memory while giving the product the signature identity and information density it currently lacks.

The single highest-leverage change is R2 (the reticle) + R3 (amber palette) — together they transform the visual identity in under 100 lines of code with zero nav-grammar risk. Start there.
