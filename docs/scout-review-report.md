# GameDock — Code Review Scout Report

**Date:** fresh full re-review of the current tree.
**Scope:** all `.swift`/`.c`/`.h` under `Sources/` and `Tests/`, plus
`Package.swift`, `Makefile`, `Info.plist`, `build-app.sh`.
**Verification performed:** `swift build` (clean), `make mock-core` +
`GAMEDOCK_CORE_PATH=build/mockcore.dylib swift run GameDock --selftest` → **PASS**,
`swift run GameDock --ra-selftest` → **PASS**.

Priorities: **P0** = guaranteed user-visible failure; **P1** = likely bug in a
reachable path (corrupts behavior/memory); **P2** = correct but risky /
latent crash / wrong-in-practice; **P3** = polish / hardening.

---

## P0

None found on the normal path. This build compiles clean, both self-tests pass,
and the headline plumbing (controller → session input, environment commands,
libretro callbacks) is wired correctly. The closest to P0 is the P1-1 hung-core
teardown below.

---

## P1

### P1-1. Teardown while a hung core thread is still running → use-after-free / dlclose-while-executing
- **Files:** `Sources/GameDock/Launch/EmulatorSession.swift` (`requestStop` ~line
  295, `teardown` ~line 310), `Sources/GameDock/AppEnvironment.swift`
  (`exitEmulation` ~line 340).
- **Problem:** `requestStop()` waits on `threadDone` with a **2-second timeout**.
  If the core is stuck inside `retro_run()` (a hung misbehaving core), the wait
  times out and `requestStop` returns `.stopped`. `exitEmulation` then immediately
  calls `teardown()`, which — with the core thread still executing — calls
  `core?.retroUnloadGame()`, `core?.retroDeinit()`, `core?.unload()` (i.e.
  `dlclose`), `rcService.destroy()` (`rc_client_destroy`), and
  `bridge.runContextDestroy`. Unmapping (`dlclose`) a dylib while a thread is still
  executing inside it, or calling `retro_deinit`/`rc_client_destroy` while another
  thread can re-enter them, is undefined behavior → crash. The run loop also reads
  `rcService?.doFrame()` after each `retro_run`, so if the stuck thread resumes it
  can call into a destroyed `rc_client`.
- **Suggested fix:** If the core thread does not join within the timeout, do not
  call any libretro/rc_client teardown on the live dylib from another thread.
  Either (a) force-terminate the core thread (unviable with threads; use a
  cooperative stop only), (b) refuse to `dlclose`/deinit while the thread lives and
  leak it deliberately in the degenerate hang case, or (c) run the whole
  `retro_run` + teardown on a single long-lived thread for the session so teardown
  and execution can never overlap. At minimum, guard teardown so a timed-out
  session is torn down on a thread that first confirms the run thread has exited.
- **Related:** `exitEmulation` runs this on the **main thread**, so even in the
  healthy case the UI thread blocks up to 2 s waiting to join.

---

## P2

### P2-1. `InputSnapshot.readButton` can trap on `1 << UInt32(id)` for id ≥ 32
- **File:** `Sources/GameDock/Controllers/GamepadInput.swift` (`readButton`, ~line 96).
- **Problem:** `setButton` guards `(0...31).contains(id)`, but `readButton`
  (called from the core via `handleInputState`) does **not** bounds-check `id`
  before `buttons[port] & (1 << UInt32(id))`. In Swift, `1 << 32` on a `UInt32`
  literal is a runtime trap. A core that queries an unsupported/unusual joypad id
  (≥32) would crash the app rather than returning 0. MelonDS/PPSSPP typically stay
  in 0…15, but the asymmetry is a genuine fault line for arbitrary cores.
- **Suggested fix:** mirror the `setButton` guard in `readButton`:
  `guard port < buttons.count, (0...31).contains(id) else { return 0 }`.

### P2-2. `SET_HW_RENDER` accepts unsupported context types (e.g. Vulkan) and claims success
- **Files:** `Sources/GameDock/Launch/EmulatorSession.swift`
  (`handleHWRenderRequest`, ~line 455), `Sources/GameDock/Launch/GLHardwareBridge.swift`
  (`init?`, ~line 38).
- **Problem:** `handleHWRenderRequest` returns `true` for **any** `context_type`,
  and `GLHardwareBridge.init` falls back to a GL core-3.2 profile for all
  unhandled context types. If a core requests `RETRO_HW_CONTEXT_VULKAN` (6),
  D3D11/9, etc., the frontend hands it a GL context + a GL FBO
  (`gd_get_framebuffer`) and says "supported." A Vulkan-only core will misinterpret
  the GL FBO handle and crash. PPSSPP requests OpenGL Core so this is fine today,
  but the code should decline (return `false`) for anything outside the supported
  GL legacy/core profiles.
- **Suggested fix:** in `handleHWRenderRequest`, return `false` unless
  `context_type` is `RETRO_HW_CONTEXT_OPENGL` or `RETRO_HW_CONTEXT_OPENGL_CORE`
  (the two profiles `GLHardwareBridge` explicitly handles).

### P2-3. `RCClientService` retains rc_client-owned pointers past `destroy()`
- **File:** `Sources/GameDock/RetroAchievements/RCClientService.swift`
  (`serverCall` / `Pending` / `drainPending`, ~lines 260–330).
- **Problem:** `serverCall` snapshots `callback` + `callbackData` (pointers owned by
  the `rc_client`) into a `Pending`, then calls `performHTTP` on a background queue.
  `destroy()` calls `rc_client_destroy`, empties `pending`, and `setActive(nil)`.
  If an in-flight request completes **after** `destroy()`, the completion closure
  (captured `[weak self]`) re-enqueues a `Pending` holding a **dangling**
  `callbackData` onto the destroyed-but-still-retained instance. Because that
  instance is no longer pumped (`doFrame` never runs again), the entry is never
  dereferenced — so today it is benign — but it is writing to a dead object from a
  background thread and can become a real use-after-free if drain is ever re-run.
- **Suggested fix:** capture a generation/token at `create()` time and drop the
  `enqueue` in `serverCall`'s completion when the token differs, or null the shared
  `[weak self]`-observable callbackData path on `destroy()`. Simplest robust guard:
  have `enqueue` no-op if `self.client == nil`.

### P2-4. `ArtworkLoader` permanently marks a key `failed` on one transient network blip
- **File:** `Sources/GameDock/Libraries/ArtworkLoader.swift` (`load`, ~line 55;
  `fetchRemote`, ~line 140).
- **Problem:** `load` inserts `failed.insert(key)` every time it takes the remote
  path (even while a fetch is in flight). `failed` is only ever removed by a
  successful `store`. If the CDN is briefly unreachable (or returns bad data), the
  key stays failed for the whole app session and `ArtworkView` shows a placeholder
  forever — the retry triggered by `loadedKeys` never fires because the key is in
  `failed`. There is no offline→online recovery.
- **Suggested fix:** remove the `failed` mark for the in-flight case (only mark
  after a fetch actually errors), and/or allow `loadedKeys`/a rescan to clear the
  failed set for retry; or add a limited retry rather than a permanent tombstone.

### P2-5. `RetroAudioEngine` start (background) vs stop (main) race
- **Files:** `Sources/GameDock/Launch/RetroAudioEngine.swift` (`start`/`stop`),
  `Sources/GameDock/Launch/EmulatorSession.swift` (`start`, ~line 230).
- **Problem:** `EmulatorSession.start()` begins `engine.start()` on a global queue
  while setting `self.audioEngine = engine` from the caller (main). `teardown()`
  calls `audioEngine?.stop()` on main. If teardown runs before the global block
  finishes `engine.start()` / sets `isRunning = true`, `stop()` early-returns on
  `guard isRunning` and the engine is orphaned **running** (silence from the ring),
  keeping a strong ref to `audioRing`. Small race window (session normally runs for
  seconds), but it leaks audio and can keep the audio device busy after the
  emulator is gone.
- **Suggested fix:** start the engine synchronously for the run thread, or gate
  `start()`/`stop()` on a single lock and have `stop()` wait for an in-progress
  `start()` to finish.

### P2-6. Core self-shutdown leaves the frontend on the emulator screen
- **File:** `Sources/GameDock/Launch/EmulatorSession.swift` (`runLoop`, ~line 280):
  sets `stopRequestedFlag` on `environment.shutdownRequested` but never tells the
  UI. No observer calls `exitEmulation`. A core requesting `RETRO_ENVIRONMENT_SHUTDOWN`
  ends its program but the app stays fullscreen on the frozen emulator surface.
- **Suggested fix:** surface a session-completion callback that `AppEnvironment`
  uses to return to XMB and teardown on `shutdownRequested`.

---

## P3 (polish / hardening)

- **P3-1. `Package.swift` invalid exclude warnings.** The `exclude:` list for
  `CRcheevos` references `Sources/CRcheevos/src/rc_libretro.c` and `.h`, which do
  not exist in the vendored copy → two spurious build warnings on every build.
  Remove those two entries (they're already absent, so no need to exclude them).
- **P3-2. `ControllerManager.connect` is last-wins (single port).** Each connect
  overwrites `activeController` and re-hooks the same fixed port-0 `InputSnapshot`;
  no multi-controller support, and a second connected controller silently takes
  over input from the first. `buttonInventory`/`connectedControllerName` reflect
  only the last. Acceptable for v1 ("DualSense primary") but worth documenting and,
  ideally, gating on "prefer the first still-connected controller."
- **P3-3. `Haptics.tick` never evicts disconnected controllers.** Engines are keyed
  by `ObjectIdentifier(controller)` in a static dict with no removal on `.GCControllerDidDisconnect`;
  long sessions with churn leak a few `CHHapticEngine`s.
- **P3-4. `RetroAudioRingBuffer.writeBatch` claims full consumption despite
  drop-oldest overflow.** `shim_audio_batch`'s "claim consumption so cores keep
  running" contract lies about how much was actually buffered when the ring overruns
  — acceptable, but it means silent audio is not a flow-control signal to cores.
- **P3-5. Retained `[CChar]` pending bodies.** `Pending.body` is rebuilt per
  response; fine, just note `drainPending` copies `body_length = count - 1` trusting
  the NUL terminator from `utf8CString` — O(1), correct today.
- **P3-6. `SettingsNavModel.selection` is dead state.** It's `@Published` and
  clamp-guarded in `rebuild` but nothing reads or writes `itemIndex` against it; the
  Settings item cursor actually lives in `XMBNavModel.itemIndex`. Remove or wire it.
- **P3-7. `ArtworkLoader` LRU cap evicts even in-focus art on a huge library.** The
  200-entry cap (per `store`) is fine, but a selected item's art can be evicted
  while the game is a couple categories away, causing a re-decode on the next focus.
  Minor.
- **P3-8. PPSSPP standalone `stop()` uses `process?.terminate()`.** Best-effort;
  `SIGTERM` may leave the emulator's save delta unflushed. Consider a graceful
  quit if the app exposes one.

---

## Verified non-issues (checked, OK)

- **Input wiring is correct in the current tree:** `AppEnvironment.startEmulator`
  passes `inputSnapshot: controllers.snapshot`, so GUI gamepad/keyboard input now
  reaches `handleInputState`. (The previously-reported P1-1 is fixed.)
- **ABI-critical C types:** `bool` writes in `RetroEnvironment` (`GET_CAN_DUPE`,
  `SET_SUPPORT_NO_GAME`, `GET_FASTFORWARDING`, `GET_JIT_CAPABLE`,
  `GET_INPUT_BITMASKS`) use `assumingMemoryBound(to: Bool.self)` — 1 byte, matching
  C `bool`. `retro_log_printf_t` is handled via `shim_get_log_printf()` (C variadic)
  rather than a Swift `@convention(c)` variadic — correct.
- **Environment command constants** in `libretro.h` are canonical (incl. the
  `0x10000` EXPERIMENTAL bit on 25/26/36/40-50/71-77 etc.); the `RetroEnvironment`
  switch routes correctly.
- **String-buffer lifetime:** `ensureCStringBuffer`/`writeCStringPointer` point at
  stable session-owned `[CChar]`, queried after `systemDirectory`/`saveDirectory`/
  `libretroPath` are set before `retro_init` — safe.
- **GL context threading:** `GLHardwareBridge` calls `context.makeCurrentContext()`
  on whichever thread performs the GL op (core thread for `prepareFrame`/`readPixels`/
  `runContextReset`, main for setup/destroy), so the GL "current" invariant holds.
- **`gd_get_proc_address`:** uses `dlsym(RTLD_DEFAULT=-2)` and
  `CGLGetProcAddress` for extensions rather than a no-op stub — avoids the
  no-op-corrupts-return-value crash called out in the notes.
- **Pacing:** the run loop sleeps `interval` with a `max(interval, 0.001)` floor and
  resyncs to `now` when it falls behind — no busy-spin, bounded drift.
- **Analog Y sign:** stores `down - up` (= −1 up) and `readAnalog` returns
  `Int16(v * 0x7FFF)`; up → negative, which is the correct DirectInput/libretro
  convention. `driveStickNav` receives `−y` so nav UX matches.
- **Metal texture upload matches row stride:** `FrameSlot.withLatest` reports
  `width * 4`; `PixelConverter` output is tight-packed; `MetalRenderer` uses the same
  stride for `bytesPerRow`. The GL readback (BGRA, tight) also matches.
- **`shim_install` / dlsym ordering:** `setup callbacks → dlopen(RTLD_GLOBAL) →
  install → retro_init` — environment strings are set in `load()` before
  `retro_init`, satisfying the audit requirement.
- **`recents`/`settings` persistence:** writes are `atomic`; `RecentsStore.record`
  snapshots under its own lock; main-thread mutation of the `@Published` lists is
  consistent with the SwiftUI observation pattern used.

---

## Summary of top actionables

1. **P1-1** — Make session teardown hang-safe: never deinit/dlclose/destroy the
   core or rc_client while the core thread may still be executing; avoid doing the
   2 s join on the main thread.
2. **P2-1** — Add the `(0...31)` guard to `InputSnapshot.readButton`.
3. **P2-2** — Decline `SET_HW_RENDER` for non-GL context types.
4. **P2-3** — Guard `RCClientService.enqueue` against `client == nil`.
5. **P2-4** — Don't tombstone artwork keys on a single transient failure.
6. **P2-5/P2-6** — Serialize audio-engine start/stop; observe core shutdown to
   leave the emulator screen.

SCOUT REVIEW DONE
