# UI Audit — Text Cutoffs & Transitions

Scout (read-only) audit of the current frontend UI vs `docs/design-spec.md`.
Scope: `Sources/GameDock/UI/` + the AppEnvironment / ControllerManager plumbing
that feeds them. Findings are categorized and cite `file:line`. One-line fixes
only; no code was written.

> Context: the built Home screen (`HomeView.swift`) is still the **old** design
> (top tab pills, rounded corners, PS-blue accent), NOT the new rail+hero+
> filmstrip spec. Theme.swift is also still the old blue/rounded palette, and
> SF Mono / chrome type is not used anywhere. Those are spec-gap findings, not
> bugs per se, but they are the backdrop for several layout mismatches below.

---

## 1. TEXT CUTOFFS

### 1.1 Card title hard-capped to 1 line vs spec's 2-line requirement
`Sources/GameDock/UI/HomeView.swift:319`
`GameCardView` sets `.lineLimit(1)` on the card title. The spec (design-spec §
"Text — never cut off": "Card titles: `lineLimit(2)`") explicitly requires two
lines. Two-line titles ("Persona 3 Portable", "Sly 2: Band of Thieves", far-future
Steam titles like "Sherlock Holmes: The Awakened") will ellipsize at one line,
clipping content that the spec says must wrap.
Fix: `.lineLimit(2)` on line 319, and raise `Theme.cardWidth`'s title well so 2
lines fit (card frame at 321 has no reserved title height — see 1.3).

### 1.2 Card frame gives the title NO height budget
`Sources/GameDock/UI/HomeView.swift:321`
`.frame(width: Theme.cardWidth)` caps the whole card at cardWidth but the title
`Text` is unbounded in height — with `lineLimit(1)` it's a single line, but the
row of 1-line titles below a 148pt art tile is tight. When 1.1 changes to 2
lines, this frame will let the title squeeze the carousel row vertical rhythm.
Fix: give the title a fixed/ideal height region (e.g. `frame(height: 40, alignment:.top)`),
or keep card title inside a fixed-height VStack that allows 2 lines.

### 1.3 Hero title `lineLimit(2)` while spec wants 3
`Sources/GameDock/UI/HomeView.swift:206`
The hero art overlay title (the *big* text, 34pt heavy) is `.lineLimit(2)`.
design-spec says "Hero title: `lineLimit(3)`". Long titles that should wrap up
to 3 lines will ellipsize at 2. Inside a 640×360 frame (line 221) with the
play-cue row, 3 lines of 34pt heavy (~41pt line height ≈ 123pt) + platform pill
(~22pt) + padding (22×2) ≈ 189pt of the 360pt art height — it fits, so this is
a safe spec-alignment change.
Fix: `lineLimit(3)` at line 206.

### 1.4 Settings folder path detail is middle-truncated to ONE line
`Sources/GameDock/UI/SettingsView.swift:148`
`.lineLimit(1).truncationMode(.middle)` on the folder `detail` shows only the
head/tail of a full absolute ROM path (`/Users/…/ROMS/Persona 3…`). The spec's
"hint: sized to fit / single line" is about hint chrome, but the *folder path*
is actionable diagnostic data and middle-truncation on line 146-148 makes a long
mount point unreadable (you can't tell which folder you'd be removing). The spec
forbids middle-truncation on visible titles.
Fix: wrap path to 2 lines with trailing truncation, or lead-truncate only the
interior (`/Users/…/ROMS`) while keeping the last 2 components visible.

### 1.5 PPSSPP app row detail is a 1-line absolute path with a trailing suffix
`Sources/GameDock/UI/SettingsView.swift` (row built at ~line 42)
The `standaloneApp` detail is `"<name>.app — /Users/…/PPSSPPSDL.app"`. With
`.lineLimit(1)` + middle truncation (1.4 applies to every row's detail) the
" — path" suffix can get cut, hiding the app name that the row's title already
shows is redundant — but the *path* part is what matters for the user finding
the app. Same fix as 1.4.)

### 1.6 Hero hint column can exceed its 380pt budget on small windows
`Sources/GameDock/UI/HomeView.swift:250` + `:221`
`.frame(maxHeight: 380)` wraps the HStack containing the **fixed 640×360** art
frame (`:221`) plus the details column. The 360pt art + detail column content
(hints at `:251-262`) shares the same 380pt cap. If the window is at the
`defaultSize` (1280×800, fullscreen) this is okay, but the heights are
independent — the details column has `Spacer()`s so it compresses, but on a
shorter screen (after the top bar + panel padding) the row can clip the bottom
hint rows. This is a **fixed-height-battles-flex-height** hazard.
Fix: replace the fixed `640×360` with an `aspectRatio(16/9)` and let the row
height follow the available vertical space.

### 1.7 Empty-state / "No games" hint text width-guarded but not min-scaled
`Sources/GameDock/UI/HomeView.swift:170` (`.frame(maxWidth: 480)`)
The long hint paragraph is center-aligned with a 480pt cap — fine on 1280
width, but at reduced fullscreen window sizes the two-line hint can wrap to a
third line and overlap the icon if vertical space is tight. Spec wants hints
"sized to fit". Minor.
Fix: add `.minimumScaleFactor(0.85)` as a small-window safety net.

---

## 2. TRANSITIONS

### 2.1 `.animation` on `tabPill` uses a spring, but the pill is in the top bar
`Sources/GameDock/UI/HomeView.swift:104`
`.animation(.spring(response: 0.3, …), value: active)` animates ONLY the pill
background/fill change on panel switch. Design-spec motion says panel switch is a
slide+crossfade with a separate rail bar; here the switch animates the pill but the
pill itself is being removed from the "panel" slide. The result is a pill that
visually pops while the whole panel area slides — two different motions at once.

### 2.2 Panel transition relies on `ForEach` + single-branch insert — boundary pop
`Sources/GameDock/UI/HomeView.swift:108-122`
`panelArea` renders only `panels[panelIndex]` inside a `ForEach(panels.indices)`.
The `.transition(slideTransition)` + `.animation(spring, value: panelIndex)` is
the documented pattern, BUT: because only the selected index's view exists, the
*removal* branch at the same id sometimes has no view to transition, so the
outgoing panel can vanish instantly (no slide-out) while the incoming slides in
— an asymmetric slide that reads as a jump on rapid L1/R1 taps. Also
`slideDirection` is set in the model on the same runloop tick the index changes,
so the `.transition` computed from `slideDirection` is evaluated with the new
index but the OLD direction value on the very first frame.
Fix: key each panel content `ForEach(obj.id)` and drive the transition off a
stable id + direction captured in the view (or use a matchedGeometryEffect on the
panel frame).

### 2.3 Carousel `scrollTo` + `scaleEffect` spring of the focused card fight
`Sources/GameDock/UI/HomeView.swift:287-294` (scrollTo) and `:313-314`
On selection change, `withAnimation(.easeOut 0.2)` `scrollTo`s the card while
the card simultaneously runs an independent `.spring(0.25)` on `scaleEffect`.
Two competing animations over roughly the same window → the focused card can
"vibrate" slightly at rest while the scroll and the 1.05 scale converge. This is
the classic scroll+scale double-animation glitch.
Fix: animate scale via the same `withAnimation` transaction, or gate the scale
spring off scroll completion (scroll ends first, then scale).

### 2.4 No `accessibilityReduceMotion` guard anywhere
`Sources/GameDock/UI/HomeView.swift:104,122,287` / `:314`, `QuickBarView.swift:79`
None of the springs or slides are wrapped in `accessibilityReduceMotion`.
design-spec § Motion: "Reduce-motion: all springs/slides → instant crossfade only."
With Reduce Motion enabled the panel slide (2.2) and card scroll+scale (2.3) still
spring — a spec violation and a real discomfort for that user class.
Fix: read `@Environment(\.accessibilityReduceMotion)` in HomeView/QuickBarView and
switch to `.easeOut(0.15)` / plain transitions when true.

### 2.5 Wrap-around panel switch slides the wrong visual direction
`Sources/GameDock/UI/HomeNavModel.swift:47-58`
`previousPanel()`/`nextPanel()` hardcode `slideDirection = .backward` / `.forward`
regardless of the *actual* index delta. After a wrap (L1 from panel 0 → last, or
R1 from last → 0) the modulo arithmetic moves the content one way while the slide
transition (HomeView slideTransition, decided by `slideDirection`) animates the
opposite way — DS→Home on R1 appears to scroll backward. The direction must be
computed from `newIndex - oldIndex`, not the action name.
Fix: set `slideDirection` from the computed index delta (with modulo wrap math),
not from the action that triggered it.

### 2.6 `EmulatorScreen` has no transition on screen switch
`Sources/GameDock/UI/RootView.swift:13-25`
`switch env.screen` swaps home/settings/emulator with no `.transition` or
`.animation` on the root ZStack. Rapid handoff minimze→Steam→restore pops the
emulator in/out with zero smoothing, and the quick-bar/error overlays (`:27-45`)
are NOT wrapped in any fade. Result is jarring state flips.
Fix: add `.transition(.opacity)` + `.animation(.easeInOut(0.2), value: env.screen)`
on the switch content.

---

## 3. FOCUS / SELECTION

### 3.1 Hero art title and card do not share selection state — hero ignores carousel focus on wrap
`Sources/GameDock/UI/HomeView.swift:203-216`, HomeNavModel `handle(_:)`
The hero subtitle reflects `nav.selectedGame ?? panel.games[0]` (`.selectedGame`
already clamps), so hero follows selection. But on **panel switch** (`previousPanel`/
`nextPanel`) `clampSelection()` only clamps the new panel's index — it does NOT
reset `selection`, so if panel A had 16 games (selection 12) and you L1 to panel B
with 3 games, `selectedGame` clamps to 2 but the carousel `nav.selection == idx`
(HomeView:297) still holds 12 while `clampSelection` fixed it to 2 only in the
model — the hero and carousel can momentarily disagree, and the focused card is
the wrong one until the next `onChange`.
Fix: have `clampSelection()` also `selection = min(selection, count-1)` BEFORE
publishing panel switch (it does clamp, but the hero and carousel read the same
value — verify the clamp is observed before the view draws — the ordering issue is
that `panelIndex` publishes before `selection`, so one frame draws mixed).

### 3.2 Selected-card scale (1.05) pushes layout, no inset reserved
`Sources/GameDock/UI/HomeView.swift:313`
`.scaleEffect(isSelected ? 1.05 : 1.0)` scales the artwork up 5% *inside* the card
frame, so the art visibly overflows its rounded-corner bounds and its outer border
thickens off-clip — the top/edges of the upscaled art get clipped by the card's own
frame. design-spec says the focus reticle should be the scaling cue, and the card
grows into reserved space, not clip.
Fix: scale the whole card (title + art) or inset the art frame by the scale so the
border/glow render inside, not clipped.

### 3.3 Quick-bar item title uses `.hintFont` + `.fontWeight` — long item ellipsizes
`Sources/GameDock/UI/QuickBarView.swift:66-68`
"Recently Played" (16 chars) at `hintFont` (13pt) in a pill: the HStack is not
`.fixedSize()` and the bar container isn't width-wrapped, so on a ≤1280 window the
four pills + titles can exceed width and "Recently Played" clips at the trailing
edge. `.scaleEffect(1.06)` (line 78) on the selected item also grows overflowing
text.
Fix: `.fixedSize()` on each item's Text, and reduce horizontal padding of the bar
or scale font up, so the longest label fits on the smallest supported window.

### 3.4 Settings selection can go out of range after a rebuild mid-navigation
`Sources/GameDock/UI/SettingsView.swift` + `SettingsNavModel.rebuild`
When `romFolders` changes (folder add/remove), `rebuild` re-runs and re-clamps
`selection` (it preserves `selection` if still valid, else 0). But the view's
`.onChange(of: model.selection)` at `:117` calls `proxy.scrollTo("setting-\(rows[newSel].id)")`
— if the row list shrank so `newSel` is beyond `rows.count` at the moment of the
scroll, `rows[newSel]` (SettingsView:119) index-faults. `rebuild` sets selection
through `selectionIsValid` before publishing, but the `onChange` fires on the
*new* selection while `rows` was just replaced — ordering is not guaranteed.
Fix: guard `newSel` against `rows.count` before indexing in the `onChange`.

---

## 4. LAYOUT (notch / safe area / overlap)

### 4.1 Top bar padding does not respect the notch / titlebar safe area
`Sources/GameDock/UI/HomeView.swift:57` (`.padding(.top, 18)`)
The window is fullscreen (`AppDelegate` toggle). On a MacBook with the notch the
top bar's `.padding(.top, 18)` is a fixed offset, not `safeAreaInset`/`safeAreaPadding`,
so the wordmark + tab pills can sit under the display cutout on notch models and
the home-screen content ignores `ignoresSafeArea` boundaries it shouldn't entirely.
The background uses `.ignoresSafeArea()` (fine) but the content should offset by the
safe-area top inset.
Fix: use `.safeAreaPadding(.top)` (or read `environment(\.safeAreaInsets).top`) in
place of the literal 18.

### 4.2 Emulator hint rows overlap bottom safe area / not content-aware
`Sources/GameDock/UI/EmulatorScreen.swift:31-36`
Bottom hints (`PS · quick bar`, `Share · Discord`) are pinned to the bottom of the
fullscreen layer with `.padding(24)` but no safe-area bottom inset — on a notch
Mac they can sit into the bottom rounded-corner region. Also both hint pills are
in a plain HStack with no min spacing guard, so a narrow window overlaps them.
Fix: `.padding(.bottom, safeAreaInsets.bottom + 24)` and put hints in a spacing-safe
HStack.

### 4.3 `EmulatorView` Metal surface ignores safe area while overlay does not
`Sources/GameDock/UI/EmulatorScreen.swift:15-18`
`Color.black` + `EmulatorView` both `.ignoresSafeArea()` (good, letterbox is
handled in the renderer), but the overlay VStack is NOT ignoresSafeArea, so on a
notch display the top-left title sits below the notch while the Metal content
fills past it — a misalignment mismatch between where game content ends and where
the title chrome begins.
Fix: keep the overlay aligned to the Metal view's safe frame (match the top inset
the renderer uses for letterboxing).

### 4.4 Error banner is stacked above the quick-bar overlay with no z-relationship
`Sources/GameDock/UI/RootView.swift:27-45` vs `:27` quick bar `zIndex(10)`
The error banner uses `.zIndex(20)` and quick bar `zIndex(10)`, so an error can
draw on top of the quick bar. Both are in the same root ZStack; if a "Couldn't
launch PPSSPP…" error fires while the quick bar is showing (launch after quick-bar
discord toggle), the banner covers the pills. Low severity, but ordering is
arbitrary.
Fix: decide one stacking order (banner either above for visibility, or below).

---

## 5. CRASH RISK / SWIFTUI WARNINGS

### 5.1 `settingsNav` `onChange` indexes rows without a bounds guard (crash)
`Sources/GameDock/UI/SettingsView.swift:119` — `proxy.scrollTo("setting-\(model.rows[newSel].id)")`
Index-fault risk described in 3.4. Swift/`rows[newSel]` traps when out of range.
Fix: guard `newSel < model.rows.count` before evaluating.

### 5.2 `hero` uses `?? panel.games[0]` when `games` is empty inside non-empty branch
`Sources/GameDock/UI/HomeView.swift:201`
`hot(panel)` is only called from `panelContent` when `!panel.games.isEmpty` (line 190),
so `panel.games[0]` never traps today — but it's a fragile local assumption if a
future caller invokes `hero` directly. Low risk; the guard is one `if games.isEmpty`
away.
Fix: leave as-is or add a defensive `if panel.games.isEmpty { EmptyView() }`.

### 5.3 `ForEach` over `panel.games.enumerated()` with `.id("card-\(idx)")` — index-keyed
`Sources/GameDock/UI/HomeView.swift:288-292`
Card id is index-based (`"card-\(idx)"`); when a scan updates `games` the ids shift
and SwiftUI treats them as new, dropping scroll position and re-triggering the
`onChange` scroll. Also `.id(game.id)` on the hero (`:266`) changes with panel.
This is a correctness/glitch warning, not a crash.
Fix: key the ForEach by the stable `game.id` and scrollTo the game id.

### 5.4 `EmulatorView.updateNSView` swaps `frameSlot` on a nil session
`Sources/GameDock/UI/EmulatorView.swift:18`
`updateNSView` sets `nsView.frameSlot = session?.frameSlot`; when `session` is nil
(mid-teardown) frameSlot becomes nil and the renderer draws a cleared slot — the
screen blinks black on normal exit. Not a crash, but a visible hitch on `B → quit`.
Fix: guard `session != nil` before nilling frameSlot during teardown.

---

## Design-Spec Deltas (not bugs, but the source of most layout mismatches)

- **Theme.swift is the pre-makeover palette** (blue accent, rounded fonts). The
  spec's void/panel/raised/ivory/ash/amber palette, SF Mono chrome, and "no
  rounded" guidance are unimplemented. Most text/type decisions in 1.x hang off
  this.
- **Home layout is old tabs, not the rail/hero/filmstrip** spec; the slide panel
  transition (2.2) is the old layout's mechanism and will be replaced by the
  reticle-driven card focus when the makeover lands — worth rebuilding rather than
  patching 2.2/2.3 in place.
- **`minimumScaleFactor(0.82)` safety net** from the spec is not applied anywhere
  (only the Settings path row has any truncation safety).

---

### Suggested precedence for the worker
Fix crashes first: 3.4 + 5.1 (bounds guard), 2.5 (wrong slide direction). Then the
spec-guaranteed text caps: 1.1 + 1.3 (line limits 2→3 / 1→2). Then motion de-rumble:
2.2 + 2.3 + reduce-motion (2.4). Then safe-area (4.1, 4.3). The Theme/layout deltas
are the makeover scope and should be handled as part of that effort, not as isolated
point fixes.

UI AUDIT DONE
