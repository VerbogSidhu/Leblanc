# UI Audit — Text Cutoffs & Transitions (current XMB shell)

Scout (read-only) audit of the **current** frontend UI vs `docs/design-spec.md`.
Scope: the present XMB-based shell (`Sources/GameDock/UI/XMBView.swift`,
`XMBNavModel.swift`, `QuickBarView.swift`, `RootView.swift`, `EmulatorScreen.swift`,
`ArtworkView.swift`, `SettingsNavModel.swift`, `Theme.swift`) plus the
`AppEnvironment` / `ControllerManager` routing that feeds them.

> Note: an earlier `scout-ui-audit.md` audited the **removed** design
> (`HomeView.swift`, `SettingsView.swift`, `HomeNavModel.swift` — none of which
> exist in `Sources/GameDock/UI/` anymore). That audit is stale; this is the
> audit of the live XMB code. The spec's rail+hero+filmstrip layout and the
> amber phosphor palette are **not** what is implemented (the shell is a large
> portrait-cover XMB list); several findings below are the spec-gap backdrop
> that drives the clipping.

---

## 1. TEXT CUTOFFS

### 1.1 Selected-item title is 44pt × 3 lines in a `maxWidth: 460` frame — vertical clipping
`Sources/GameDock/UI/XMBView.swift:113-119`
`Theme.itemTitleSelected` is **44pt bold** (Theme.swift:40) with `.lineLimit(3)`
+ `.minimumScaleFactor(0.6)` inside `.frame(maxWidth: 460)`. Because the value is
top-aligned in the outer VStack and the item bar is not height-constrained, a
3-line 44pt title (~160pt) combined with the cover (1.3) overruns the ~670pt that
the 800-high fullscreen leaves after hints+rail. Long Steam titles ("Sherlock
Holmes: The Awakened") wrap to 3 lines and the bottom pushes off-screen / under the
bottom scrim. `.minimumScaleFactor(0.6)` is also the *only* text-safe it has and
it shrinks to 26pt when the frame is exceeded — visibly squished.
Fix: cap the selected cover at a fixed height (`frame(height:)`) and let the title
stay at normal size; drop the 0.6 min-scale.

### 1.2 Game covers use a portrait 0.70 aspect → absurdly tall, steals the vertical budget
`Sources/GameDock/UI/Theme.swift:49-50` + `XMBView.swift:111`
`Theme.itemCoverWidth = 300`, `Theme.itemCoverAspect = 0.70`, and the cover height
is `size / aspect` (XMBView:141) → **300 / 0.70 ≈ 429pt** for every game/action item.
The spec's 16:9 hero + card filmstrip would be ~170pt tall at 300 wide. 429pt of
cover is the single biggest driver of the overflow in 1.1. The portrait cover also
contradicts the spec ("each card ~230×130 art (16:9 fill)").
Fix: switch covers to a `16/9` aspect (e.g. `height = size * 9/16`) so selected
≈169pt, neighbors ≈54pt — the whole item bar fits in 670pt.

### 1.3 Neighbor covers at 96pt (→137pt tall) render **full-size**, not as peeking slivers
`Sources/GameDock/UI/XMBView.swift:94-104, 131-132`
`neighborView` uses `size: 96` → cover height = `96/0.70 ≈ 137pt`, and all 5 windowed
items (lo…hi, 2 above + selected + 2 below) render at full height in one VStack with
`spacing: 20`. On a category with ≥5 items the combined stack ≈ 1288pt in a ~670pt
viewport — every neighbor below the selected card renders fully off-screen and under
the gradient scrim (XMBView:39-45). The design intent ("neighbors peek") is not
realized because nothing clips the bar or shows partial covers.
Fix: clip the item bar to the visible band (`.clipped()`/`drawingGroup`) or render
neighbors at true sliver height so the peek is bounded.

### 1.4 Subtitle is unbounded height with `maxWidth: 520` — long meta lines push down
`Sources/GameDock/UI/XMBView.swift:120-126`
The `metaLine` (AppEnvironment) can be long: "Nintendo DS · last played Jan 3, 2025"
plus RA items carry `"gameTitle · 10 pts · 3 hr ago"`. `Theme.meta` is 13pt JetBrains
mono (Theme:45) and the Text has **no `lineLimit`** — a long subtitle wraps freely,
adding height to every card and worsening 1.1/1.3.
Fix: `.lineLimit(2)` + let it truncate (truncation is acceptable for a diagnostic meta
line), or give the subtitle a fixed height.

---

## 2. TRANSITIONS

### 2.1 One L1/R1 tap triggers TWO independent springs (rail + item bar) simultaneously
`Sources/GameDock/UI/XMBView.swift:61` + `XMBView.swift:104`
`nextCategory()`/`previousCategory()` (XMBNavModel:81,88) change BOTH `categoryIndex`
and `itemIndex` (reset to 0). The rail has `.animation(Theme.spring, value: nav.categoryIndex)`
(:61) and the item bar has `.animation(Theme.spring, value: nav.itemIndex)` (:104).
A single category switch therefore pops the rail and, on the same tick, springs the
whole item stack back to item 0 — two concurrent springs over two different glyphs
that read as a jarring double-motion. Also `jumpToCategory` (XMBNavModel:97-101)
used by quick bar paths does the same.
Fix: drive panel switch off a single `withAnimation(railSlide)` and rely on the
rail's own slide, delaying/removing the itemBar spring on category change (only
spring itemBar on itemIndex changes within a category).

### 2.2 No `.animation(value:)` on `RootView` for the quick bar / screen / error insertion point
`Sources/GameDock/UI/RootView.swift:7-49`
The quick bar `.transition(.move(edge:.top).combined(with:.opacity))` is declared on
`QuickBarView` (QuickBarView.swift:72), but the conditional is inserted into the root
ZStack with **no `.animation(value: env.quickBarVisible)`** and `gamepad(.openQuickBar)`
toggles the flag with **no `withAnimation`** (AppEnvironment). SwiftUI only fires a
`.transition` when the add/remove is animated, so the quick bar **appears/disappears
instantly** — the "slides in from the top" behavior never runs. Same for the
`.XMB ↔ .emulator` screen switch (RootView:14-21 sets `env.screen` with no animation)
and the error banner.
Fix: wrap the `switch` / quick-bar conditional in `.animation(Theme.spring, value: env.quickBarVisible)`
(+ `.animation(…, value: env.screen)`), or toggle `quickBarVisible`/`screen` inside
`withAnimation`.

### 2.3 `selectedItemView` fades `.opacity` but old selection pops out with no transition
`Sources/GameDock/UI/XMBView.swift:95-101,128`
The item window is a `ForEach(lo...hi, id: \.self)` where index identity determines
selected vs neighbor. Advancing the selection moves the old selected card's **index**,
so its identity flips from `selectedItemView` (has `.transition(.opacity)`) to
`neighborView` (no transition) — the outgoing card is torn down as a new identity and
vanishes instantly while the new one fades in. Also a card entering/leaving the
`lo...hi` window (moving ±3) appears/disappears with no transition because
`ForEach(id: \.self)` re-renders.
Fix: key covers by `item.id` and animate via the shared `.matchedGeometryEffect`
(XMBView:142) as the single source of truth; drop the per-view `.opacity` transition.

### 2.4 `matchedGeometryEffect` + parent `.animation` + `.transition` are three animation systems fighting
`Sources/GameDock/UI/XMBView.swift:104,128,142`
Every cover carries `matchedGeometryEffect(id: "cover-\(item.id)", in: coverNS)`
(:142) while the item bar also runs `.animation(spring, value: itemIndex)` (:104)
and the selected view runs `.transition(.opacity)` (:128). When `itemIndex` changes,
the same `item.id` cover must interpolate 96pt→300pt (matched geometry) *and* the
whole bar springs *and* the selected-to-neighbor identity shift fades/removes —
three competing animation drivers on one element. Rapid D-pad taps cause the cover
to "rubber-band"/flash as the springs and match-id disagree about the target frame.
Fix: pick ONE mechanism — keep `.matchedGeometryEffect` and remove the itemBar
`.animation` + `.transition` on the windowed items (let the match-id own the morph).

### 2.5 No `accessibilityReduceMotion` guard on the item-bar spring or quick-bar move
`Sources/GameDock/UI/XMBView.swift:104` (guarded) vs the **rail show spring**,
`QuickBarView.swift:72`
The itemBar and rail springs ARE guarded by `reduceMotion ? nil :` (good), and
`coverNS` matched geometry is **not** — matched-geometry morphs still run under
Reduce Motion. More importantly the default fullscreen panels use a `booted`
fade (XMBView:49) and the quick-bar uses `.move(edge:.top)` with no reduce-motion
fallback to plain crossfade as the design spec requires ("all springs/slides →
instant crossfade").
Fix: gate `matchedGeometryEffect` off when `reduceMotion` (fall back to plain
insertion), and make the quick bar `.transition(reduceMotion ? .opacity : .move…)`.

### 2.6 Quick bar `.animation(value: model.selection)` animates the strip, not its slide-in
`Sources/GameDock/UI/QuickBarView.swift:72-73`
The `.animation(Theme.spring, value: model.selection)` animates the selected-pill
highlight as you D-pad across the bar — correct. But it has **no effect on the
slide-in**, which is decided entirely by the parent insertion point (2.2). As written
the spring is harmless but the intended slide is dead; the reader may assume the
transition covers it. Group with the 2.2 fix.

---

## 3. FOCUS / SELECTION

### 3.1 Category switch resets `itemIndex` to 0 — loses per-category context on every L1/R1
`Sources/GameDock/UI/XMBNavModel.swift:81,88 (and jumpToCategory:97-101)`
Every panel switch and every quick-bar jump zeroes `itemIndex`. Combined with 2.1 the
selected game snaps to the top item of the new category on each shoulder tap — the 
"position in list" the spec frames as `03 / 16` state is discarded wholesale and the
selected-cover morph (2.4) runs the biggest 96→300 jump every panel switch. Not a
scroll-desync crash, but the selection is reset (not focused) and the spec's position
readout is absent.
Fix: keep `itemIndex` per-category (store a last-seen index map), reset only on an
explicit `jumpToCategory` from a quick-bar action.

### 3.2 Quick bar "Recently Played" and "Home" are the same category — no focused landing state
`Sources/GameDock/UI/QuickBarView.swift:15-25` + `AppEnvironment.swift:202-207`
`quickBarSelect(.recentlyPlayed)` and `.home` both call `selectCategory("home")`, so
picking "Recently Played" just lands on the Home category top item. If the recents
are meant to surface first, the selection should land on the first *recent* item, not
item 0 of the full Home stack. Redundant affordance = a confused focus jump.
Fix: differentiate the landing (jump to the recent item index) or drop the
"Recently Played" case.

### 3.3 Selected cover grows to 429pt but nothing reserves space – overflow clips, not scales
`Sources/GameDock/UI/XMBView.swift:111,141`
The "focused card" reads as the 300×429 selected cover among 137pt neighbors — but
out of the box it's simply the biggest in a top-aligned stack whose bottom clips
(1.1/1.3). The spec's intent (focus grows into *reserved* reticle space, never clips)
is unmet. There is no focus reticle (spec's amber L-brackets) implemented at all —
selection is signaled only by size + dim + a colored border stroke (XMBView:138-140).
Fix: when the makeover lands, reserve a fixed hero band for the selected card so
neighbors are true peek slivers and no text/art ever clips.

---

## 4. LAYOUT (notch / safe-area / overlap)

### 4.1 Top hint row uses a literal `.padding(.top, 18)` — sits under the display notch
`Sources/GameDock/UI/XMBView.swift:25`
The PS/Share hint glyphs are offset by a fixed 18pt, not the window's safe-area top
inset. On a notch MacBook in fullscreen the background fills under the cutout
(`.background(Theme.void.ignoresSafeArea())`, :47) but the hint row floats up into
it — glyphs overlap the camera housing.
Fix: `.padding(.top, 18 + (env.window safeAreaInsets.top))` (or
`GeometryReader`/`safeAreaPadding`).

### 4.2 Emulator bottom hints pinned with a fixed 22pt pad — no bottom safe-area inset
`Sources/GameDock/UI/EmulatorScreen.swift:36-38`
`HStack { hintPill("PS · QUICK BAR"); hintPill("SHARE · DISCORD") }.padding(.bottom, 22)`
ignores the macOS fullscreen bottom safe area; the pills can sit into the rounded
bottom region / home-indicator area, and on narrow windows two pills + `.tracking(1.2)`
can collide (zero min spacing guard).
Fix: `.padding(.bottom, safeArea.bottom + 22)` and allow the HStack to wrap or add
`minimumScaleFactor`.

### 4.3 EmulatorMetal content fills under the notch while the overlay chrome does not
`Sources/GameDock/UI/EmulatorScreen.swift:15-21` vs `:23-45`
`EmulatorView` + `Color.black` both `.ignoresSafeArea()`, but the VStack overlay is
**not** ignoresSafeArea — the top-left game-title/pill (`:23-31`) aligns to the safe
area while the game fills past it, so the title sits visibly lower than the content
it labels on a notch display. The letterbox/edge handling in the renderer and the
SwiftUI overlay use different coordinate conventions.
Fix: match the overlay's top inset to the Metal view's letterbox top (either both
ignoresSafeArea with matching manual insets, or neither).

### 4.4 Item bar overflow draws under the bottom `LinearGradient` scrim (unreadable content)
`Sources/GameDock/UI/XMBView.swift:39-45` (scrim) + `:94-104` (overflow)
The 220pt bottom gradient is drawn *over* the item bar, so every below-the-fold
neighbor cover / title (from 1.1/1.3) is dimmed to near-invisible under
`Theme.void.opacity(0.65)`. Content isn't just clipped off-screen — it's actively
darkened where it still peeks.
Fix: fold the clipping into the item bar itself (clip to the visible band) and keep
the scrim purely behind non-interactive space.

---

## 5. CRASH RISK / SWIFTUI WARNINGS

### 5.1 Long `maxWidth` title + `minimumScaleFactor(0.6)` can produce a one-line squeeze, not a crash
`Sources/GameDock/UI/XMBView.swift:117`
Wrapped with `lineLimit(3)` this is safe (no index trap). The only runtime risk is
Cosmetic — at 0.6 scale a 44pt title renders at 26pt, which for a 3-line heavy font
over a 460pt frame can exceed the frame height and clip regardless. Not a trap; fix
by removing the aggressive min-scale and capping the cover height (see 1.1/1.2).

### 5.2 `waveField` TimelineView runs a full-screen Canvas every render — idle cost, not a crash
`Sources/GameDock/UI/WaveField.swift:18-25`
`TimelineView(.animation)` redraws the whole canvas at display refresh even when
nothing changed (no selection ripples). Under `reduceMotion` waves freeze (`t = 0`)
but `drawRipples` still uses real `t` (WaveField:36) — ripple animation continues
indefinitely (bounded to 0.7s per ripple, so only while ripples exist). Not a crash,
but a continuous 60fps full-frame Canvas behind the UI on an always-on launcher.
Fix: pause the Timeline when there are no ripples and reduce-motion is on, or drop
to on-change redraw.

### 5.3 `matchedGeometryEffect` on every cover with a shared namespace can warn/glitch when categories change fast
`Sources/GameDock/UI/XMBView.swift:142`
Each cover registers `matchedGeometryEffect(id: "cover-\(item.id)", in: coverNS)`
but the id is only unique *within* a category. When `rebuildXMB()` (triggered on any
settings action / library rescan) replaces categories, ids recur across removed and
added views; SwiftUI logs the classic "multiple views have the same matched geometry
anchor" warning and the morph target can snap. Confirm at runtime under settings churn.
Fix: namespace the id by category, e.g. `matchedGeometryEffect(id: "\(cat.id)-cover-\(item.id)", …)`.

### 5.4 `RemoteImage` / `ArtworkView` use `@State` image set off-main, no main-actor hop
`Sources/GameDock/UI/RemoteImage.swift:43-44` (UI) and `ArtworkView.swift:27-44`
`RemoteImage.load` dispatches to `DispatchQueue.main` before setting `image` (good),
but `ArtworkView.load()` sets `@State image` from `ArtworkLoader` synchronously on
the current thread (`ArtworkView.swift:41-43`) — safe if `banner/cover` return on
main, but they're called from `.onAppear` (main) and `.onReceive` (main), so low
risk. No crash today; flagging the pattern.
Fix: keep as-is or hop `ArtworkView`'s state write to `MainActor` for safety.

---

## Design-spec deltas that drive the bulk of the layout bugs
- **The shell is an XMB portrait-cover list, not the spec's rail + 16:9 hero +
  filmstrip.** Most text-clip/overflow findings (1.1–1.4, 4.4) come from the 300×429
  cover axis, which disappears under the spec layout.
- **No focus reticle and no amber phosphor palette** (spec's signature + one-accent):
  selection is a colored border + size difference only. The "selected card scale-up text
  overflow" concern from the role brief does not apply — the shell never scales a card;
  it *grows the whole neighbor bar* instead, which is the overflow source.
- **`minimumScaleFactor(0.82)` safety net** (spec) is replaced by an over-aggressive
  `0.6` on the hero title only; no card/filmstrip min-scale exists because there's no
  filmstrip.

---

### Suggested worker precedence
1. Crash/log-first: 5.3 (namespace the matched-geometry id) — safest early fix.
2. Layout overflow (biggest visual bug): 1.2 → 1.3 → 4.4 (16:9 covers + bounded item
   bar + move scrim behind content).
3. Text caps: 1.1 + 1.4 (fixed cover height, 2-line limit on the meta line).
4. Transitions: 2.2 (RootView animation so quick bar/screen slide actually animate),
   2.1 + 2.4 (single animation driver), 2.5 (reduce-motion for matched geometry).
5. Safe area: 4.1 + 4.2 (top/bottom insets).
6. Focus: 3.1 (per-category item memory) — align with the makeover when it lands.

The Theme/rail/hero/filmstrip makeover swaps most of 1.x and 2.x wholesale — those
should be rebuilt with the spec, not patched in place.

UI AUDIT DONE
