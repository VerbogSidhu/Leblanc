# GameDock Code Audit — v2 (scout, read-only)

Scope: everything under `Sources/` (+ `Tests/MockCore/mockcore.c`, `Package.swift`, `Makefile`).
No files edited. ABI-critical `Sources/CLibretro` flagged but not touched.

> Ground truth: this read supersedes the earlier `docs/audit-v2.md` draft (which claimed
> RetroAchievements was entirely unreferenced). that is **no longer true** — a full RA
> integration already exists (`Sources/GameDock/RetroAchievements/*`) and compiles. It is,
> however, **half-wired** (see §1.1, the single most important finding).

Key numbers:
- Swift app ~6,740 lines across 45 files.
- `CRcheevos` vendored C ~29,000 lines (rcheevos), now **actually linked** and called from Swift.
- 5 fonts (~584 KB) are the only bundled resource; `JetBrainsMono-Regular.ttf` (270 KB) is a heavy accent with a single small-label consumer.
- Nothing under `Sources/GameDock/UI/HomeView.swift` / `GameCardView.swift` exists anymore (AGENTS.md's module map is stale — those files are gone, XMB replaced them). `SettingsView.swift` also does not exist (Settings is rendered via `SettingsNavModel` rows inside `XMBView`).

---

## 1. CORRECTNESS (bugs, races, leaks)

### 1.1 — 🔴 RA: game is created + logged in but **never loaded** — achievements are inert
`Sources/GameDock/Launch/EmulatorSession.swift:298-314` (`startRetroAchievements`) does
`service.create()`, `service.applySettings()`, `service.cacheRegions(from: core)`,
`service.beginLogin()`, and assigns `self.rcService`. But it **never calls**
`RCClientService.beginLoadGame(path:data:)` (`RCClientService.swift:172-184`) or the hash variant
(`:186-193`). Verified: `grep -rn "\.beginLoadGame" Sources/*` returns nothing except a self-test
(`RCClientService.beginLoadGame(hash:)` is only referenced there too — `CLIRASelfTest.swift` calls the
**C** `rc_client_begin_load_game` directly, not the Swift service).

Consequence: `rc_client_is_game_loaded(client)` stays false for the actual GUI emulator path.
`runLoop()` calls `rcService?.doFrame()` every frame (`EmulatorSession.swift:364`), but
`RCClientService.doFrame` (`:274-283`) checks `rc_client_is_processing_required(client)` which is 0
until a game is loaded → it always `rc_client_idle(client)`. So: **the client logs in, caches memory
regions, but never attaches to the game; zero achievements are ever evaluated, toasts never fire.**
This is a functional no-op, not a crash. The CLI `--ra-selftest` passes because it drives the C API
directly and calls `rc_client_begin_load_game` itself (`CLIRASelfTest.swift:112`).

Fix (planner): after `beginLogin()` resolves (async), and with the ROM bytes/path available, call
`service.beginLoadGame(path: entry.romPath, data: <ROM bytes>)`. `startRetroAchievements` currently has
no access to the ROM bytes — the caller must thread `romData`/`romPath` through (they ARE stored on the
session: `self.romPath`, `self.romData`). See §4.

### 1.2 — `requestStop()` proceeds to teardown after a **2 s join timeout** → dlclose of a live core
`Sources/GameDock/Launch/EmulatorSession.swift:397-413`. AGENTS.md's rule is "load/unload on a dedicated
session lock", but `teardown()` (`:416-453`) runs on the caller's thread (main, from
`AppEnvironment.exitEmulation`, `AppEnvironment.swift:333-336`). `requestStop` joins the core thread with
`.now()+2.0s`; on timeout it logs a warning and **returns normally**, so `teardown()` still calls
`retro_unload_game`/`retro_deinit`/`dlclose` while a possibly-stuck core thread is still inside
`retro_run`. That is a **use-after-unmap** on a hung core. Recommend: on timeout, either hard-`exit()`,
or skip `dlclose` (leak the handle) so the stuck thread's code stays mapped.

### 1.3 — `EmulatorSession.active` callback routing is process-global, and `shim g_cb` is un-synchronized
`EmulatorSession.active`/`setActive` guard `_active` with `NSLock` (`EmulatorSession.swift:96-113`), but
the C shim's `g_cb` global (`Sources/CLibretro/shim.c:13-19`, `shim_set_callbacks`) is written with
**no synchronization**, and the per-callback trampolines (`gd_video` etc., `EmulatorSession.swift:12-47`)
all route through `EmulatorSession.active?`. There is exactly one session at a time by construction, and
`AppEnvironment.startEmulator` (`:309-331`) doesn't guard against a second `startEmulator` while one is
active — two rapid PS-confirms could construct a second `EmulatorSession`, swap `g_cb` across threads,
and route frames to the wrong one. Low likelihood in the single-action UI, but the RA `RCClientService.active`
(`RCClientService.swift:96-107`) repeats the same pattern with its own lock, adding a second global. Note.

### 1.4 — RA transport teardown race: in-flight HTTP callbacks race `rc_client_destroy`
`RCClientService.destroy()` (`:284-296`) calls `rc_client_destroy(client)`. Meanwhile `serverCall`
(`:296-335`) dispatches `performHTTP` on a `DispatchQueue.global(.utility)`; when it completes it calls
`self?.enqueue(...)`, which appends to `pending` even after `destroy()` has cleared it and freed the
client. Worse, the queued `callbackData` came from `rc_client_server_call` and may reference the freed
`rc_client`. If teardown happens mid-flight (`exitEmulation` while a login/patch request is outstanding),
`drainPending` during a *subsequent* `doFrame` on a dead client → use-after-free / crash, or at best a
leaked unreachable `Pending`. Needs: cancel/ignore `pending` after destroy, and never deliver callbacks
after `rc_client_destroy`. This + §1.2 are the two teardown hazards the RA work must harden.

### 1.5 — `FrameSlot.pitch` (stored) is dead/misleading; renderer gets `width*4`
`Sources/GameDock/Launch/FrameSlot.swift:17,36,53` stores `self.pitch = pitch` (the **source** stride),
but `withLatest` (`:63-72`) returns `width * 4` as rowBytes — and `MetalRenderer` computes
`bytesPerRow` from `rowBytes` = `width*4` (`MetalRenderer.swift:118`). `PixelConverter.convert` always
writes tightly-packed `width*4`, so consumption is correct. The stored `pitch` field is never read by the
renderer and misrepresents the destination stride. Cosmetic-but-misleading: drop the field.

### 1.6 — `MetalRenderer.draw` performs the GPU `texture.replace` **under the FrameSlot lock**
`MetalRenderer.draw` (`:108-134`) calls `frameSlot.withLatest { ... texture.replace(...) }` inside the
slot lock, and `withLatest` holds `FrameSlot.lock`. `push` (core thread) also wants that lock. For a
hardware-render readback at 480×272×4 ≈ 0.5 MB or PSP-GL at larger sizes, the blocking CPU→GPU `replace`
stalls the core thread's next `push` **every frame** — a lock-convoy on the hot path. Safe today (the lock
makes it correct) but it couples core pacing to GPU upload. Recommend: copy the frame pointer under the
lock, release, `replace` outside — with a small slot ring so the pointer stays valid (see §3.4).

### 1.7 — `frameSlot` HW readback allocates a fresh readback buffer per size-change (fine) — but the **type of the pushed format for HW is hardcoded xrgb8888**
`EmulatorSession.readBackHardwareFrame` (`:435-459`) pushes with `format: .xrgb8888` which is correct
because `GLHardwareBridge.readPixels` reads `GL_BGRA` (bottom-up flipped) → the bytes are already
B,G,R,A. `PixelConverter.convertXRGB` then only forces alpha=0xFF (`PixelConverter.swift:87-102`) — no
reorder. Correct. The vertical flip in `readPixels` (`GLHardwareBridge.swift:224-236`) is an extra
per-frame memcpy pass; necessary given GL's bottom-left origin. OK, just noting the double copy.

### 1.8 — `RetroEnvironment` bool writes are correct BUT `GET_AUDIO_VIDEO_ENABLE` writes a 2-word array as `UInt32`
`RetroEnvironment.swift:151-157` writes `arr[0]`/`arr[1]` of `UInt32` for GET_AUDIO_VIDEO_ENABLE — the
libretro contract is `bool[2]` (two 1-byte bools) → writing `UInt32` to `arr[0]` fills 4 bytes, and
`arr[1]` writes 4 more at offset 4. If the core allocated `bool video, audio;` (2 bytes) this overruns by
2 bytes into adjacent stack. On Apple ABI `bool` is 1 byte, so this is a **real buffer overrun** unless
the core allocates `uint32_t` pairs. Canonical RetroArch writes 2 separate `bool`. Flag for a fix
(write `Bool` to a 1-byte-typed pointer, or a `[Bool]`). Same class as the (correct) `GET_CAN_DUPE`
discipline at `:60-65` — this one is inconsistent with the rest of the file and likely wrong.

### 1.9 — `AppDelegate.retryFullscreen` churns even after success
`AppDelegate.swift:40-67` schedules a continuation every 0.25 s up to 40 attempts, and `makeFrontendFullscreen`
is also invoked both from the `didBecomeKey` observer and the retry — the fullscreen toggle can be issued
twice (enter then immediately exit) on slow launches. The early-return `styleMask.contains(.fullScreen)`
only exists in `retryFullscreen`, not `makeFrontendFullscreen` (`:70-76`), so the observer path can
double-toggle. Cosmetic flake on slow launch, but worth a guard.

### 1.10 — `recents.save()` does synchronous disk write on the caller (main) thread
`RecentsStore.save` (`:80-91`): encode + `data.write(.atomic)` on the calling thread at emulator-launch
time (via `AppEnvironment.recordLaunch` on main). Small JSON, but `.atomic` is a temp-file + rename on
main → can hitch the launch transition. Low impact; move to a background queue.

### 1.11 — `XMBView.itemBar` `ForEach(lo...hi, id: \.self)` reads `cat.items[i]` with clamped index
`XMBView.swift:88-99`. `lo/hi` are derived from `itemIndex`; `XMBNavModel.rebuild` clamps `itemIndex`
before publishing, but a `@Published categories` + `itemIndex` update in the same transaction can
transiently expose `itemIndex > cat.items.count-1` → `cat.items[i]` out of range → SwiftUI crash.
Category switches happen frequently (PS quick bar / tab / L1/R1). Note as a latent index-sync hazard.

---

## 2. LIGHTNESS (dead code / weight to strip)

### 2.1 — `GlobalHIDMonitor` capture half is opt-in dead weight (~90 lines); only `describeDevices` is used
`Sources/GameDock/Controllers/GlobalHIDMonitor.swift`. `startCapture`/`stopCapture`/`onPSButton` are not
referenced by any production path (AGENTS marks it ⚠️ experimental). Only `describeDevices()` is called,
from `CLIDiagnoseInput` (`CLI.swift`). Keep (roadmap), but the capture slab could be `#if`-gated or
trimmed until hardware is verified. `isCapturing`/`manager` are set but never read off the capture path.

### 2.2 — `GLHardwareBridge` is wired but today dead in the GUI path
AGENTS.md §6: PPSSPP runs via the **standalone** app; the embedded libretro path is software-render
(melonDS/mock). `handleHWRenderRequest` (`EmulatorSession.swift:475-530`) only fires if a core requests
`SET_HW_RENDER` (env 14) — no v1 software core does. The `get_framebuffer`/`get_proc_address` globals
(`EmulatorSession.swift:53-91`) exist purely for that. **Do not delete** (it's the reference for
melonDS-GL and the RA-over-GL pipeline), but flag: nothing exercises it in v1. Consider `#if DEBUG` gating
the whole bridge to keep the shipped binary lean, and confirm no dylib core in `cores/` requests hw render.

### 2.3 — `controller.playerIndex` dead assignment
`ControllerManager.swift` — `playerIndex` isn't referenced anywhere; it's cosmetic (LED slot). Keep or
strip; cheap.

### 2.4 — `EmulatorMetalView.drawableSizeWillChange` is a required no-op; `frameSlot` set twice per pass
`EmulatorMetalView.swift:48-51` empty delegate method (renderer reads `view.drawableSize` live).
`frameSlot.didSet` + `EmulatorView.updateNSView` (`EmulatorView.swift:17`) both assign the slot on every
render pass — harmless duplicate. Collapse if desired.

### 2.5 — `Theme` unused tokens
`Theme.swift` defines `Theme.ember` (used), but earlier-draft tokens `itemTitleUnselected`, `railHeight`,
`screenPadding`, `fade` — grep shows **no references** in the current tree. Trim those 4.
`ArtworkPlaceholder` and `RemoteImage` are both used (XMB covers / RA badges).

### 2.6 — `GameDockFonts.data` / `JetBrainsMono-Regular` (270 KB) is a heavy small-label accent
`Theme.meta` (last-played subtitle, settings rows) is the only consumer of the Mono face. `ChakraPetch`×4
(~314 KB) carries the UI. If binary weight matters, drop `JetBrainsMono-Regular.ttf` and render `Theme.meta`
with `ChakraPetch-Regular` or system mono → −270 KB from the bundle (≈46% of the resource weight).

### 2.7 — `CRcheevos` is large but now genuinely needed — size where it goes
~29k lines of vendored rcheevos C is the dominant build/binary weight. It is **used** (RA). Fine to keep,
but ensure the RHash AES/CD-reader/hash_zip modules aren't pulling unused code into the binary — if only
`rc_hash` for ROM hashing + `rc_client` + rapi are needed, verify link-time dead-stripping (release build)
removes the disc/zip paths. Not a code change; a release `-dead_strip` check under `swift build -c release`.

### 2.8 — `CLIProbeCore` opens AppKit (`NSBitmapImageRep`) for a headless tool
`CLI.swift:189-263`. The whole target is a GUI app so AppKit is already linked — not removable; the
`--probe-core` path is a legit diagnostic. Keep.

### 2.9 — duplicate comment + `Ripple.id = UUID()` per nav tick
`XMBNavModel.swift:97-98` duplicated comment (cosmetic). `WaveFieldModel.emit` (`WaveField.swift:16-18`)
allocates a UUID + Color per nav selection — trivial per event, fine.

---

## 3. PERFORMANCE

### 3.1 — Wave field redraw is the dominant XMB per-frame CPU cost
`WaveField.swift:32-77`. `TimelineView(.animation)` fires 60–120×/s; `drawWaves` builds 5 sine `Path`s,
each `for x in stride(0…width, by:5)`, i.e. width/5 points × 5 layers (≈ width points total, ~2560 on a
2560px-wide screen), **plus** the below-waves fill subpaths, then `fill` + `stroke` each. Rerun every frame
even when the only change is the phase `+ layer.3 * t`. Optimizations:
1. **Pre-bake the static geometry** — baseY/amplitude/wavelength are constant; animate only the phase as a
   texture scroll, or render 3 layers instead of 5.
2. **Idle-throttle**: skip redraw when `t` delta is ~0 (paused/foregrounded) or drop to every 2nd frame.
3. Double the stride (by:10) — sub-pixel at 0.05 opacity; cannot see the difference.
This matches AGENTS' "wave-field draw cost" hotspot. Biggest single win available.

### 3.2 — Artwork cache: unbounded memory + repeated decode on the XMB stack
`ArtworkLoader.swift`:
- `cache:[String:NSImage]` is **unbounded** (no eviction in `store`, `:181-190`). A 300-game library × 2
  (banner+cover) × ~1 MB decoded = ~600 MB of NSImage retained. **Add an LRU cap** (~200 entries / ~256 MB)
  like the intended `maxCacheEntries` comment implies but does not enforce.
- `ArtworkView.onAppear(load)` + `.onReceive(loader.$loadedKeys)` (`ArtworkView.swift:30,39`) calls `load()`
  on every `loadedKeys` change while the view lives. Each `load()` → `ArtworkLoader.cover(...)` falls back
  `.banner` (`:34-35`), doing two `NSImage(contentsOfFile:)` decodes + a `copyItem` when no cover exists.
  `failed:Set` guards re-*encode* but the decode re-runs every cold call. Consider a per-key memo so a
  missing cover is decoded once.

### 3.3 — `LibraryStore` full rescan every refresh; Steam reparser dominates
`LibraryStore.swift:57-78`: `refresh()` runs on `scanQueue` (good) but:
- calls `steam.gameEntries()` (`SteamLibrary.swift:260-273`) → `scan()` re-reads **every
  `appmanifest_*.acf`** from disk each refresh (launch + every settings change + rescan). No `mtime`/cache.
- `roms.scan` recursively walks every ROM folder each refresh.
- `scanSynchronously` then does `recents.lastPlayedDate(for:)` per entry (`RecentsStore`, ≤20 recents — fine).
For a large Steam library this is hundreds of synchronous `String(contentsOf:)` reads on the scan queue at
launch. Recommend an incremental/mtime-gated rescan (only re-stat changed manifests) and caching the parsed
Steam list between refreshes. Also `AppEnvironment.settingsAction(.folder)` calls `library.refresh()` directly
*and* `rebuildXMB()` re-derives — two rescans for one folder removal (see also §3.6).

### 3.4 — Per-frame emulator pipeline
- `FrameSlot` + `MetalRenderer` lock contention during `texture.replace` (§1.6) is the **real** per-frame
  bottleneck once a live core runs. The CPU-side `PixelConverter` per-frame conversion is cheap for
  software DS (320×240) — fine.
- HW readback does a `memcpy` + block-copy + vertical flip per frame (`GLHardwareBridge.readPixels`,
  `EmulatorSession.swift:429,435-449`) — inherent to readback; if perf ever matters switch to IOSurface
  (RetroArch's approach). Note-only for now.
- `RetroAudioRingBuffer.read/write` are single-linked-circle with one lock each — mock/core path is fine;
  a PSP core pushing 735 frames × 2 samples per `retro_run` is trivial. No action.

### 3.5 — `AppEnvironment.metaLine` builds a `DateFormatter` per item per rebuild
`AppEnvironment.swift:150-157`: `Self.lastPlayedFormatter` is static/cached (good), but `relativeTime`
(`:171-181`) creates a **new `DateFormatter` per RA subtitle** string each `rebuildXMB`. Cache a static
formatter for the RA `yyyy-MM-dd HH:mm:ss` format. Minor, but `rebuildXMB` runs on every nav + scan.

---

## 4. RETROACHIEVEMENTS HOOKS

Read `Sources/CRcheevos/include/rc_client.h` (934 lines) — this is the contract. The integration is mostly
**already built** (`RCClientService`, `RAHash`, `RAClient` [Web API], `RAHubModel`, `RAToastModel`) but the
*in-emulator* half is unwired (see §1.1). Below maps the exact hook points against the current code.

### 4.1 — Which libretro memory regions `retro_get_memory_data` exposes
Canonical ids (from `Sources/CLibretro/include/libretro.h:183-187`, typed in `RetroCore.swift:109-110`):
- `RETRO_MEMORY_SAVE_RAM = 0` — battery-backed save RAM; persistent progression.
- `RETRO_MEMORY_RTC      = 1` — real-time clock (time-gated achievements).
- `RETRO_MEMORY_SYSTEM_RAM= 2` — live system RAM; **the** achievement-integrity region for DS/PSP cores.
- `RETRO_MEMORY_VIDEO_RAM = 3` — VRAM (rarely integrity-checked).
Swift resolvers already exist: `RetroCore.retroGetMemoryData/size` (`RetroCore.swift:109-110`) return
`UnsafeMutableRawPointer?` / `Int`. `cacheRegions` (`RCClientService.swift:211-220`) already snapshots all
four (id 0…3) once per session after `retro_load_game`, keyed by id.

**Crucially, rcheevos gives us the native-address layout** via `rc_console_memory_regions(console_id)`
(`rc_consoles.h:135`; struct `rc_memory_region_t` with `start_address/end_address/real_address/type`).
`RCClientService.loadConsoleMemoryMap` (`:222-245`) already maps `RC_MEMORY_TYPE_SYSTEM_RAM→2`,
`SAVE_RAM→0`, `VIDEO_RAM→3` and builds `consoleRegions`. And `readMemory` (`:247-272`) translates a native
console address → the right libretro region + offset and memcpys. **This plumbing is complete and correct.**
The only thing missing is calling `beginLoadGame`.

### 4.2 — `rc_client_create` / login — already done, correct threading
`RCClientService.create()` (`:132-156`) calls `rc_client_create(ra_read_memory, ra_server_call)` and
`ra_read_memory` routes via `RCClientService.active` (`:30-36`). `beginLogin()` (`:158-166`) uses
`rc_client_begin_login_with_token`. This is correct. The `read_memory` callback set at create-time is the
one rcheevos uses for both identify and runtime (see `rc_client.c:1355` calling
`client->callbacks.read_memory`). `rc_client_set_allow_background_memory_reads(c, 0)` (`:148`) restricts reads
to inside `do_frame` — intended, and matches our core-thread-only rule.

### 4.3 — where to call `begin_load_game` (the gap) 
`Sources/GameDock/Launch/EmulatorSession.swift`:
- `startRetroAchievements()` ends at `:314` with the service created, regions cached, login begun — but
  **no load-game kickoff**. This is where (or immediately after login resolves) the session must call
  `rcService.beginLoadGame(path: romPath, data: <romData-or-read-file>)`.
- `RCClientService.beginLoadGame(path:data:)` (`:172-184`) already:
  - `RAHash.generate(consoleID:path:data:)` (`RAHash.swift:17-38`) → local `rc_hash_generate` (Path A),
  - then `rc_client_begin_load_game(client, hash, ...)`.
  So the missing piece is strictly a **call site** in `EmulatorSession`. Because the client isn't ready
  (not logged in / no game) on the very first frame, gate on `rc_client_get_load_game_state`:
  - `:-` `EmulatorSession.runLoop()` (`:338-392`) already calls `rcService?.doFrame()` right after
    `retroRun()` (`:364`). Keep that; to feed it the game must be loaded first.
  - When `beginLoadGame`'s async callback lands, set a `gameLoaded` flag; `doFrame()` only evaluates when
    `rc_client_is_game_loaded`.
- **ROM bytes availability**: `RAHash.generate` needs the full ROM (`data`). For `need_fullpath==false`
  cores `EmulatorSession.romData` holds it; for fullpath cores the session reads the file in `load()`
  (`:239-245`) but doesn't retain the `Data` — the RA caller must re-read `romPath`. Note this.

### 4.4 — `do_frame` / `idle` — already in the loop; correct thread
`RCClientService.doFrame` (`:274-283`): if `rc_client_is_processing_required` → `rc_client_do_frame`, else
`rc_client_idle`, both bracketed by `drainPending()`. Called from `EmulatorSession.runLoop` on the **core
thread** (`EmulatorSession.swift:364`) — the only thread allowed to touch `retro_get_memory_data`. Correct.
The pending-callback hop (`Pending` + `drainPending`, `:340-371`) already marshals URLSession responses back
to the core thread — the #1 complexity the older audit worried about is already solved. Only gap remains §4.3.

### 4.5 — `read_memory` callback serving **ROM hash** vs **RAM**
- During **identify**: hashing uses the ROM bytes passed to `rc_client_begin_load_game` (via `RAHash`),
  not the `read_memory` callback. So ROM hashing is already handled by `beginLoadGame(path:data:)`.
- During **runtime**: `readMemory` (`:247-272`) serves RAM reads from `consoleRegions` + cached `regions`
  (`[UInt32: Region]` of pointer+size). Region pointers are snapshotted in `cacheRegions` at load-time and
  are **stable** for the session; contents change per `retro_run`. That's fine — `doFrame` runs after
  `retro_run`.
- **Caveat**: `readMemory` returns early with a partial copy when a region offset falls outside
  (`offset < regionSize` guard, `:263-268`) and returns `0` (invalid) when no region matches — exactly the
  return-contract rcheevos expects (`0` = invalid address, see `rc_client.h:22-25`). Good.

### 4.6 — `server_call` HTTP callback (login/award/fetch)
`RCClientService.serverCall` (`:296-335`) snapshots `rc_api_request_t.url`, `post_data`, `content_type`,
issues `URLSession` on a `.utility` queue via `performHTTP` (`:337-360`), and `enqueue`s the response for
core-thread delivery. This single callback handles **all** RA server traffic from the C library:
- **Login**: from `beginLogin()` → POST to login endpoint (already observed in `--ra-selftest`).
- **Load/patch**: from `begin_load_game` → fetch game data + achievement patch.
- **Award/unlock**: `rc_client_do_frame` internally queues award POSTs → same `server_call`.
- `https://retroachievements.org/api/...` host is the `base` in `RAClient` (`RAClient.swift`). The C-side
  `rc_api_request_t.url` is already absolute (`https://retroachievements.org/api/...`), so `performHTTP`
  POSTs directly to it — correct, no host remap needed.
User-Agent is set (`:355`). Timeout 30 s. Good. **Only gap**: the whole `server_call` pipeline is
unreachable until `beginLoadGame` is invoked (§4.3) — it's wired but idle.

### 4.7 — Event → UI toast (already wired)
`ra_event` → `RCClientService.handleEvent` (`:364-409`) dispatches ACHIEVEMENT_TRIGGERED(1),
GAME_COMPLETED(15), RESET(14), SERVER_ERROR(16) as `RAToast`s onto `DispatchQueue.main`. `EmulatorScreen`
(`EmulatorScreen.swift:29,55-75`) observes `session.raToasts`. Complete and correct; just unreachable due
to §4.3.

### 4.8 — Console-id mapping (correct)
`RAConsole.id` (`RAConsole.swift:13-18`): DS→18, PSP→41 (matches `rc_consoles.h:33,56`). Passed from
`AppEnvironment.startEmulator` (`:313-317`) as `raConsoleID`. Correct. `RCClientService.loadConsoleMemoryMap`
uses it via `rc_console_memory_regions(consoleID)`.

### 4.9 — Teardown ordering for RA (must-harden, see §1.4)
`EmulatorSession.teardown` (`:416-453`) already runs `rcService.unloadGame()` + `rcService.destroy()` first,
before `retro_unload_game`/`deinit` — correct ordering (unload RA before the core frees its memory). The
danger is the §1.4 in-flight HTTP race and the §1.2 2 s timeout. Planners should treat RA teardown as
non-negotiable-before-core-unload.

---

## 5. AREAS VERIFIED CLEAN
- `VDFParser` escaping (Windows `D:\` paths preserved, `//`/`/* */` comments, BOM) — correct
  (`VDFParser.swift:96-116`).
- `PixelConverter` LUT-precomputed tight loops (`PixelConverter.swift:9-11,45-102`) — correct for DS software.
- `SteamLibrary` StateFlags gating + last-played merge-to-max (`SteamLibrary.swift:180-208`) — matches spec.
- `CoreLocator` search order override→own→RetroArch→fuzzy (`CoreLocator.swift`) — correct & cheap.
- `InputSnapshot` port-0-only, lock-protected read/write (`GamepadInput.swift`) — correct for v1.
- mock core + `--selftest` E2E harness is sound; input-acceleration assertion is meaningful.
- `SettingsStore` Keychain migration for the RA API token (`SettingsStore.swift:57-75`) — correct; token never
  lands in UserDefaults/plist/logs.

---

## AUDIT DONE
