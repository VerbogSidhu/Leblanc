---
name: leblanc-ui-layer
description: The SwiftUI view hierarchy, Theme tokens, navigation models, overlay wiring, and input→UI flow for the Leblanc (GameDock) XMB shell and emulator screen. Use when adding a screen, overlay, Theme token, or modifying navigation, the WaveField, or reduceMotion handling.
---

# Leblanc — UI Layer

SwiftUI shell built around a horizontal XMB (category rail + vertical item
bar) and a fullscreen emulator surface. All UI is controller-driven through a
single input router. This skill documents the view tree, the design tokens,
the navigation models, the input flow, and the conventions an agent must
follow when touching UI.

> **Read `docs/design-spec.md` only as historical context.** That spec
> describes an amber-phosphor vertical-rail + filmstrip + focus-reticle
> design that was superseded. The *actual* tokens and layout are below and
> in `UI/Theme.swift`. Do not implement "to spec" — implement to code.

## View hierarchy

The root is `RootView` (`UI/RootView.swift`), a `ZStack` that switches on
`env.screen` and layers global overlays on top:

```
RootView (UI/RootView.swift)  — ZStack, animates overlay insertions
├─ switch env.screen
│  ├─ .xmb     → XMBView (UI/XMBView.swift)
│  └─ .emulator → EmulatorScreen (UI/EmulatorScreen.swift)  [if env.emulator != nil]
│                                   └─ EmulatorView (Metal) + its own overlays
├─ QuickBarView           (zIndex 10)  — env.quickBarVisible
├─ StartingOverlay        (zIndex 15)  — env.isLaunching (Steam/PPSSPP handoff)
├─ ConfirmationOverlay    (zIndex 25)  — env.pendingConfirmation
├─ errorBanner            (zIndex 20)  — env.activeError
└─ CaptureToastView       (zIndex 30)  — env.captureToasts (any screen)
```

**Important split:** global overlays (quick bar, error, starting, confirmation,
capture toast) live in `RootView`. Emulator-only overlays (CoreOptionsOverlay,
PauseMenuOverlay, boot "Loading core…" overlay) live in `EmulatorScreen`.
When adding an overlay, decide which group it belongs to and place it in the
matching `ZStack` — and add it to the input router (see below).

`EmulatorScreen` overlays (`UI/EmulatorScreen.swift`):
- `env.isLaunchingGame` → "Loading core…" boot overlay (branded spinner).
- `env.coreOptionsVisible` → `CoreOptionsOverlay(model: session.coreOptions)`.
- `env.pauseMenuVisible` → `PauseMenuOverlay(model: env.pauseMenu)`.
- A `PAUSED` pill appears whenever `coreOptionsVisible || pauseMenuVisible`.
- RA unlock toasts via `session.raToasts` → `toastPill(_:)`.

## Theme system (`UI/Theme.swift`)

`enum Theme` holds all design tokens as `static let`. Use these names
directly — never hardcode hex or substitute colors.

### Palette tokens

| Token | Hex | Use |
|---|---|---|
| `Theme.void` | `#0A0D16` | base background (fullscreen) |
| `Theme.ink` | `#12172A` | panels / surfaces / overlay backgrounds |
| `Theme.signal` | `#4FD3FF` | **primary accent** — selection, focus, active pills |
| `Theme.ember` | `#FF9F4A` | "recently played" / warning / sparingly |
| `Theme.mist` | `#8B93A7` | secondary text, unselected, hairlines |
| `Theme.paper` | `#EDEFF5` | primary text |
| `Theme.error` | `#FF6B6B` | destructive / error accent |

### Platform accents (glow/underline only, never a full wash)

```
steamAccent    = signal        (#4FD3FF)
pspAccent      = #9B8CFF   (muted violet)
dsAccent       = #FF8C8C   (soft coral)
homeAccent     = ember
discordAccent  = #7A86C8
settingsAccent = mist
trophy / achievementsAccent = #FFC94D   (RA gold, distinct from ember)
```

`Theme.accent(for: GameSource)` returns the per-source accent. Category
accents are assigned in `AppEnvironment.rebuildXMB()` (one per category id).

### Type scale

| Token / helper | Font | Use |
|---|---|---|
| `Theme.railLabel(selected:)` | Chakra Petch display (22 selected / 16, weight varies) | category rail labels |
| `Theme.itemTitleSelected` | Chakra Petch 44 bold | selected item title |
| `Theme.meta` | JetBrains Mono 13 | meta line (source, playtime, last played) |
| `Theme.body` | system 14 | body / settings text |
| `Theme.caption` | system 12 | captions |

Fonts are bundled (`Sources/GameDock/Resources/Fonts/`: Chakra Petch ×4
weights, JetBrains Mono ×1) and registered by
`GameDockFonts.registerAll()` (`Core/GameDockFonts.swift`) at launch.

#### ⚠️ Custom-font weight trap

`GameDockFonts.display(_:weight:)` and `.data(_:)` return `Font.custom(...)`.
**Do NOT chain `.weight()` on a custom font** — SwiftUI then falls back to
the system font and silently drops the bundled face. The weight is baked into
the chosen file (`ChakraPetch-Bold`, `-SemiBold`, `-Medium`, `-Regular`). Use
the `weight:` parameter, not the `.weight()` modifier.

### Layout constants

```
Theme.itemCoverWidth: CGFloat = 300
Theme.itemCoverAspect: CGFloat = 0.78   // portrait, not absurdly tall
```

### Motion token

```
Theme.spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
```

This is the one motion token. Pair it with the `reduceMotion` convention
below — never use a raw `Animation.spring(...)` inline.

## reduceMotion convention (follow this everywhere)

Every animated view reads the environment value and branches:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

// animation:
.animation(reduceMotion ? nil : Theme.spring, value: someState)

// transition:
.transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))

// ambient time (WaveField):
let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
```

The pattern across the codebase:
- **When reduceMotion is on:** springs → `nil` (instant) or
  `.easeInOut(duration: 0.15)`; slide transitions → `.opacity` only; ambient
  motion freezes.
- **When reduceMotion is off:** use `Theme.spring`; combine move + opacity for
  overlays.
- Scope the `.animation(value:)` to each overlay's own visibility flag so the
  declared `.transition` actually runs (otherwise SwiftUI treats it as a hard
  cut). RootView and EmulatorScreen both do this per-overlay.

**Do not add a new animated view without a `reduceMotion` branch.** It is the
project's accessibility contract.

## Navigation models

Three `ObservableObject` nav models, plus the pause/core-options models. All
expose a `handle(_ action: GamepadUIAction) -> Item?` method that the input
router calls; they return the confirmed item on `.confirm`, nil otherwise.

### XMBNavModel (`UI/XMBNavModel.swift`)

- `categories: [Category]` — each has `id`, `title`, `accent`, `items: [XMBItem]`.
- `categoryIndex` / `itemIndex` — the cursor (both `@Published`).
- `selectedItem` — computed current item.
- `rebuild(_:)` preserves selection by identity across library refreshes
  (same game stays under the cursor when its index shifts); falls back to a
  clamp on miss.
- **Navigation grammar matches the DualSense exactly:** left/right = walk
  categories (`previousCategory`/`nextCategory`, wraparound); up/down = walk
  items (wraparound); L1/R1 = accelerated category switch
  (`previousPanel`/`nextPanel`). `jumpToCategory(at:)` (quick bar / tab
  clicks) restores the category's last item position instead of resetting to 0.
- `lastItemIndexByCategory` — cursor is remembered per category.

`XMBItem` has a `Kind` enum (`game`, `action`, `profile`, `unlock`,
`completion`, `refresh`) derived from which payload is non-nil. This drives
how `XMBView.cover(for:)` renders it (portrait cover for games/actions,
square avatar/badge for RA entries).

### SettingsNavModel (`UI/SettingsNavModel.swift`)

- Settings rows are rendered as the Settings category's item stack inside the
  XMB — there is no separate Settings view. `rebuild(settings:library:)`
  rebuilds the row list (ROM folders, core paths, PPSSPP app path, rescan, RA
  sign-in/hardcore/unofficial, global capture toggle).
- The item cursor lives in `XMBNavModel.itemIndex` — Settings has no
  per-row selection state of its own.

### QuickBarModel (`UI/QuickBarView.swift`)

- `selection: QuickBarItem` — the focused pill.
- `handle(_:items:)` wraps within the *currently visible* items (the list
  changes between XMB and emulator contexts). left/right and up/down both
  move (the bar is a horizontal strip); confirm returns the selection.
- `visibleQuickBarItems` (on `AppEnvironment`) is contextual: emulator
  screen adds Save/Load/Reset/Options; XMB adds Favorite when a game is
  selected.

### PauseMenuModel / CoreOptionsModel

- `PauseMenuModel` (`UI/PauseMenuOverlay.swift`): fixed item set (resume,
  saveState, loadState, coreOptions, reset, quit); `handle(_:)` wraps
  up/down.
- `CoreOptionsModel` (`Launch/CoreOptionsModel.swift`): core-defined rows;
  `moveCursor(±1)` / `cycleValue(±1)`; a trailing "Reset to defaults" row
  (`cursorIsOnResetRow` / `activateResetRow()`).

## Input → UI flow

All controller/keyboard input funnels through a single router:
`AppEnvironment.gamepad(_:)` (`AppEnvironment.swift`). The controller skill
documents how actions are produced; this skill documents how they are
consumed.

**The router checks modal overlays in a strict priority chain.** Earlier
checks consume the action and `return`; an action never falls through to a
lower-priority handler:

```
AppEnvironment.gamepad(action)
  1. pendingConfirmation?        → confirm proceeds / back·openQuickBar dismisses
  2. pauseMenuVisible (emulator)  → up/down select, confirm runs, back·openQuickBar resumes
  3. coreOptionsVisible (emulator)→ up/down move cursor, left/right cycle value,
                                    confirm (reset row? → activate; else close),
                                    back·openQuickBar close
  4. discord.isFloating          → up/down move selection, confirm activate,
                                    back·toggleDiscord hide, openQuickBar toggles bar
  5. quickBarVisible             → left/right navigate (or adjust volume if .volume focused),
                                    toggleMute mutes; handled inline
  6. captureScreenshot           → captureScreenshot() (global, any screen)
  7. screen-specific:
       openQuickBar → toggle bar + reset
       toggleDiscord → discord.toggle()
       back → close bar / (emulator) openPauseMenu / cancel boot
       confirm/up/down/left/right →
            quickBarVisible → handleQuickBar(action)
            screen == .xmb  → xmb.handle(action) → xmbConfirm(item) on .confirm
       previousPanel/nextPanel (L1/R1) → xmb.handle + selectionMoved (XMB only)
```

**Rules for the router:**
- Add a new modal overlay by inserting its check at the right priority in the
  chain. A modal that should block everything goes near the top (after
  `pendingConfirmation`); a transient one goes lower.
- Every `handle(_:)` on a nav model returns the confirmed item on `.confirm`
  only — the router uses the non-nil return to trigger the action (launch,
  settings row, quick-bar item).
- `selectionMoved()` is called after any nav change that moves the cursor —
  it emits a haptic tick + a WaveField ripple (see below).

## WaveField and ambient motion (`UI/WaveField.swift`)

The signature background: 5 overlapping sine layers drawn in a `Canvas` inside
a `TimelineView(.periodic(... by: 1/30))`. Each layer is a tuple
`(baseY, amplitude, wavelength, speed, inkOpacity, accentOpacity)`; layers
fill toward the bottom for a "field" feel and are stroked with the category
accent at low opacity. Present but calm (~7-13% opacity).

- **Ripples:** `WaveFieldModel.emit(x:y:color:)` injects a radial ripple in
  the accent color on selection change; ripples live 0.7s and fade.
- `XMBView` passes `nav.currentCategory?.accent ?? Theme.signal` so the field
  tints toward the active platform.
- `reduceMotion` freezes the time input (`t = 0`) — waves still render but
  don't drift.
- `allowsHitTesting(false)` + `ignoresSafeArea()` — it's pure backdrop.
- Stride is 10px (halved from 5) — a documented perf tradeoff (the audit
  flagged it as the dominant XMB CPU hotspot).

`env.selectionMoved()` is the trigger site for ripples — it calls
`waveField.emit(...)` and `Haptics.tick()`. Selection changes that don't go
through `selectionMoved()` won't ripple.

## How to add a new screen

1. Add a case to `AppScreen` (`AppEnvironment.swift`).
2. Add the `switch` branch in `RootView` (render the new view).
3. Wire entry/exit in `AppEnvironment.gamepad(_:)` (usually a `.confirm` or
   `.back` branch).
4. If the screen has its own nav model, give it a `handle(_:)` and call it
   from the router.
5. Keep `Theme.*` tokens and the `reduceMotion` convention.

## How to add a new overlay

1. Create the view (usually an `ink.opacity(0.97)` panel on a
   `Color.black.opacity(0.45)` scrim; mirror `CoreOptionsOverlay` /
   `ConfirmationOverlay` for the visual idiom).
2. Add a visibility flag on `AppEnvironment` (`@Published var fooVisible`).
3. Render it in `RootView` (global) or `EmulatorScreen` (emulator-only) with
   a `zIndex` and a scoped `.animation(value:)`.
4. **Insert its input check into the `AppEnvironment.gamepad(_:)` priority
   chain** at the right priority. This is the step most easily missed.
5. Use `Theme.spring` + a `reduceMotion` branch for the transition.

## How to add / modify a Theme token

1. Add the `static let` to `Theme` in `UI/Theme.swift` (use `Color(hex:)`).
2. If it's a platform/category accent, wire it in `Theme.accent(for:)` and/or
   `AppEnvironment.rebuildXMB()`.
3. Do not introduce a second accent for the same role — `signal` is the one
   focus/selection accent; `ember` is the one "recent/warning" accent;
   `trophy` is the one RA-gold accent. Restraint is the design intent.
4. Update this skill's token table if you add a token an agent would reach for.

## Design spec vs. implementation gap

`docs/design-spec.md` describes a design that was superseded during
implementation. Key divergences an agent must know:

- **Accent:** spec says amber phosphor (`#F2A93B`) is "the one accent." Code
  uses cyan `signal` (`#4FD3FF`) as the primary accent; `ember` is secondary.
- **Fonts:** spec says SF Mono for chrome. Code uses **Chakra Petch** for
  display/labels and **JetBrains Mono** for data (bundled, registered at
  launch).
- **Layout:** spec describes a left vertical rail (220pt) + hero + horizontal
  filmstrip. Code is a **horizontal category rail + vertical item bar**
  (selected large, neighbors peek above/below) — a horizontal XMB.
- **Signature element:** spec says "focus reticle" (amber L-brackets). Code
  has no reticle; the signature element is **WaveField** (ambient sines +
  selection ripples) — which the spec explicitly forbids ("no ambient drift").
- **Palette hexes:** spec's `void/panel/ivory/ash` do not match code's
  `void/ink/paper/mist` (different names + different hex values).

Treat `design-spec.md` as historical. The tokens above are the source of
truth. If a task says "match the design spec," flag the divergence rather
than reverting working code.

## Rules — what to never break

1. **Single input router.** All gamepad/keyboard UI actions go through
   `AppEnvironment.gamepad(_:)`. Do not add a second input path or let a view
   handle `GamepadUIAction` directly. (See the controller skill for how
   actions are produced.)
2. **Modal priority chain.** The overlay checks in `gamepad(_:)` run in a
   fixed priority order. A new modal must be inserted at its correct priority;
   do not reorder existing checks without tracing every interaction.
3. **Selection preview panel is purely additive.** It never modifies
   `XMBNavModel`, input routing, or the item-bar layout. Driven by the same
   `onChange(of: nav.selectedItem)` that updates the cover art. (See the
   `leblanc-preview-panel` skill.)
4. **`reduceMotion` everywhere.** Every animated view must branch on
   `@Environment(\.accessibilityReduceMotion)`. No raw `Animation.spring`
   without a reduceMotion alternative.
5. **One accent per role.** `signal` = focus/selection, `ember` =
   recent/warning, `trophy` = RA gold. Do not add competing accents for the
   same purpose.
6. **Custom-font weight via parameter, not modifier.** Do not chain
   `.weight()` on a `GameDockFonts` font (silently falls back to system).
7. **Overlay transitions must be scoped.** Add `.animation(value:)` on each
   overlay's visibility flag so the declared `.transition` actually runs;
   otherwise SwiftUI treats insertion as a hard cut. RootView and
   EmulatorScreen both follow this.
8. **Verify UI changes by eye** (`make run`) — there is no headless UI test.
  `make test` / `make selftest` cover pure logic and emulator plumbing only
  (see `leblanc-build-verify`).
