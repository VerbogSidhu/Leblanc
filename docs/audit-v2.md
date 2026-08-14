# GameDock Code Audit — v2 (scout, read-only)

Scope: everything under `Sources/` plus `Tests/MockCore/mockcore.c`, `Package.swift`,
`Makefile`. No files edited. ABI-critical surface (`Sources/CLibretro`) flagged but not changed.

Key numbers up front:
- ~40,774 lines total across Sources/Tests. Swift app ~7,500 lines; `CRcheevos` C ~29,410 lines.
- `CRcheevos` is **compiled but completely unreferenced from Swift** — the single biggest lightness lever.
- 5 fonts (~584 KB) are the only bundled resource, and 1 (`JetBrainsMono-Regular`, 270 KB) is barely used.

---

## 1. CORRECTNESS (bugs, races, leaks)

### 1.1 — `EmulatorSession.teardown()` runs `retro_*` off the core thread — by design, but fragile
`Sources/GameDock/Launch/EmulatorSession.swift:393-410`
Teardown `dlclose`s the core (via `core.unload()`) **after** `retro_deinit`/`retro_unload_game`, on the *calling* thread (whatever called `exitEmulation()` — main). AGENTS.md's rule is "never call retro_* from two threads at once; load/unload happen on a dedicated session lock". There is **no session lock**; teardown races the (already joined) core thread *only* — which is fine because `requestStop()` joins first. But `requestStop()` joins with a **2 s timeout** (`EmulatorSession.swift:372-378`) and then proceeds to teardown even when the join timed out. If the core thread is stuck inside `retro_run` (a hung core), teardown will `dlclose` the dylib while the stuck thread is executing it → **use-after-free / crash at teardown**. Recommendation: if the join times out, either `exit()` (fail hard) or leak the core without dlclose. Currently the timeout path proceeds to unmap live code.

### 1.2 — `EmulatorSession.active` is per-session but the **shim callbacks are process-global and not re-armed thread-safely**
`Sources/GameDock/Launch/EmulatorSession.swift:96-113` (`EmulatorSession.setActive` uses a lock) vs `Sources/CLibretro/shim.c:16-19` (`g_cb` is a plain global, written by `shim_set_callbacks` with **no synchronization**).
`load()` calls `shim_set_callbacks` then `shim_install()` then `setActive(self)`. Since a single session is loaded at a time on the calling thread, this is *currently* correct, but nothing prevents two `EmulatorSession`s being constructed concurrently (two rapid `startEmulator` taps). `AppEnvironment.startEmulator` doesn't guard against an already-active session. Risk: two sessions swapping `g_cb` and `_active` across threads → callbacks route to the wrong session. The `activeLock` protects `_active` but **not** `g_cb`. Low likelihood today (UI is single action at a time) but a real latent race; note for the RA work (which will add a second cross-thread user of a session).

### 1.3 — `FrameSlot` pitch lies to the renderer
`Sources/GameDock/Launch/FrameSlot.swift:63-72`
`push` stores `self.pitch = pitch` (the *source* pitch) but `withLatest` returns `width * 4` as the caller's `pitch`/rowBytes. `PixelConverter` always writes tightly-packed `width*4`, so `width*4` is correct for consumption — but the stored `pitch` field is misleading dead state, and `MetalRenderer.draw` trusts `withLatest`'s rowBytes. **Not a bug today** (dst is always tight), but `withLatest` passes `width * 4` while the slot also exposes `pitch` (the src pitch) — a future caller reading `frameSlot.pitch` will get the wrong stride. Recommend dropping the stored `pitch` field.

### 1.4 — `MetalRenderer.draw` does the GPU texture `replace(...)` **inside the FrameSlot lock**
`Sources/GameDock/Launch/MetalRenderer.swift:105-118` + `FrameSlot.withLatest` lock.
`texture.replace` is a blocking CPU→GPU copy of a whole frame (e.g. 960×544×4 ≈ 2 MB for PSP-GL, more for melonDS-GL at 2×). This runs under `frameSlot.lock` while `push` (core thread) wants the same lock. Result: the core thread stalls in `push` during the upload — a shared-lock convoy every frame. This ties the emulator thread's pacing to the render thread's upload. Better: read a pointer under the lock, release, then `replace` outside (already the pointer is valid because `buffer` is stable until the next `push`'s realloc — but realloc on the core thread invalidates it, so you'd need a refcounted/ring of buffers). Flag as hot-path contention, not a memory corruption today (the lock makes it safe, just slow).

### 1.5 — `FrameSlot` reallocate-under-render race window (latent)
`FrameSlot.push` deallocates + reallocates `buffer` when capacity grows, **under the lock** — so a renderer holding the old pointer after `withLatest` returns would be safe only if the renderer never touches it after unlock. `MetalRenderer.draw` uses the pointer *inside* `withLatest`, so current usage is safe. Any future "retain the frame pointer" refactor (e.g. for the RA overlay compositing, or `--probe-core` PNG dumps that memcpy after unlock) would be a UAF. Note for the RA planner.

### 1.6 — `RetroEnvironment` multi-byte writes to 1-byte `bool`
`Sources/GameDock/Launch/RetroEnvironment.swift:60-65` writes `Bool` to `GET_CAN_DUPE` — correct (stdbool is 1 byte, Swift `Bool` is 1 byte, Apple-matching). `GET_INPUT_BITMASKS` (`:183-186`) also `Bool` — correct. `GET_FASTFORWARDING` (`:168-171`) `Bool` — correct. These are all fine. No bug, but they are fragile: if a future core compiled with `-fno-char8_t`/different bool size, these would corrupt. RetroArch has dealt with this via unions; low risk on Apple Silicon.

### 1.7 — `RetroAudioRingBuffer.writeSample` skips the underflow/drop bookkeeping differently from `writeBatch`
`Sources/GameDock/Launch/RetroAudioEngine.swift:44-61`
`writeBatch` uses a single loop; `writeSample` writes L then R then handles overflow — but writes the **right channel before adjusting `count` on overflow** and can overwrite `readIdx`'s current sample inconsistently across the two writes. Minor, but a single-sample path with a full buffer can briefly expose a "phantom" interleaving. Since cores overwhelmingly use `audio_batch`, this path is rarely hit (mock core uses batch). Not user-visible today.

### 1.8 — Audio source node block returns the wrong interleaving for non-2-channel config; hardcoded 2
`Sources/GameDock/Launch/RetroAudioEngine.swift:96-100` — `ring.read(buf, maxSamples: frameCount*2)` and `abl[0].mData`. `AVAudioSourceNode` with an interleaved stereo format gives one `AudioBufferList` with 1 buffer (2 channels) — correct. But `channels` lives on the ring as constant 2 while the engine's `format.channelCount` is not cross-checked. If a core ever reports a non-2 audio rate, buffer sizing (`maxSamples = frameCount*2`) stays hardcoded. Note only.

### 1.9 — `readPixels`/`prepareFrame` GL calls all run on the core thread — OK, but teardown breaks the rule
`Sources/GameDock/Launch/GLHardwareBridge.swift` — all `gl*` calls happen in `runLoop` (core thread) or in `runContextDestroy`/`destroy` during teardown (other thread). The GL context is **not made current on the teardown thread** in `destroy()` except `makeCurrentContext()` is called there — `NSOpenGLContext` permits context switching across threads only if serialized with the core thread's use. Since teardown happens after the join, this is safe *in the happy path* but inherits 1.1's timeout risk (destroy runs GL calls while a stuck core thread still holds the context current → undefined behavior on that context).

### 1.10 — `AppDelegate.retryFullscreen` never bails on success, and keeps resizing every 0.25 s
`Sources/GameDock/AppDelegate.swift:40-67`
Once the window enters fullscreen, the `didBecomeKey` observer path returns early only in the `styleMask.contains(.fullScreen)` branch, but the **scheduled** `retryFullscreen` continuation still runs (it checks `guard attempt < 40` → 40 attempts ≈ 40×0.25 s ≈ 10 s of churn, each doing `setFrame(visibleFrame)` + `toggleFullScreen`). After the window is already fullscreen, `window.setFrame(screen.visibleFrame, ...)` is harmless, but the pattern loops a full 40x even when the first toggle succeeds. Minor wasted work / window fluting on every app launch; plus `makeFrontendFullscreen` is called from both the observer and the retry, so fullscreen can be toggled twice (enter then immediately exit) on slow launches — a known flake if the toggle lands between the observer and the retry's `styleMask` check.

### 1.11 — `GlobalHotkeyManager` registers on the main run loop only; handoff restore races window state
`Sources/GameDock/Core/GlobalHotkeyManager.swift` — fine. But `restoreFrontend` (`AppDelegate.swift:78-85`) calls `makeFrontendFullscreen` which does `window.toggleFullScreen(nil)` — if the window wasn't in fullscreen when hidden (Steam handoff hides via `orderOut`), restoring toggles it *into* fullscreen. Because `orderOut` during handoff keeps the window's styleMask, on restore the `styleMask.contains(.fullScreen)` may already be true → skip toggle → window reappears windowed. Inconsistent restore after Steam handoff vs after emulator. Note.

### 1.12 — `ControllerManager` `controller.playerIndex = .index1`
`Sources/GameDock/Controllers/ControllerManager.swift:77` — hardcodes `.index1` for every controller. `InputSnapshot` reads port 0 for input regardless; `playerIndex` here is about LED/controller slot, cosmetic only. Not a bug, but dead assignment (nothing reads playerIndex). See 2.3.

### 1.13 — Emulator input: analogue sign for stick nav
`Sources/GameDock/Controllers/ControllerManager.swift:113-117` — `driveStickNav(x: x, y: -y)` inverts Y for nav, and `hookStick` stores `y = s.down.value - s.up.value` (so pushing up → negative Y, DirectInput convention) then passes `-y` to nav. UI "up" = stick up: y_raw (up) = -value, so nav gets `-(-)` = + → `.up`. Correct, but the sign dance is done twice (nav and snapshot) and has been a source of subtle bugs; worth a comment update. Not a bug.

### 1.14 — `LibraryStore.refresh()` has no cancellation / stale-result guard
`Sources/GameDock/Libraries/LibraryStore.swift:44-55`
If a scan is in flight and `refresh()` is called again, the `isScanning` guard drops it — good. But a scan started before a settings removal can publish results captured *before* the change. Minor staleness; acceptable.

### 1.15 — `RecentsStore.save()` writes outside the lock, on the caller's thread
`Sources/GameDock/Libraries/RecentsStore.swift:80-91` — `record()` locks, mutates, unlocks, then `save()` re-locks for the snapshot and does `Data` encode + disk write on the caller's thread (main). During emulator launch on main this is a small synchronous disk+JSON write → can hitch the UI. Note for performance section.

### 1.16 — `XMBView.itemBar` `ForEach(lo...hi, id: \.self)` indexes can go stale
`Sources/GameDock/UI/XMBView.swift:88-99` uses array indices `lo...hi` computed from `itemIndex`; the `ForEach` uses the *index* value `i`, then reads `cat.items[i]`. If `cat.items` and `itemIndex` are briefly out of sync during a rebuild (category switch), `cat.items[i]` could be out of bounds → SwiftUI crash. `XMBNavModel.rebuild` clamps `itemIndex` before the next body eval so it's normally safe, but a `@Published` category update and itemIndex update in the same transaction can transiently expose `itemIndex > items.count-1`. Note.

---

## 2. LIGHTNESS (dead code / bloat to strip)

### 2.1 — `CRcheevos` (29,410 C lines) is a **dead weight** build dependency — the single biggest lever
`Package.swift:49-62` — the `GameDock` target lists `CRcheevos` in `dependencies`. **Zero Swift code references** `rc_client`, `rc_hash`, or any `CRcheevos` symbol (verified: `grep -rl CRcheevos Sources/GameDock` returns nothing). So every `swift build` compiles the **entire vendored rcheevos stack** (rapi, rhash with MD5/AES/CD reading/hash_zip, rcheevos runtime, rc_client) into a target that doesn't call any of it. That's the full cost of the RetroAchievements integration with none of the benefit.

    Actions (pick per milestone, see §4):
    - **Now:** drop `CRcheevos` from `GameDock`'s dependencies (keep the target in the package) until the RA integration lands → removes ~29k lines from every build of the app binary.
    - When RA lands: build it as a **separate target** that Swift links via a thin typed wrapper (`RCClientService`), so the monster C stays encapsulated.

### 2.2 — `GLHardwareBridge` — keep? It is wired but effectively dead in v1
AGENTS.md §6: PPSSPP ships via the user's **standalone** app; the embedded libretro path targets **software-render cores** (melonDS DS, mock core). The GL bridge (`Sources/GameDock/Launch/GLHardwareBridge.swift`, ~260 lines) is exercised only if a core requests `SET_HW_RENDER` (env cmd 14) — melonDS uses a GL2/software path that v1 doesn't enable; the sole intended consumer was PPSSPP-libretro which is now standalone. So **the GL bridge is currently dead weight** (~260 Swift lines + all the hw branches in `EmulatorSession`).
    - Recommendation: **do not delete** — it's the reference for the future melonDS-GL/3D path and RA needs the GL→FrameSlot pipeline intact — but consider `#if` gating it or confirming no v1 core requests hw render. At minimum, the `gd_get_framebuffer`/`gd_get_proc_address` globals (`EmulatorSession.swift:53-80`) are only meaningful with GL; fine to keep. Flag: if melonDS libretro ships an OpenGL core variant, this becomes live.

### 2.3 — `controller.playerIndex = .index1` dead assignment
`Sources/GameDock/Controllers/ControllerManager.swift:77`. Nothing reads `playerIndex`. Strip or keep as cosmetics (DualSense LED slot). Cheap to keep, flag as remove-able.

### 2.4 — `EmulatorMetalView.mtkView(_:drawableSizeWillChange:)` is a no-op
`Sources/GameDock/Launch/EmulatorMetalView.swift:49-51`. The delegate method is required but empty (renderer reads `view.drawableSize` each frame). Legit placeholder — but the `didSet` of `frameSlot` and `EmulatorView.updateNSView` set the slot twice on every `updateNSView` pass. Harmless; collapse if desired.

### 2.5 — `FrameSlot.pitch` (see 1.3) is dead/misleading stored state
Drop the `private(set) var pitch` field; the renderer needs `width*4` only.

### 2.6 — Unused Theme tokens
`Sources/GameDock/UI/Theme.swift` defines `itemTitleUnselected`, `railHeight`, `screenPadding`, `fade` — grep shows they are **never referenced** in other files. `Theme.accent(for:)` is used only by `ArtworkView.placeholder`. Small dead-code trim (5 tokens). Also `Theme.ember`, `Settings` accents are used.

### 2.7 — `GameDockFonts.data` / JetBrains Mono (270 KB) usage
`JetBrainsMono-Regular.ttf` (270 KB of the 584 KB font budget) is used for `Theme.meta` (last-played subtitle, settings details) — a handful of tiny labels. `ChakraPetch` ×4 (~314 KB) carries the UI. The Mono face is a legitimate but heavy accent font; if weight is a priority, drop Mono and render meta with ChakraPetch-Regular or system mono → saves ~270 KB in the bundle. `GameDockFonts.data` currently routes through `Theme.meta` only.

### 2.8 — `CLIProbeCore` writes a PNG to `/tmp` and does a full-pixel loop — fine (debug), but the `--probe-core` path duplicates `--selftest`'s session harness
`Sources/GameDock/CLI/CLI.swift:189-263`. Acceptable debug tool; note it opens an `NSBitmapImageRep` (AppKit) — meaning the CLI app pulls AppKit into the headless path, which it already does (the whole target is a GUI app). Not removable.

### 2.9 — `GlobalHIDMonitor` capture is experimental and off; keep as-is (diagnostic contract)
AGENTS.md marks it ⚠️. Only `describeDevices()` is used (by `--diagnose-input`). The capture half (`startCapture`/`stopCapture`) is unused by any production code path. Keep for the roadmap but it is today a ~90-line dead slab behind an opt-in `var`.

### 2.10 — Duplicate doc comment
`Sources/GameDock/UI/XMBNavModel.swift:97-98` — "Applies an action..." comment duplicated. Cosmetic.

### 2.11 — `WaveFieldModel.Ripple.id` is a `UUID()` created per ripple; `emit` appends+prunes each nav tick
Minor allocation churn (see §3.3).

---

## 3. PERFORMANCE

### 3.1 — Wave field redraw: the hot ambient cost
`Sources/GameDock/UI/WaveField.swift:49-77`
Every `TimelineView(.animation)` frame (60 fps nominal, more on ProMotion):
- 5 layer sine strips, each `for x in stride(0...width, by:5)` building a `Path`, then `ctx.fill(path)` + `ctx.stroke(path)`.
- On a 4K fullscreen XMB canvas that's ~5 layers × (≈1536 points at stride 5) — ~7,700 `sin()` calls + 10 path fills/strokes, **rerun every frame even when nothing changed**, behind *everything* (allowsHitTesting(false)).
- Cost is real on Apple Silicon iGPU. Optimizations:
  1. **Cache the static layer shape**: the path geometry (base Y, amplitude, wavelength) is constant; only the phase `+ layer.3 * t` animates. Render the wave as a pre-baked offscreen CGLayer/Metal texture and scroll/skew it, or reduce layers to 3.
  2. **Skip re-render when idle**: if no ripple and `t` delta ≈ 0 (paused) skip. The ripples only matter on nav; the idle waves could be a much lower-frequency update (e.g. every 2nd frame).
  3. Halve the stride (×2 points) — sub-pixel fine for a 0.05-opacity fill.
  This is the biggest single-frame CPU cost in the XMB. AGENTS lists "the wave-field draw cost" as a known hotspot — it is.

### 3.2 — Artwork cache: memory + disk, but re-fetches and re-decodes happen on `loadedKeys` drives
`Sources/GameDock/Libraries/ArtworkLoader.swift`:
- `cache` is unbounded `[String: NSImage]` — every banner+cover per game cached forever (XMB can hold hundreds). A 200-game library at ~1 MB decode each is ~400 MB of RAM cached. **Add an LRU cap** (~200 images / ~256 MB).
- Disk cache writes synchronously to `AppPaths.artworkDir` via `data.write` on the URLSession completion queue — fine (background).
- **Hot path:** `ArtworkView.onAppear(load)` + `.onReceive(loader.$loadedKeys)` calls `load()` again on every `loadedKeys` change while the view is alive — each `load()` re-checks `cache` (cheap) but `ArtworkLoader.cover`→`load(... fallback: .banner)` does **two NSImage decodes + a file copy** when no cover exists, per view-body. With many covers in the XMB stack this multiplies.
- `NSImage(contentsOfFile:)` decode re-runs on every cold `load()` even when `cache` says nil. Consider a `failed: Set<key>` so a missing cover is not re-decoded repeatedly.

### 3.3 — Navigation-driven `WaveFieldModel.emit` alloc + `selectionMoved()`
`Sources/GameDock/AppEnvironment.swift:190-193` + `WaveFieldModel.emit` (`WaveField.swift:16-18`): every selection change allocates a `Ripple` (UUID + Color + timestamp) and runs a `removeAll`. Trivial per event but does run on the UI thread alongside the whole `xmb` `@Published` mutation. Fine.

### 3.4 — Per-frame emulator work
- `PixelConverter` converts RGB565 (DS) / XRGB (GL readback) per frame on the core thread — a 320×240 DS frame is cheap, but a PSP-GL 960×544×4 XRGB→BGRA copy + memcpy + vertical flip in `readPixels` (`GLHardwareBridge.readPixels`, `EmulatorSession.swift:435-459`) is ~4 MB/frame + flip. This is inherent to the readback design; if performance is ever a target, an IOSurface/TexSubImage path would remove the CPU round-trip (RetroArch uses IOSurface). Note as future work, not a v1 regression.
- `MetalRenderer.draw` holds the FrameSlot lock during `texture.replace` (see 1.4) — the **real** per-frame bottleneck once a GL core is live.

### 3.5 — `LibraryStore` scan strategy
`Sources/GameDock/Libraries/LibraryStore.swift:57-78`:
- Runs on a dedicated `scanQueue` — good, off-main.
- **But** it calls `steam.gameEntries()` which rescans the **entire Steam library from disk every refresh** (parses every `appmanifest_*.acf`), and `roms.scan` recursively walks every ROM folder. `refresh()` runs on every app launch and every settings add/remove/rescan.
- `scanSynchronously` then does a per-entry `recents.lastPlayedDate(for:)` — `O(games × recent)` linear over the recents list (≤20) — fine.
- **Biggest issue:** no caching/diff. On cold launch it re-reads all manifests and re-walks all folders, then rebuilds XMB. For a modest DS/PSP collection this is fast; for a 500-game Steam library it's hundreds of file `String(contentsOf:)` reads on the scan queue. Acceptable now, but there's no `mtime`-based incremental rescan, so every app relaunch pays the full cost. Also `RomLibrary.scan` allocates a `GameEntry` per file then sorts — fine.
- `settings` `@Published` mutation from `AppEnvironment.settingsAction` triggers `library.refresh()` anew per change — two rescans for a remove (one in the folder case, one via `rebuildXMB`).

### 3.6 — `LibraryStore` derived collections are O(n) filters recomputed per body eval
`steamGames`/`pspGames`/`dsGames`/`recentGames` are computed properties over `games` — called by `XMBView`/`AppEnvironment.rebuildXMB` each navigation/render. With thousands of entries and SwiftUI recompute this is churn; precompute per-source arrays in `LibraryStore` on scan instead of filtering each read.

### 3.7 — `AppEnvironment.metaLine` with `DateFormatter` allocated per item
`Sources/GameDock/AppEnvironment.swift:155-162` — a new `DateFormatter` per game item per rebuild. Cache one static formatter.

---

## 4. RETROACHIEVEMENTS HOOKS

### 4.0 — Current state
`CRcheevos` is vendored + built (see 2.1) but nothing calls it. Read `Sources/CRcheevos/include/rc_client.h` (934 lines) for the full surface. The integration can be added without touching `CLibretro` (all needed libretro entrypoints already exist).

### 4.1 — Which libretro memory regions `retro_get_memory_data/size` exposes
Types (canonical ids, from `Sources/CLibretro/include/libretro.h:117-121` and wired through `RetroCore`):
- `RETRO_MEMORY_SAVE_RAM = 0` — battery-backed save RAM; persistent across sessions, the main integrity region.
- `RETRO_MEMORY_RTC      = 1` — real-time-clock bytes.
- `RETRO_MEMORY_SYSTEM_RAM= 2` — live system RAM (the primary **achievement-cheating region** for most cores: melonDS/DS exposes its main RAM here).
- `RETRO_MEMORY_VIDEO_RAM = 3` — VRAM.

Swift access is already present: `RetroCore.retroGetMemoryData`/`retroGetMemorySize` are resolved at `Sources/GameDock/Launch/RetroCore.swift:75,78` and typed as `RetroGetMemoryDataFn`/`RetroGetMemorySizeFn` (`RetroCore.swift:73-78`). **Constrained to the core thread** per AGENTS' threading rule (never call retro_* from two threads). The RA `read_memory` callback WILL run on whatever thread calls `rc_client_do_frame` — so it must be invoked only on the core thread (see 4.3).

Mapping plan:
- **ROM hashing** (identify the game) uses the **ROM image bytes**, not `retro_get_memory_data`. The `rc_hash` library (included) hashes files/CDs. GameDock already holds the ROM as `romPath` (and `romData` bytes in `EmulatorSession.init`). For non-fullpath cores `romData` is the raw buffer; for fullpath cores read the file. `rc_client_begin_identify_and_load_game(console_id, file_path, data, size, ...)` (`rc_client.h:319-327`) takes either path or in-memory bytes — pass `romPath` + nil data for need_fullpath cores; pass `nil` path + `romData` for memory cores. Console id must map (see 4.5).
- **RAM reads** (in-game achievement checks) use `RETRO_MEMORY_SYSTEM_RAM` (primary), with `SAVE_RAM` for progression / RTC for time — via `retro_get_memory_data(2)`+`retro_get_memory_size(2)`. The `rc_client_read_memory_func_t` callback (`rc_client.h:74-78`) gets `(address, buffer, num_bytes, client)` and must translate into that region: fetch the region pointer once per region-switch (cheap: `retro_get_memory_data` is O(1)), memcpy `min(num_bytes, size - address)`, return bytes copied. **Zero-copy not possible** (the region pointer is only valid on core thread / stable per region) — but a per-frame memcpy of only the touched addresses is cheap.
- **Note:** `retro_get_memory_data` returns a pointer that is stable for the session but the *contents* only change after `retro_run` commits. Read it only on the core thread, ideally right after `retro_run` returns and before `rc_client_do_frame`.

### 4.2 — Where to create / configure the `rc_client`
- **Create once per session at the earliest point** — in an RA service owned by `EmulatorSession`, created in `load()` BEFORE `retro_run` starts:
  ```
  rc_client_create(read_memory_cb, server_call_cb)   // rc_client.h:118
  rc_client_set_event_handler(...)                    // rc_client.h:594 → handle ACHIEVEMENT_TRIGGERED etc.
  rc_client_set_host(...)                             // rcheevos.ra / retroachievements.org
  rc_client_set_get_time_millisecs_function(...)
  rc_client_enable_logging(...) → route to Log
  ```
  **Threading:** `rc_client` is not thread-safe across arbitrary threads. Create it on the **caller thread** (main — where `startEmulator` runs), but **all `do_frame`/`idle`/`read_memory` calls on the core thread**. Login (`rc_client_begin_login_with_password/token`) is async and its callbacks come back on the thread that pumps the periodic work — align with core-thread pumping (see 4.3).

- **Login/data flow:** The `server_call` callback (`rc_client.h:85-88`) receives an `rc_api_request_t` and must perform the HTTP exchange. GameDock has **no HTTP layer today** — this is a net-new dependency (URLSession). Requests to retrofit:
  - `rc_client_begin_login_with_password/with_token` → POST to `/api/...login` (auth).
  - `rc_client_begin_load_game(hash, ...)` → fetch game data + achievement patch.
  - `rc_client_begin_identify_and_load_game` → `POST /api/api.php?r=patch` (identify+load).
  - On unlock: `rc_client_do_frame` will internally queue an unlock request → `server_call` must POST to `...?r=...` award. All server calls funnel through the **same** `server_call` callback, which the game's HTTP service must dispatch to `rc_api_*` handlers (the rapi/ folder already models the request/response structs).

### 4.3 — Where to call `rc_client_create` / `begin_load_game` / `do_frame` / `idle`
Exact insertion points in `Sources/GameDock/Launch/EmulatorSession.swift`:

1. **`load()`** — `EmulatorSession.swift:168-252`. After `loadedGame = true` and after `retro_run`'s symbols are all resolved (which they are by then via `RetroCore.load`), and AFTER `shim_install` (callbacks live). Correct ordering: create the client here, then:
   ```
   // hash phase (async — needs the server):
   rc_client_begin_identify_and_load_game(client, consoleIdFor(source), romPath, romData?.bytes, romData?.count, callback, nil)
   // callback (on whichever thread pumps) → rc_client_is_game_loaded() → proceed.
   ```
   The identify flow is **async over the network**, so the game may begin emulating before achievements are attached. Gate the first `rc_client_do_frame` until `rc_client_get_load_game_state == DONE` (or queue frames via `rc_client_idle`).

2. **`runLoop()`** — `EmulatorSession.swift:301-355` (the per-frame loop), **after** the `core?.retroRun?()` call at `EmulatorSession.swift:323`. Precisely: run `retro_run()` → hardware readback (if hw) → then if RA game is loaded and `rc_client_is_processing_required(client)` → `rc_client_do_frame(client)`. Must be **on the core thread** (this loop IS the core thread) so the `read_memory` callback can safely call `RetroCore.retroGetMemoryData` for that region. Add to the pacing block: do NOT let RA processing put the core behind; it's negligible (memrefs only on touched addresses).

3. **Pause/resume**: when emulation is paused (not currently implemented — v1 has no pause), call `rc_client_idle(client)` for periodic queue pumping instead of `do_frame`.

4. **`teardown()`** — `EmulatorSession.swift:375-410`. **Before** `retro_deinit`/`unload` (the core must still be loaded to release its memory regions cleanly), call `rc_client_unload_game(client)` then `rc_client_destroy(client)`. Destroy must happen on a thread that is not racing the (already stopped) core thread — same ordering caveat as 1.1. **Never destroy while the core thread is inside `retro_run`.**

5. **`retro_reset` hook**: if hardcore mode triggers `RC_CLIENT_EVENT_RESET` (`rc_client.h:617+`), the event handler should call `core?.retroReset?()` (already available as `RetroCore.retroReset`, `RetroCore.swift:169-172`).

6. **`handleVideo`/`frameSlot` (frame counter):** `rc_client_do_frame` internally advances the frame counter; no separate frame counter needed — call it once per `retro_run`.

### 4.4 — `read_memory` callback serving ROM (hashing) vs RAM
The ring: `rc_client_read_memory_func_t` is used for **both** hashing (during identify, over whole ROM address space) and runtime achievement checks (over the mapped RAM region).
- **During identify**: the runtime accesses the ROM image via `rc_api` hashing (`rc_hash_*`) — rcheevos hashes the file itself from `file_path`/`data` it already received; the `read_memory` callback during identify is generally for the *system memory* being prepared. Practically: give `read_memory` a single implementation that resolves addresses against `RETRO_MEMORY_SYSTEM_RAM` (id 2), falling back to `SAVE_RAM`/`RTC`/`VIDEO_RAM` for out-of-range addresses. That single callback is enough for both phases since rcheevos routes ROM hashing internally.
- **Runtime**: address 0 = start of `RETRO_MEMORY_SYSTEM_RAM`. Implement `read_memory` (Swift `@convention(c)` non-capturing, like the existing `gd_*` globals at `EmulatorSession.swift:12-47`, routing via `EmulatorSession.active`):
  ```
  func rc_read_memory(_ address: UInt32, _ buffer: UnsafeMutablePointer<UInt8>?,
                      _ numBytes: UInt32, _ client: OpaquePointer?) -> UInt32 {
      guard let session = EmulatorSession.active, let core = session.core,
            let base = core.retroGetMemoryData(UInt32(RETRO_MEMORY_SYSTEM_RAM.rawValue)),
            ... memcpy, return count
  }
  ```
  **Constraints:** (a) runs on core thread; (b) region pointer valid until next `retro_run`/`load_game` change — memcpy immediately, don't retain; (c) handle `address+numBytes > size` by returning a partial copy (rcheevos expects that); (d) `RETRO_MEMORY_RTC` for time-based achievements.

### 4.5 — Console-id mapping
`rc_client_begin_*`/`set_console_id` needs the RetroAchievements console id, **not** libretro's. Mapping (rcheevos `rc_consoles.h` constants): DS = 33 (Nintendo DS), PSP = 14/25 (PSP handheld). Console id should live in a small Swift enum mapping `GameSource.psp/.ds → RA console id`, with Steam excluded. Verify against `Sources/CRcheevos/include/rc_consoles.h` before wiring.

### 4.6 — Server-call HTTP callback duties (`server_call`)
`rc_client.h:83-91`. The callback is invoked (on the pumping thread — core thread) with an `rc_api_request_t` (see `rc_api_request.h`). Duties:
- **Login** (`rc_client_begin_login_with_password/token`): send `request->post_data` to `request->url` (the retrofit login endpoint), parse via `rc_api_logged_in_parse` (the rapi code is already compiled in), call `rc_client_server_callback_t` with the parsed `rc_api_server_response_t`.
- **Load / identify** (`begin_load_game`, `begin_identify_and_load_game`): same dispatch → `rc_api_patch_parse`, feed back.
- **Award/unlock**: when `do_frame` detects a trigger, it queues an unlock → `server_call` must POST the award request (`?r=awardachievement`), route the response through `rc_api_award_achievement_parse`.
- **All**: URLSession async on the concurrent queue, return via `rc_client_server_callback_t`. Because `server_call` originates on the core thread but HTTP must be off-thread, the callback that resumes `rc_client` may land on a URLSession thread — rcheevos expects the callback on **the same thread that will call `do_frame` next**. Safest: marshal the `server_callback_t` result back to the core thread (hop through `EmulatorSession`'s run queue or a lock-protected pending-callback list drained each frame). This thread-hopping is the #1 new complexity.

### 4.7 — Overlay / UI hooks (secondary)
Achievement **toast** + **progress** and the "You've unlocked X/Y" summary (`rc_client_get_user_game_summary`, `rc_client_get_achievement_info`, badge URLs via `rc_client_achievement_get_image_url`) feed a future `EmulatorScreen` overlay. Wire the `rc_client_set_event_handler` (`rc_client.h:586-604`) to post `RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED` to the main thread for a SwiftUI toast; do **not** touch SwiftUI from the core thread. `EmulatorScreen` (`Sources/GameDock/UI/EmulatorScreen.swift`) is the natural surface; `ArtworkLoader` can reuse its disk cache for badges.

### 4.8 — State serialization
`rc_client_serialize_progress_sized`/`deserialize` (`rc_client.h:921-934`) enables save/load of in-progress achievement state. Hook into a future save-state feature; today GameDock has no save-state, so note only.

---

## 5. AUDIT-DONE checklist areas that are CLEAN
- `VDFParser` escaping (scout §6.1 fix) correct; `//`/`/* */` skipping + windows `D:\` paths preserved. (`VDFParser.swift:96-116`)
- `PixelConverter` LUTs (`expand5`/`expand6`) precomputed, tight inner loops. Correct and fast for software cores.
- `RetroEnvironment` has the `bool` write-size discipline noted (1.6) — good.
- `CoreLocator` override→own-dir→RetroArch→fuzzy search order is correct and cheap.
- `SteamLibrary` StateFlags gating (`scan/parseManifest`) matches the scout report; last-played merge to max is correct.
- `ControllerManager` reuses the same `InputSnapshot`; port-0 only — fine for single-controller v1.
- mock core + selftest are a solid E2E harness; the input acceleration assertion is meaningful.

---

## AUDIT DONE
