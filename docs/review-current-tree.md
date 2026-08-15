# GameDock Code Review — current tree (fresh pass)

**Method:** full read-through of every file under `Sources/GameDock/`, plus
`Package.swift`, `Makefile`, `build-app.sh`, `Info.plist`,
`Scripts/subagents/orchestrate.mjs`, `Tests/MockCore`, `AGENTS.md`, `README.md`,
`docs/`. (The scout subagent pool was provider-rate-limited, so this was done
directly.) `swift build` is clean; `make app` succeeds.

Prior audit docs (`docs/audit-v2.md`, `docs/scout-review-report.md`,
`docs/scout-ui-audit.md`) were cross-checked: several findings are already
**FIXED** in the current tree (verified in source, details below). Everything
below is **new or still open**.

---

## 1. New findings — bugs

### 1.1 ArtworkLoader: `inflight` set is a cross-thread data race
`Sources/GameDock/Libraries/ArtworkLoader.swift` (~L152-166)
- `fetchRemote` reads `inflight.contains(cacheKey)` and inserts on the **main
  thread**; the URLSession completion closure (`defer { self?.inflight.remove(...) }`)
  mutates the same `Set` on the **URLSession delegate queue** (background).
- Unsynchronized `Set` mutation from two threads — benign today (no crash in
  practice), but a genuine race; Swift 6/TSan would flag it.
- **Fix:** move the `inflight` add/remove onto the main queue (the whole
  `store`/`loadedKeys` update already hops to main) or guard with the same
  `NSLock` pattern used elsewhere.

### 1.2 VolumeController never tracks default-output-device changes
`Sources/GameDock/Core/VolumeController.swift`
- `refreshDevice()` is called only in `init()`. If the user switches the output
  device while Leblanc is running (AirPods ↔ speakers ↔ HDMI, or a device
  disconnects), the property listeners and `setVolume`/`toggleMute` keep
  targeting the **stale** `AudioDeviceID`. Volume HUD and L2/R2 volume control
  stop affecting the actual output until relaunch.
- **Fix:** add a `kAudioHardwarePropertyDefaultOutputDevice` listener and
  re-point `defaultDevice` (re-adding the two property listeners on the new
  device).

### 1.3 Info.plist: missing mic permission for the embedded Discord web app
`Info.plist`
- Discord is now an embedded `WKWebView` loading `discord.com/app`
  (`DiscordController.swift`). The web app requests **microphone** access for
  voice calls (and camera for video). macOS will hard-fail (app-kill) when a
  `WKWebView` triggers a TCC prompt that has **no usage string** in Info.plist.
- `NSMicrophoneUsageDescription` (and ideally `NSCameraUsageDescription`) are
  missing.
- Bonus: `NSAccessibilityUsageDescription` is **stale** — it describes the
  removed AXUIElement window-resize approach; the app no longer uses
  Accessibility at all. Remove it or reword.

### 1.4 LibraryStore.refresh silently drops concurrent scans
`Sources/GameDock/Libraries/LibraryStore.swift` (`refresh`, ~L38)
- `guard !isScanning else { return }` — a rescan requested while one is running
  (e.g. Settings → "Rescan libraries" pressed twice, or a folder added during a
  scan) is **dropped silently**, and the UI shows "not scanning" only after the
  first completes. Minor, but confusing: the user asked for a rescan and nothing
  new appears.
- **Fix:** coalesce to one pending refresh (`needsAnotherScan` flag) instead of
  dropping.

### 1.5 Haptics engine cache grows unbounded (still open, prior P3-3)
`Sources/GameDock/Core/Haptics.swift`
- `engines[ObjectIdentifier(controller)]` is never pruned on
  `.GCControllerDidDisconnect`. Repeated connect/disconnect churn leaks
  `CHHapticEngine`s for the session. Small, but easy: observe disconnect and
  remove the entry.

### 1.6 ArtworkLoader: transient CDN blip = permanent tombstone (prior P2-4, still open)
`Sources/GameDock/Libraries/ArtworkLoader.swift` (`load`, `failed.insert`)
- Any network error marks the key `failed` for the **whole session**; only a
  successful `store` clears it. A brief offline moment means placeholder art
  forever (until relaunch). Combine with 1.1: also do not mark `failed` while a
  fetch is merely in flight.

### 1.7 RemoteImage: unbounded static cache + no cancellation
`Sources/GameDock/UI/RemoteImage.swift`
- `Self.cache` never evicts (RA avatars/badges are small, so minor), and a
  `dataTask` started in `onAppear` isn't cancelled when the view disappears or
  the URL changes — a rapid scroll can waste bandwidth. Low priority.

---

## 2. New findings — performance / UX improvements

### 2.1 Artwork decode happens on the main thread during body evaluation
`Sources/GameDock/Libraries/ArtworkLoader.swift` (`load`, `NSImage(contentsOfFile:)`)
- Called from `ArtworkView`/`XMBView.cover` body eval. First pass over a large
  library (or after LRU eviction) decodes disk images on the main thread →
  scroll/selection jank. In-memory cache amortizes it, but the decode itself
  should move off-main (decode on a utility queue, publish via `loadedKeys`).

### 2.2 Emulator load and teardown run on the main thread
`Sources/GameDock/AppEnvironment.swift` (`startEmulator`/`exitEmulation`),
`Sources/GameDock/Launch/EmulatorSession.swift` (`load`, `requestStop` + `teardown`)
- `session.load()` (retro_init + load_game) runs on main — a slow core freezes
  the UI on launch. `exitEmulation` calls `requestStop()` which joins the core
  thread with a 2 s timeout **on main**, so a stuck core stalls the UI up to 2 s
  before teardown. (The hang itself is now handled safely via `coreThreadStuck`
  — see §3 — but the UI stall is avoidable: hop load/teardown off main.)

### 2.3 GLHardwareBridge.readPixels allocates a temp buffer every frame
`Sources/GameDock/Launch/GLHardwareBridge.swift` (`readPixels`)
- `tmp = UnsafeMutableRawPointer.allocate(...)` + `defer deallocate` per call,
  per frame (~60×/s for a 480×272 row = 1.9 KB). Trivial today; could reuse a
  member scratch buffer like `EmulatorSession.hwReadbackBuffer` does.

### 2.4 GCController callback thread affinity — verify, don't assume
`Sources/GameDock/Controllers/ControllerManager.swift`
- `pressedChangedHandler`/`valueChangedHandler` mutate `@Published` UI state via
  `uiReceiver?.gamepad(...)`. GameController currently delivers on the main
  thread, so this works — but it's an undocumented contract. Cheap hardening:
  assert `Thread.isMainThread` in `AppEnvironment.gamepad` (debug only) so a
  future OS change surfaces loudly instead of corrupting SwiftUI state.

---

## 3. Prior findings verified FIXED (current source)

- **P2-1** `InputSnapshot.readButton` shift trap → now guards `(0...31).contains(id)`.
- **P2-2** `SET_HW_RENDER` accepting Vulkan → now declines anything except
  `RETRO_HW_CONTEXT_OPENGL`/`OPENGL_CORE`.
- **P2-3** RCClientService dangling `callbackData` → `enqueue` now no-ops after
  `destroy()` via `isDestroyed` (a tiny check-vs-teardown race remains, benign
  since `doFrame` never runs post-teardown).
- **audit-v2 §1.1** RA game never loaded → `startRetroAchievements` now calls
  `service.beginLoadGame(path:romData:)`.
- **audit-v2 §1.2** dlclose of a live stuck core → `coreThreadStuck` path now
  leaks the core instead of unmapping under it.
- **audit-v2 §1.5** `FrameSlot.pitch` dead field → removed.
- **P1** hung-core teardown → handled (see §2.2 for the remaining UI-stall
  aspect only).

---

## 4. Still-open prior findings (confirmed in source)

- **P2-4** ArtworkLoader permanent `failed` tombstone (see 1.6).
- **P2-5** `RetroAudioEngine` start (background queue) vs stop (main) race —
  unchanged. If `stop()` wins the race before `start()` completes on the
  background queue, the engine can end up running after detach. Worth a small
  serialization (start/stop on one queue, or `isRunning` under the same lock).
- **P3-2** Single-controller last-wins (v1 design, document it).
- **P3-3** Haptics engine cache never evicted (see 1.5).
- **P3-6** `SettingsNavModel.selection` is dead state (`@Published var selection`
  is only clamp-guarded in `rebuild`, never read by any view).
- **P3-8** PPSSPP `stop()` uses `terminate()` (SIGTERM may skip save flush).

---

## 5. Build / tooling

- **Package.swift**: the `CRcheevos` `exclude:` list names `src/rc_libretro.c`
  and `src/rc_libretro.h`, which don't exist → two spurious build warnings every
  build. Delete those two entries.
- **No unit tests at all**: `Tests/` contains only `Tests/MockCore/mockcore.c`
  (a fixture for `--selftest`). `VDFParser`, `RomTitle`, `PixelConverter`,
  `SettingsStore`, `RACache`, `RecentsStore`, `Models.romID` are pure logic,
  highly testable, and currently have zero coverage. Add a `GameDockTests` test
  target (`swift test`) — VDFParser and RomTitle are the highest value (they
  parse untrusted Steam/ROM files and already have documented edge cases).
- **Makefile**: no `test` target; `make app` always builds debug; add `make
  test`/`make app-release` for completeness.

---

## 6. Docs / repo hygiene drift

- **README.md:14** — `make app # assemble build/GameDock.app` → the app is
  `build/Leblanc.app`.
- **AGENTS.md** — stale module map: `GameLauncher` (no such file; it's
  `StandaloneEmulatorLauncher`/`SteamLauncher`), `FrameSlotRing` (actual:
  `FrameSlot`), `HomeView`/`GameCardView`/`SettingsView` listed but gone (XMB
  replaced them), "Discord … resize/position its window via Accessibility
  (AXUIElement)" (actual: embedded WKWebView), hotkey "via CGEventTap" (actual:
  Carbon `RegisterEventHotKey`), `GlobalHIDMonitor` described as "experimental,
  default-off" (it's now disabled pending Apple's HID fix — see
  `docs/ps-button-report.md`), `build-app.sh` "assembles GameDock.app from
  .build/release binary" (debug by default).
- **Info.plist** — `NSAccessibilityUsageDescription` stale (see 1.3).
- **Scripts/subagents/orchestrate.mjs** — PRIMER still says "RootView.swift
  (placeholder home)", "CLI … stubs", and lists a stale file layout; imports
  hardcode `/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/...`
  absolute paths (breaks on any other machine).
- `.gitignore` is fine; no stray large/binary files tracked (`git status`
  clean).

---

## 7. Suggested priority order

1. **Fix now (small, high value):** Package.swift excludes; Info.plist mic key
   (TCC crash risk for the embedded Discord web app); README/AGENTS app-name
   fixes.
2. **Fix this week:** VolumeController default-device listener (1.2);
   ArtworkLoader `inflight` race + in-flight/`failed` logic (1.1+1.6);
   LibraryStore scan coalescing (1.4).
3. **Improvement backlog:** off-main artwork decode (2.1), off-main
   emulator load/teardown (2.2), unit-test target for pure logic (§5),
   RetroAudioEngine start/stop serialization (P2-5), Haptics eviction (1.5),
   doc refresh (§6).
