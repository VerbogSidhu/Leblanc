# GameDock — Code Review Scout Report

Scope: full read-only review of all `.swift`/`.c`/`.h` under `Sources/` and
`Tests/`, plus `Package.swift`, `Makefile`, `Info.plist`, `build-app.sh`.
`swift build` succeeds with zero warnings; findings below are independent of
the compile.

Priorities: **P0** = will misbehave for a user / breaks a headline feature;
**P1** = real bug that corrupts behavior or memory in a reachable path;
**P2** = correct but risky / wrong-in-practice; **P3** = polish / hardening.

---

## P0 / P1 — Input never reaches the emulator

### P1-1. `EmulatorSession.inputSnapshot` is never wired to `ControllerManager.snapshot`
- **Files:** `Sources/GameDock/AppEnvironment.swift` (`startEmulator`, ~line 150),
  `Sources/GameDock/Launch/EmulatorSession.swift` (line 127),
  `Sources/GameDock/Controllers/ControllerManager.swift` (lines 117–122, 204)
- **Problem:** `ControllerManager` writes controller state to its own
  `let snapshot = InputSnapshot()`. `EmulatorSession` declares a second,
  **separate** `let inputSnapshot = InputSnapshot()` and its libretro input
  callbacks (`handleInputState`, lines 458/462) read only from *that* one.
  `AppEnvironment.startEmulator(_:)` creates the `EmulatorSession` and neither
  passes the controller snapshot in nor shares it. Nothing ever writes to
  `session.inputSnapshot` in the GUI path.
- **Effect:** The on-screen emulator's `retro_input_state` / retro_input_poll
  always return 0. **Controller/keys do not control the running game.** The
  `--selftest` hides this because it writes directly to `session.inputSnapshot`
  (CLI.swift `CLISelfTest`).
- **Fix:** Inject the shared `InputSnapshot` into the session — e.g.
  `EmulatorSession(corePath:..., input: controllers.snapshot)` and have
  `handleInputState`/`handleInputPoll` read that; or make `EmulatorSession`
  reuse `ControllerManager.snapshot` (one source of truth). Add a real-GUI
  integration check (not just `--selftest`) that disconnects the two panels.

---

## P1 — ABI/behavior corruption in RetroEnvironment

### P1-2. `RETRO_ENVIRONMENT` case 56 is mis-labeled and mis-handles `SET_CORE_OPTIONS_DISPLAY`
- **File:** `Sources/GameDock/Launch/RetroEnvironment.swift`, lines 112–117 and 150
- **Problem:** Comment says `case 56: // RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER`,
  but in `libretro.h` (line 160–161): `SET_CORE_OPTIONS_DISPLAY = 56`, and
  `GET_PREFERRED_HW_RENDER = 57`. So cmd 56 (which expects a
  `struct retro_core_option_display*`) falls into this branch and executes
  `data.assumingMemoryBound(to: Int32.self).pointee = preferredHwContext` — an
  `Int32` write into the core-provided struct. The real command 57 is correctly
  declined in the `case 14, 41, 40, 43, 57` block, which means
  `GET_PREFERRED_HW_RENDER` is **never** answered as intended (it returns false).
- **Effect:** A core issuing `SET_CORE_OPTIONS_DISPLAY` (options UI) gets 4 bytes
  clobbered where its `visible` field sits, and the frontend falsely claims the
  command was handled. `GET_PREFERRED_HW_RENDER` is effectively unimplemented at
  the env layer (though `EmulatorSession` already steers PPSSPP onto GL elsewhere).
- **Fix:** change the case to `case 57: data.assumingMemoryBound(to: Int32.self).pointee = preferredHwContext`, and either implement (decline) cmd 56 in the graceful-decline block: `case 56: // SET_CORE_OPTIONS_DISPLAY — no options UI; decline` → `return false`.

---

## P2 — Correct but wrong-in-practice / risky

### P2-1. Analog Y axis sign is inverted vs. libretro convention
- **Files:** `Sources/GameDock/Controllers/ControllerManager.swift` (lines 117–122),
  `Sources/GameDock/Launch/EmulatorSession.swift` (`handleInputState` ~line 462)
- **Problem:** `setStick` derives Y as `s.up.value - s.down.value`, so pushing the
  stick **up** yields **+1**. The libretro analog convention (and what cores like
  melonDS/PPSSPP expect for the left/right stick) is that *up = negative Y* for
  the left stick (and typically up = negative Y for the right stick too).
- **Effect:** Vertical camera/character movement is inverted in many games.
- **Fix:** negate the Y when writing, or negate in `readAnalog` for the Y axis
  (keep it consistent with what RetroArch does, which is up→negative).

### P2-2. `RecentsStore` is read off-main while written on main — data race
- **Files:** `Sources/GameDock/Libraries/RecentsStore.swift` (no locking on
  `launches`), `Sources/GameDock/Libraries/LibraryStore.swift`
  (`scanSynchronously` reads `recents.lastPlayedDate(...)` on `scanQueue`)
- **Problem:** `record(entry:)`/`recentGames(...)` are called on the main thread,
  while `LibraryStore`'s background `scanQueue` reads the same `launches` array
  via `lastPlayedDate`/inside `recentGames(from:)`. There is no lock on the array.
- **Effect:** Coherent but technically undefined concurrent read/write; can
  crash/throw in obscure timing (a launch fired during a rescan).
- **Fix:** guard `launches` with an `NSLock` or dispatch all RecentsStore access
  onto a single serial queue (the project is Swift 5, so a lock is simplest).

### P2-3. SteamHandoffMonitor `isHandedOff` is never cleared by the manual-restore (hotkey/PS) path
- **File:** `Sources/GameDock/Launch/SteamLauncher.swift` (`restoreEarly()` is
  dead code, lines 65–71)
- **Problem:** `restoreEarly()` exists but is never called. The hotkey
  (`GlobalHotkeyManager`) and PS-button restore go straight to
  `AppDelegate.restoreFrontend()`. So `isHandedOff` stays `true` after the user
  returns manually.
- **Effect:** Later, when Steam quits for an unrelated reason (closing the client
  to switch apps), `handleSteamQuit()` fires the stale `onSteamQuit()` and the
  frontend restores itself spuriously.
- **Fix:** call `SteamHandoffMonitor.shared.restoreEarly()` inside
  `AppDelegate.restoreFrontend()` when a handoff is active, or have the hotkey
  callback clear it.

### P2-4. Standalone emulator launch may double-spawn the process
- **File:** `Sources/GameDock/Launch/StandaloneEmulatorLauncher.swift` (lines
  95–98)
- **Problem:** `Process` launches the app's *internal binary*
  (`p.executableURL = bundle/binary`), then `NSWorkspace.shared.open(bundle)`
  re-opens the `.app` bundle and often launches a **second** instance via
  LaunchServices.
- **Effect:** Two PPSSPP processes, confusing process management and the
  `terminationHandler` restore (the first to exit calls `onExit`, restoring the
  frontend while the other instance keeps running).
- **Fix:** use `NSWorkspace.shared.open([romPath], withApplicationAt: bundle,
  configuration:)` to open the ROM *with* the app via LaunchServices, dropping
  the manual `Process` launch (or keep `Process` only and activate via
  `app.activate()`).

### P2-5. `exitEmulation()` blocks the main thread while joining the core thread
- **File:** `Sources/GameDock/AppEnvironment.swift` (`exitEmulation`),
  `Sources/GameDock/Launch/EmulatorSession.swift` (`requestStop` waits on
  `threadDone.wait()`)
- **Problem:** `requestStop()` blocks the caller until the core `retro_run` loop
  exits. Called from the main thread in `exitEmulation`. A core stuck in a GL
  call (PPSSPP/HW path) or an infinite `retro_run` freezes the entire UI/app.
- **Effect:** Potential app hang (accepted "not signal-perfect" risk in
  AGENTS.md, but worth a watchdog or a timeout on the join).
- **Fix:** join on a background queue and flip the UI to `.home` only after the
  thread completes, keeping the main thread responsive.

### P2-6. DualSense PS/menu button is overloaded (Select + quick bar)
- **File:** `Sources/GameDock/Controllers/ControllerManager.swift` (lines 108, 160–175)
- **Problem:** `pad.buttonMenu.pressedChangedHandler` is set to libretro
  `SELECT` (id 2). Then `hookSystemButtons` probes the physical profile for a
  PS button and, if the menu/PS elements resolve to the same
  `GCControllerButtonInput`, assigns a second `pressedChangedHandler`, which
  **replaces** the Select handler with the quick-bar toggle. Depending on how
  GameController aliases the DualSense "PS"/"Menu" element, either Select is
  never mapped or PS both opens the quick bar *and* injects Select mid-game.
- **Effect:** Confusing/incorrect button mapping on the flagship controller; the
  retropad Start/Select layout on DualSense is nonstandard to begin with.
- **Fix:** decide one interpretation (map Options→Start and Create/Share→Select
  via the physical profile; keep PS solely as the quick-bar button) and don't
  double-assign a handler to the same element. Verify with `--diagnose-input`.

---

## P3 — Polish / hardening

### P3-1. `shim.h` declares `shim_get_log_printf` *after* `#endif` and outside `extern "C"`
- **File:** `Sources/CLibretro/include/shim.h` (lines 66–71)
- **Problem:** The `retro_log_printf_t shim_get_log_printf(void);` declaration
  sits after the include guard's `#endif` and after the `extern "C"` block. In
  C it still declares the symbol (guarded), but if this header is ever included
  from C++ (or twice), the declaration escapes the guard and loses C linkage
  (C++ name mangling).
- **Fix:** move the declaration inside the guard (before the `#endif` / inside
  `extern "C"`).

### P3-2. `MetalRenderer.draw` holds the `FrameSlot` lock during the GPU texture upload
- **File:** `Sources/GameDock/Launch/MetalRenderer.swift` (`draw`, `withLatest` +
  `texture.replace`)
- **Problem:** The render/draw thread holds the same `NSLock` the core thread
  uses in `FrameSlot.push` while doing `replace` on a `.shared` texture, which
  is a synchronous CPU→GPU copy. Under load this contends with the core thread.
- **Fix:** copy the latest frame out of the slot lock into a scratch buffer, then
  upload it; keeps the critical section tiny.

### P3-3. `RomLibrary.scan` requests `isHiddenKey` but never uses it
- **File:** `Sources/GameDock/Libraries/RomLibrary.swift` (`isHiddenKey` in the
  requested keys array, never read)
- **Problem:** dead resource fetch; the enumerator already passes
  `.skipsHiddenFiles`. Harmless but misleading.
- **Fix:** drop `isHiddenKey` from `keys`.

### P3-4. Missing `NSAccessibilityUsageDescription` in Info.plist
- **File:** `Info.plist`, `Sources/GameDock/Discord/DiscordController.swift`
- **Problem:** AX window floating requires Accessibility trust (`AXIsProcessTrusted`),
  which normally benefits from an `NSAccessibilityUsageDescription` string to show
  a proper TCC prompt. Absent here, so users must pre-enable GameDock manually in
  System Settings → Privacy → Accessibility — the AX path will silently degrade
  to "plain launch" without it.
- **Fix:** add `NSAccessibilityUsageDescription` to `Info.plist` and, ideally,
  surface a hint in Settings when `AXIsProcessTrusted()` is `false`.

### P3-5. OpenGL bridge depends on (deprecated-but-present) macOS OpenGL
- **File:** `Sources/GameDock/Launch/GLHardwareBridge.swift` (`import OpenGL`,
  `import OpenGL.GL3`)
- **Problem:** OpenGL is deprecated (since macOS 10.14) and will be removed in a
  future macOS. v1 works, but the PPSSPP/GL readback path has a finite lifespan
  and no migration plan (documented in AGENTS.md as out-of-scope for v1). Worth an
  explicit note/tracking for v2.

### P3-6. `DiscordController` `isFloating` stays false when AX permission is missing
- **File:** `Sources/GameDock/Discord/DiscordController.swift` (`resizeFloating`)
- **Problem:** When `AXIsProcessTrusted()` is false, the function activates
  Discord and returns without setting `isFloating = true`. A second Share press
  therefore calls `show()` again (re-`open`) instead of `hide()`. Minor and the
  documented degrade-to-plain-launch, but inconsistent state.
- **Fix:** set `isFloating = true` (or use a separate "shown" flag) once Discord
  is brought forward, so the next toggle hides/returns to the frontend.

### P3-7. `SettingsStore`/`LibraryStore` background reads vs. main-thread writes
- **File:** `Sources/GameDock/Libraries/LibraryStore.swift`,
  `Sources/GameDock/Libraries/SettingsStore.swift`
- **Problem:** `scanSynchronously()` reads `settings.romFolders` off-main while
  the Settings UI mutates it on main (Swift 5, unguarded). Lower-severity twin of
  P2-2 (folder lists change rarely and mostly outside a scan, but still a race).
- **Fix:** snapshot the folder list on the main thread before submitting to the
  scan queue, or add a lock to the published dictionaries.

### P3-8. HomeNavModel/`HomeView` vertical+horizontal nested scroll id logic
- **File:** `Sources/GameDock/UI/HomeView.swift`, `Sources/GameDock/UI/HomeNavModel.swift`
- **Problem:** `rebuild` clamps selection defensively (fine), but the horizontal
  `scrollTo` uses `"card-\(section.id)-\(col)"`; if two sections ever share an
  `id->col` colliding anchor while the vertical scroll also targets
  `"row-\(index)"`, the `LazyVStack`'s section ids could collide. Currently ids
  are unique per source; low risk, flag for safety when adding sections.
- **Fix (defensive):** prefix card anchors with the row index.

---

## Verified non-issues (checked, OK)

- **`shim_install` + `RTLD_DEFAULT` ordering:** dlopen'd with `RTLD_GLOBAL`,
  set_* resolved before `retro_init`, callbacks installed before load — correct.
- **use-after-free / teardown ordering:** core thread is joined (`requestStop`
  waits) before `teardown()` runs unload/deinit; `EmulatorSession.setActive(nil)`
  happens after — no callback can fire on a freed session.
- **C-string env buffers:** `ensureCStringBuffer` fills once and never mutates
  the array again, so `withUnsafeBufferPointer` baseAddresses remain stable for
  the session lifetime. `GET_SYSTEM_DIRECTORY`/`SAVE_DIRECTORY`/`LIBRETRO_PATH`
  are set before `retro_init` — correct.
- **PixelConverter BGRA paths:** 565/1555/XRGB conversions are consistent with
  the libretro little-endian memory order and Metal `bgra8Unorm`. GL readback
  uses `GL_BGRA` and flips rows in-place before `frameSlot.push(.xrgb8888)`, so
  the channel order and orientation are correct.
- **Audio ring under/overflow:** `writeSample` and `writeBatch` lock once;
  `read` zero-fills on underflow; no buffer overrun (modulo arithmetic). OK.
- **`requestStop` join guard:** if `state == .loaded` (never started),
  `runThread == nil` so `threadDone.wait()` is skipped — no deadlock on the
  not-started path.
- **`--diagnose-input` / `--probe-core` arg indexing:** correct (`args.count >= 4`,
  args[2]/[3]).
- **FrameSlot reallocation** only grows; smaller frames reuse the larger buffer —
  no overrun.

---

## Summary of top actionables
1. **P1-1** — Wire `ControllerManager.snapshot` into `EmulatorSession` (input is
   currently dead in the GUI).
2. **P1-2** — Fix `RetroEnvironment` cmd 56/57 labeling + handling.
3. **P2** — Analog Y sign, RecentsStore race, SteamHandoffMonitor stale state,
   PPSSPP double-launch, blocking `exitEmulation`, DualSense button overloading.
4. **P3** — shim.h guard, lock-scope in MetalRenderer, plist accessibility
   string, etc.

SCOUT REVIEW DONE
