# UI/UX Improvement Plan — Leblanc (GameDock)

Grounded in a full-codebase audit (UI layer, AppEnvironment router, artwork pipeline,
input layer, emulator session, Discord, skills, AGENTS.md). Findings are grouped into
phases by severity; each item cites file:line and specifies the change.

---

## Phase 1 — Bugs & destructive traps (fix first, small diffs)

### 1.1 Cancel in core-file NSOpenPanel clears the core override
- **Where**: `AppEnvironment+Settings.swift:69-72` — non-OK response calls `setCoreOverride(nil)`.
- **Fix**: only apply the override when the panel returns `.OK`; treat Cancel as a no-op.
- **Test**: unit-testable via a seam — extract `applyCorePick(_ url: URL?)` and assert cancel path leaves override untouched.

### 1.2 Removing a ROM folder has no confirmation
- **Where**: `AppEnvironment+Settings.swift:19-21` — Confirm on a folder row deletes immediately.
- **Fix**: route `.folder(source,index)` confirm through a new lightweight confirmation overlay (`ConfirmationOverlay`, see 3.3) — "Remove this ROM folder? Games from it stay on disk." Confirm removes, Circle cancels. Reuse for future destructive actions.

### 1.3 Selection is index-based across library rebuilds
- **Where**: `XMBNavModel.rebuild` clamps indexes only (`XMBNavModel.swift:61-65`); favorites toggle rebuilds all categories (`AppEnvironment.swift:458-459`) so the cursor can land on a different game.
- **Fix**: store `selectedItemID` before rebuild; after rebuild, restore `itemIndex` by id match, fall back to clamp. Same for `categoryIndex` by category id. Also give `jumpToCategory` memory of last item index per category (`XMBNavModel.swift:93` resets to 0).

### 1.4 Quick bar / core options transitions don't animate
- **Where**: `RootView.swift:20-24` and `EmulatorScreen.swift:45-48` insert views with `.transition(...)` but no enclosing `.animation(value:)` — the declared transitions never run.
- **Fix**: add `.animation(.spring, value: env.quickBarVisible)` on the RootView ZStack (respect `reduceMotion` → use `.opacity`-only) and the equivalent for `coreOptionsVisible` in EmulatorScreen. Audit every `if let`/`if bool` + `.transition` pair for a missing animation scope (error banner, toast, volume HUD in `QuickBarView.swift:162`).

### 1.5 Steam launch failure leaks keep-awake + session tracking
- **Where**: `SteamLauncher.swift:20` returns on bad URL after `+Launch.swift:14-20` started both.
- **Fix**: return a `Result`/Bool from `steam.launch`; on failure call `endKeepAwake()`/`endSessionTracking()` and set `errorMessage = "Couldn't launch <title> via Steam."`.

### 1.6 Screenshot-permission error cleared by string comparison
- **Where**: `AppEnvironment+Launch.swift:75-79` — compares the exact error text after 6 s.
- **Fix**: replace `errorMessage: String` with a struct (see 3.1) carrying an optional auto-dismiss interval; no string matching.

### 1.7 EmulatorMetalView `fatalError` paths
- **Where**: `EmulatorMetalView.swift:16,33`.
- **Fix**: on missing Metal device, fall back to a software `CALayer` blit of the FrameSlot (or at minimum show a styled error screen instead of crashing).

---

## Phase 2 — Missing states (loading / empty / error / offline)

### 2.1 Library scan progress state
- **Where**: `LibraryStore.isScanning` is published but nothing consumes it; empty categories show "No games found" *while scanning* (`XMBView.swift:239-241`).
- **Fix**:
  - Add `xmb.isScanning` (or read `env.library.isScanning` directly).
  - In `XMBView` empty state: if scanning → spinner + "Scanning your library…" (animated dots); if done and empty → current copy **plus an actionable row/button: "Open Settings"** that calls `xmb.jumpToCategory(settings)` (also fixes the settings empty-state dead end).
  - Differentiate Steam states: "Steam not found" vs "No installed games" (SteamLibrary already knows install presence).

### 2.2 Launch feedback ("Starting…" overlay)
- **Where**: `launch()` hides the window for Steam/PPSSPP with zero feedback (`+Launch.swift`); `startEmulator` blocks the main thread synchronously (`+Launch.swift:99`).
- **Fix**:
  - Non-emulator launches: show a brief full-screen ink overlay "Starting <title>…" (fade out via `NSApp` hide ~0.4 s later) so the handoff reads as intentional.
  - Emulator: move `session.load()` off the main thread — set `screen = .emulator` + `isLaunchingGame = true` immediately, render EmulatorScreen with a "Loading core…" boot overlay (title + spinner, matches XMB ink aesthetic), clear it on first frame (`FrameSlot` first-consume callback) or on load error → banner + return to `.xmb`.

### 2.3 Unified error surface
- **Where**: `RootView.swift:40-57` — single string, no auto-dismiss, no animation, off-palette red, collides with quick bar/toast.
- **Fix**:
  - `struct AppError { message; kind: .info/.error/.warn; autoDismissAfter: TimeInterval?; retry: (() -> Void)? }`.
  - Style with Theme tokens (ember accent on ink, not raw red), `.transition(.move(edge: .top).combined(with: .opacity))` with proper animation scope, auto-dismiss default 6 s for `.info`/`.warn`.
  - Move to **bottom-leading** placement to eliminate the top collision (top is occupied by quick bar + toast).
  - Wire retry into artwork/preview failures (see 2.4).

### 2.4 Offline awareness + network-failure ≠ no-data
- **Where**: `StatusMonitor` knows network state but nothing consumes it; `ArtworkView`, `RemoteImage`, `SelectionPreviewModel` render permanent placeholders on failure.
- **Fix**:
  - Small persistent "Offline" pill in the XMB header (next to clock) when `status.networkState == .offline`; drives a subtle "showing cached data" affordance.
  - `ArtworkLoader` tombstones already retry after 60 s — surface transient state: `ArtworkView` shows a **shimmer skeleton** while loading, initials only on confirmed miss.
  - `PreviewImage`: distinct failure state (dimmed panel + small retry glyph; clicking/selecting again retries).
  - `RemoteImage`: add timeout (15 s), LRU cap (reuse PreviewImageLoader's 200-entry pattern), HTTP-status check.

### 2.5 Artwork fade-in + prefetch-before-swap
- **Where**: `ArtworkView.swift:22-38` — `onChange(entry.id)` nils the image first, causing placeholder flash; declared transition never animates.
- **Fix**: load the new entry's art, swap only when the NSImage is available; `.animation(.easeOut(0.25), value: image)` for the fade. Replace the per-publish `keys.contains` scan with a set intersection check.

---

## Phase 3 — Navigation & interaction (controller-first parity)

### 3.1 d-pad Left/Right = category switch in XMB
- **Where**: `XMBNavModel.handle` breaks on `.left/.right` (`XMBNavModel.swift:111-112`).
- **Fix**: map `.left → previousPanel`, `.right → nextPanel` (matching PSP/PS3 XMB muscle memory). Keep L1/R1 as the accelerated/repeat path. Verify `RepeatPacer` covers the new path (it already repeats `.left/.right`).

### 3.2 Keyboard + mouse parity
- **Where**: item cards have no tap gesture (`XMBView.swift:149-172`); quick bar pills are `onTapGesture` not Buttons (`QuickBarView.swift:88`); core option rows can't be clicked (`CoreOptionsOverlay.swift:17,83`); keyboard only works when no controller is connected (`ControllerManager.swift:26`).
- **Fix**:
  - Item covers: `.onTapGesture` → select; double-click (or single click when already selected) → confirm.
  - Quick bar pills and core-options rows → real `Button`s with hover highlight (`onHover`).
  - Keyboard: always-on keyboard navigation (merge keyboard events alongside controller instead of exclusive fallback), and give the router a keyboard path for screenshot (F5?) / quick bar (Esc or F1) so the hotkey story is consistent.
  - Add `.accessibilityLabel` to all interactive elements while in there (covers: game title; pills: action name).

### 3.3 Confirmation & "back" semantics
- **Where**: Circle/back is dead in XMB (`AppEnvironment.swift:235-240`); quitting emulation via Circle has no confirmation (`exitEmulation` immediate).
- **Fix**:
  - Circle in XMB: if an item is selected beyond the first, return to category rail / collapse selection; else no-op (or show hints briefly). 
  - Emulator Circle → small in-game pause menu overlay (Resume / Save State / Load State / Core Options / Reset / Quit) instead of instant quit; Quit asks confirm if playtime-since-save > 2 min. This also gives the **user-facing pause** feature (audit gap: pause only exists via sleep/options-overlay).
  - New shared `ModalOverlay` pattern (scrim + ink panel + rows) reused by ConfirmationOverlay, PauseMenu, CoreOptions.

### 3.4 Quick bar horizontal navigation
- **Where**: left/right = volume while quick bar open (`AppEnvironment.swift:204-218`) — a horizontal bar navigated only vertically.
- **Fix**: left/right moves selection horizontally (wrapping); hold R2 (or Options) + left/right adjusts volume, or move volume to up/down on a dedicated "Volume" pill with live HUD. Add a one-line hint row inside the quick bar ("▲▼/◀▶ SELECT · ✕ CONFIRM · ○ CLOSE") mirroring CoreOptionsOverlay's caption.

### 3.5 Wrap-around navigation
- **Where**: no looping on categories/items (`XMBNavModel.swift:77-103`).
- **Fix**: wrap with the existing matched-geometry animation; wrap on categories, wrap on items (config flag in Theme if we want hard-stop later).

### 3.6 Save-state slot safety
- **Where**: single slot `<stem>.state`, silent overwrite (`EmulatorSession.swift:522-532`).
- **Fix (minimal v1.5)**: 3 slots + auto slot. Save writes to a rotating slot or `<stem>-<timestamp>.state` keeping last 3; pause menu (3.3) lists slots with timestamps; load defaults to newest. Keep the quick-bar Save/Load on slot 1 with toasts (already exists).

---

## Phase 4 — Feedback & polish (motion, sound, haptics, layout)

### 4.1 Screen transitions
- **Where**: RootView switches XMB↔Emulator with a hard cut (`RootView.swift:8-17`).
- **Fix**: cross-fade + slight scale (0.98→1.0) via `.transition`, 0.35 s, respecting `reduceMotion` (opacity only). Applies to error/toast/quick bar once 1.4 lands.

### 4.2 Boot & selection choreography
- **Where**: single 0.9 s fade of the whole XMB (`XMBView.swift:41,55`).
- **Fix**: staggered entrance (clock → rail → items, 80 ms offsets, spring), item-bar window changes animate as slide (enter from top/bottom edge based on direction — track last direction in XMBNavModel). Ripple origin: pass the selected card's actual center to `waveField.emit` instead of the fixed 0.5/0.58 (`AppEnvironment.swift:421`) — GeometryReader on the selected cover.

### 4.3 Feedback taxonomy (haptic + optional nav sound)
- **Where**: single tick on selection (`AppEnvironment.swift:419-422`); nothing on confirm/error/favorite/save.
- **Fix**: `Feedback.play(.selection/.confirm/.error/.toggle)` wrapper — distinct haptic patterns per event; confirm gets a stronger event; favorite/save toasts already exist for capture — extend the toast system (`captureToasts`) into a general `ToastCenter` (kind: capture/save/error/info) with slide+fade transition and queueing (currently `toasts.current` shows one achievement at a time — show "+N more" badge).

### 4.4 Emulator screen polish
- **Where**: hints permanently overlaid (`EmulatorScreen.swift:35-39`).
- **Fix**: auto-hide hints after 5 s (reappear on any non-gamepad input / Options press); add on-screen toasts for Save/Load/Reset (currently silent) and audio-failure ("Audio unavailable — check output device", replaces log-only warning in `RetroAudioEngine`); show a subtle "PAUSED" pill while core-options overlay is open.

### 4.5 Status visibility & quick bar accuracy
- **Where**: battery/network only visible while quick bar open; battery icon always `battery.75` (`QuickBarView.swift:122`).
- **Fix**: map battery level → `battery.0/25/50/75/100` + `battery.100.bolt` when charging; low controller battery (<20%) → one-time amber pill under the XMB header; Wi-Fi vs Ethernet distinct icons.

### 4.6 Theme systemization
- **Where**: magic paddings/radii/durations scattered; no contrast support (`Theme.swift`).
- **Fix**: add tokens — spacing scale (4/8/12/16/24/40), corner radii (8/12/18), duration tokens (`fast 0.2 / base 0.35 / slow 0.9`); consult `accessibilityColorDifferentiateWithoutColor`/Increase Contrast to bump mist→paper contrast on captions; improve `ArtworkPlaceholder.initials` stop-word handling ("The Legend of Zelda" → "LZ" not "TL"); size-aware placeholder typography (neighbor vs selected cover).

### 4.7 Settings rows as rows, not giant cards
- **Where**: every settings row renders a 300 pt cover card with question-mark art (`SettingsNavModel.swift` + `XMBView.swift:193-199`).
- **Fix**: add `XMBItem.kind == .settingRow` rendering — compact horizontal row (glyph capsule + title + detail, mono path truncating middle). Section headers become non-selectable styled headers with an explicit "+ Add Folder…" row underneath. Detail paths truncate head (`…/last-component`).

### 4.8 Misc cleanups
- Preview panel: skeleton shimmer while loading; pagination dots for rotating screenshots; pause rotation when window not key / quick bar open (`SelectionPreviewModel`); disk cache eviction (keep ≤ 200 MB LRU).
- Discord: offline → styled error panel instead of raw WKWebView error page; log when nav selectors fail so breakage is diagnosable.
- `WaveField`: freeze ripples under `reduceMotion` too (`WaveField.swift:34-36`); pause TimelineView when not visible.
- Localize nothing yet, but extract user-facing strings into a `L10n.swift` namespace to make future localization possible.
- RemoteImage unbounded cache → LRU; achievements queue badge (4.3).

---

## Phase 5 — Bigger bets (optional, after 1–4)

1. **Achievements category dead items** (`AppEnvironment.swift:348-350`): render text items as info rows, not selectable cards with `questionmark` art.
2. **Steam custom portrait grid art** (`ArtworkLoader.swift:194-210`): consult local `600x900`/`p.png` grid capsules before CDN — fixes offline first-run covers.
3. **Multi-controller**: feed ports 1–3 (`InputSnapshot` already supports them); fix superseded-controller handler leak (`ControllerManager.swift:43`).
4. **Search / jump-to-letter** for long libraries: hold Options → letter rail overlay; or Search quick-bar item with keyboard entry.
5. **Idle attract mode**: after 3 min idle on XMB, slow screenshot slideshow (WaveField already provides motion; reuse preview pipeline).
6. **Second-window guard**: `WindowGroup` single-instance enforcement or `defaultSize`/`minSize` reconciliation (`GameDockApp.swift:11-24` vs `AppDelegate.swift:97`).

---

## Suggested implementation order & verification

| Phase | Est. scope | Verify with |
|---|---|---|
| 1 (bug fixes) | 1 day | `make build && make test`; manual: open-panel cancel, folder remove confirm, favorite toggle keeps selection |
| 2 (states) | 2 days | Kill network → offline pill + skeleton; `--scan-steam`; big ROM launch shows boot overlay |
| 3 (navigation) | 2–3 days | DualSense pass over every screen; keyboard-only pass; pause menu flows |
| 4 (polish) | 2–3 days | reduce-motion pass; screenshot review of every transition |
| 5 (bets) | as desired | per-feature |

Every phase must keep `make build`, `make test`, `make selftest` green (AGENTS.md git rule:
commit per milestone, `feat(ui): …`).

## Non-goals (explicitly out, per AGENTS.md constraints)
- No custom Discord UI; no cloud sync; no 3DS; no changing the bundle id; no ABI changes
  to CLibretro shim layout.
