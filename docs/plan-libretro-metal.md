# GameDock — Embedded Libretro Core + Metal Render Path (Implementation Plan)

**Role:** PLANNING ENGINEER (read-only). This document specifies, file-by-file,
the hardest subsystem in GameDock: the Swift libretro frontend that `dlopen`s a
core dylib, feeds it a ROM, and renders its software framebuffer through Metal,
with gamepad input and audio. It is written to be executed verbatim by a
separate worker.

**Grounding.** Everything below is cross-checked against the actual current
sources:

- `Sources/CLibretro/include/libretro.h` — trimmed ABI-correct API (do not touch).
- `Sources/CLibretro/include/shim.h` + `Sources/CLibretro/shim.c` — callback
  trampoline registry. `shim_set_callbacks()` stores a `shim_callbacks_t`; the
  C trampolines (`shim_video`, `shim_audio`, `shim_audio_batch`,
  `shim_input_poll`, `shim_input_state`, `shim_environment`, `shim_log_printf`)
  call back into Swift via `g_cb.*(g_cb.ctx, …)`. `shim_install()` resolves the
  core's `retro_set_*` symbols via `dlsym(RTLD_DEFAULT, …)` and installs the
  trampolines.
- `Sources/GameDock/Core/PixelConverter.swift` — already converts 0RGB1555 /
  XRGB8888 / RGB565 → BGRA8 (bgra8Unorm byte order).
- `Sources/GameDock/Controllers/GamepadInput.swift` — `InputSnapshot` is already
  a lock-protected button/analog store with `readButton(port:id:)` and
  `readAnalog(port:stick:axis:)`.
- `Sources/GameDock/CLI/CLI.swift` — `CLISelfTest.run()` is a stub.
- `Sources/GameDock/main.swift` — dispatches `--selftest` → `CLISelfTest.run()`.
- `Makefile` — already has `mock-core` (builds `build/mockcore.dylib` from
  `Tests/MockCore/mockcore.c`, which does **not** exist yet) and
  `selftest: … GAMEDOCK_CORE_PATH=$(MOCK_CORE) swift run GameDock --selftest`.

> **Important**: the AGENTS.md module map lists the `Launch/` files as "✅
> implemented", but they do **not** exist yet in `Sources/GameDock/Launch/`
> (the directory is empty). They are the deliverable of this plan.

---

## 0. Non-goals / hard boundaries

- **Never** edit `Sources/CLibretro/` (ABI-critical). The shim is exactly what we
  need; no changes are required and none should be made.
- **Never** edit `Package.swift` (the `CLibretro` target already exposes
  `shim_set_callbacks` / `shim_install` / `shim_log_printf`; no new deps).
- **HW render is out of scope.** `RETRO_ENVIRONMENT_SET_HW_RENDER` **must** return
  `false`. Software-render cores only (melonDS, 2D cores, mock core).
- **Do NOT wire `AppEnvironment`** into the session yet — that integration is a
  later milestone. This plan delivers `EmulatorSession`, `RetroCore`,
  `EmulatorMetalView`, and the headless `--selftest` harness only.
- **One active session at a time** (matches the shim's single global registry).

---

## 1. `Sources/GameDock/Launch/RetroCore.swift` — dynamic loader

### 1.1 Purpose

Wrap `dlopen`/`dlsym` behind a safe Swift API, giving us typed function pointers
into the core.

### 1.2 Key design points

- `dlopen(path, RTLD_NOW | RTLD_GLOBAL)`. `RTLD_GLOBAL` is **required** so
  `shim_install()`'s `dlsym(RTLD_DEFAULT, "retro_set_environment")` can find the
  core's symbols (see `shim.c`). `RTLD_NOW` so missing symbols fail at load, not
  first call.
- Cast each resolved symbol with `unsafeBitCast(to:)`. **Safety rule:** only
  `unsafeBitCast` a symbol pointer to a `@convention(c)` function type that is
  ABI-identical to what the core exports. Every cast below matches the typedefs
  in `libretro.h` exactly, so the bit-cast is value-preserving (pointer → pointer).
- Mandatory symbols (fatal if missing): `retro_set_environment`,
  `retro_set_video_refresh`, `retro_set_audio_sample_batch`,
  `retro_set_input_poll`, `retro_set_input_state`, `retro_init`,
  `retro_deinit`, `retro_api_version`, `retro_get_system_info`,
  `retro_get_system_av_info`, `retro_set_controller_port_device`,
  `retro_run`, `retro_load_game`, `retro_unload_game`.
- Optional (guard with `!symbol.isEmpty` before use): `retro_set_audio_sample`
  (legacy single-sample path — most cores use batch only),
  `retro_load_game_special`, `retro_reset`, `retro_get_region`,
  `retro_get_memory_data`, `retro_get_memory_size`.

### 1.3 Swift typealiases (concrete)

```swift
import Foundation
import Darwin

typealias RetroEnvironmentFn      = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
typealias RetroVideoRefreshFn     = @convention(c) (UnsafeRawPointer?, UInt32, UInt32, Int) -> Void
typealias RetroAudioSampleFn      = @convention(c) (Int16, Int16) -> Void
typealias RetroAudioSampleBatchFn = @convention(c) (UnsafePointer<Int16>?, Int) -> Int
typealias RetroInputPollFn        = @convention(c) () -> Void
typealias RetroInputStateFn       = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> Int16

typealias RetroSetEnvironmentFn   = @convention(c) (@escaping RetroEnvironmentFn) -> Void
typealias RetroSetVideoRefreshFn  = @convention(c) (@escaping RetroVideoRefreshFn) -> Void
typealias RetroSetAudioSampleFn   = @convention(c) (@escaping RetroAudioSampleFn) -> Void
typealias RetroSetAudioBatchFn    = @convention(c) (@escaping RetroAudioSampleBatchFn) -> Void
typealias RetroSetInputPollFn     = @convention(c) (@escaping RetroInputPollFn) -> Void
typealias RetroSetInputStateFn    = @convention(c) (@escaping RetroInputStateFn) -> Void

typealias RetroInitFn             = @convention(c) () -> Void
typealias RetroDeinitFn           = @convention(c) () -> Void
typealias RetroApiVersionFn       = @convention(c) () -> UInt32
typealias RetroGetSystemInfoFn    = @convention(c) (UnsafeMutablePointer<RetroSystemInfo>) -> Void
typealias RetroGetSystemAVInfoFn  = @convention(c) (UnsafeMutablePointer<RetroSystemAVInfo>) -> Void
typealias RetroSetControllerPortDeviceFn = @convention(c) (UInt32, UInt32) -> Void
typealias RetroResetFn            = @convention(c) () -> Void
typealias RetroRunFn              = @convention(c) () -> Void
typealias RetroLoadGameFn         = @convention(c) (UnsafePointer<RetroGameInfo>?) -> Bool
typealias RetroLoadGameSpecialFn  = @convention(c) (UInt32, UnsafePointer<RetroGameInfo>?, Int) -> Bool
typealias RetroUnloadGameFn       = @convention(c) () -> Void
typealias RetroGetRegionFn        = @convention(c) () -> UInt32
typealias RetroGetMemoryDataFn    = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
typealias RetroGetMemorySizeFn    = @convention(c) (UInt32) -> Int
```

### 1.4 C-struct mirror types (ABI-correct — mirror `libretro.h` exactly)

```swift
// C enums as raw UInt32 (avoid importing bool sizes mismatches).
enum RetroLogLevel: Int32 { case debug = 0, info, warn, error }

// Must match libretro.h field order byte-for-byte.
struct RetroGameInfo {      // struct retro_game_info
    var path: UnsafePointer<CChar>?
    var data: UnsafeRawPointer?
    var size: Int
    var meta: UnsafePointer<CChar>?
}
struct RetroSystemInfo {    // struct retro_system_info
    var library_name: UnsafePointer<CChar>?
    var library_version: UnsafePointer<CChar>?
    var valid_extensions: UnsafePointer<CChar>?
    var need_fullpath: Bool    // C bool = 1 byte
    var block_extract: Bool
}
struct RetroGameGeometry {  // struct retro_game_geometry
    var base_width: UInt32
    var base_height: UInt32
    var max_width: UInt32
    var max_height: UInt32
    var aspect_ratio: Float
}
struct RetroSystemTiming {  // struct retro_system_timing
    var fps: Double
    var sample_rate: Double
}
struct RetroSystemAVInfo {  // struct retro_system_av_info
    var geometry: RetroGameGeometry
    var timing: RetroSystemTiming
}
```

> Pitfall: Swift `Bool` is 1 byte and matches C `bool` here, but **do not** add
> fields or reorder. `retro_game_info.size` is `size_t` → Swift `Int` (64-bit),
> matching the C `size_t` on arm64.

### 1.5 Public surface

```swift
final class RetroCore {
    let path: String
    private(set) var handle: UnsafeMutableRawPointer?

    // Function pointers (nil until load())
    // ... one stored property per typealias above ...

    var isLoaded: Bool { handle != nil }

    init(path: String)
    /// dlopen + resolve all mandatory symbols. Throws RetroCoreError on failure.
    func load() throws
    /// Resolve a single symbol as a generic function pointer; returns nil if absent.
    func symbol<T>(_ name: String, as: T.Type) -> T?
    /// dlclose. Call only after deinit + unload on the session thread.
    func unload()

    // Convenience typed getters used by the session (cached in load()).
    var setEnvironment: RetroSetEnvironmentFn { ... }
    // ... etc ...
}

enum RetroCoreError: Error {
    case dlopenFailed(String)          // dlerror string
    case missingSymbol(String)
    case apiVersionMismatch(UInt32)    // expected RETRO_API_VERSION == 1
}
```

- `load()` validates `retro_api_version() == 1` (RETRO_API_VERSION) and throws
  `apiVersionMismatch` otherwise.
- `load()` caches all mandatory pointers as stored properties; `symbol(_:as:)`
  is the generic helper (`dlsym` → `unsafeBitCast`).

---

## 2. `Sources/GameDock/Launch/EmulatorSession.swift` — orchestrator + callbacks

This is the centerpiece. It owns the `RetroCore`, registers the `@convention(c)`
callbacks with the shim, drives the run loop on its own thread, and exposes the
latest-frame slot + audio ring buffer + input snapshot to the renderer/audio
consumers.

### 2.1 Singleton routing

Because the shim callbacks are **non-capturing** globals, they reach the active
session through a process-wide static:

```swift
final class EmulatorSession {
    /// The single session currently driving a core. Set on load, cleared on unload.
    static var active: EmulatorSession?  // guarded by an internal NSLock
    private static let activeLock = NSLock()
}
```

Every `@convention(c)` callback below does:

```swift
let session = EmulatorSession.snapshotActive()   // locked read of optional
guard let session else { return /* neutral values */ }
```

### 2.2 Callback globals (top-level, non-capturing)

```swift
// NOTE: these must be top-level (file-scope) functions, never closures.

private func gd_video(_ ctx: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer?,
                      _ width: UInt32, _ height: UInt32, _ pitch: Int) {
    EmulatorSession.active?.handleVideo(data, width: Int(width), height: Int(height), pitch: pitch)
}

private func gd_audio(_ ctx: UnsafeMutableRawPointer?, _ left: Int16, _ right: Int16) {
    EmulatorSession.active?.handleAudioSample(left, right)
}

private func gd_audio_batch(_ ctx: UnsafeMutableRawPointer?, _ data: UnsafePointer<Int16>?,
                            _ frames: Int) -> Int {
    EmulatorSession.active?.handleAudioBatch(data, frames: frames) ?? frames
}

private func gd_input_poll(_ ctx: UnsafeMutableRawPointer?) {
    EmulatorSession.active?.inputSnapshot.notifyPoll()   // no-op / hook
}

private func gd_input_state(_ ctx: UnsafeMutableRawPointer?, _ port: UInt32,
                            _ device: UInt32, _ index: UInt32, _ id: UInt32) -> Int16 {
    EmulatorSession.active?.handleInputState(port: port, device: device, index: index, id: id) ?? 0
}

private func gd_environment(_ ctx: UnsafeMutableRawPointer?, _ cmd: UInt32,
                            _ data: UnsafeMutableRawPointer?) -> Bool {
    EmulatorSession.active?.environment.handle(cmd: cmd, data: data) ?? false
}

private func gd_log(_ ctx: UnsafeMutableRawPointer?, _ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let text = String(cString: message)
    // map level → Log.debug/info/warn/error
}
```

`ctx` is ignored (single-session model); we pass `nil` as context to keep types
clean, or pass `Unmanaged.passUnretained(self).toOpaque()` — **recommend
`nil`** and route through `EmulatorSession.active`.

### 2.3 Session lifecycle (load/unload sequencing)

```swift
final class EmulatorSession {
    enum State { case idle, loaded, running, stopping, stopped }

    let corePath: String
    let romPath: String?            // nil for cores that support no-game
    let romData: Data?              // optional in-memory ROM (none for need_fullpath)
    private(set) var core: RetroCore?
    private(set) var state = State.idle
    private(set) var systemInfo: RetroSystemInfo?
    private(set) var avInfo: RetroSystemAVInfo?
    let frameSlot: FrameSlot          // see §4
    let audioRing: RetroAudioRingBuffer // see §6
    let inputSnapshot: InputSnapshot  // reuses Controllers/GamepadInput.swift

    private var runThread: Thread?
    private let stopRequested = ...     // atomic/flag + semaphore
    private let threadDone = DispatchSemaphore(value: 0)
}
```

**Load sequence (order matters — see shim.c comment):**

1. `ensure appSupport/cores + saves dirs` (via `AppPaths`).
2. `core = RetroCore(path: corePath); try core.load()`.
3. Build a `shim_callbacks_t` referencing the `gd_*` globals, `ctx = nil`:
   ```swift
   var cb = shim_callbacks_t(ctx: nil,
                             video: gd_video, audio: gd_audio,
                             audio_batch: gd_audio_batch,
                             input_poll: gd_input_poll, input_state: gd_input_state,
                             environment: gd_environment, log: gd_log)
   shim_set_callbacks(cb)
   ```
   > The C `shim_callbacks_t` struct is auto-imported into Swift. Pass the
   > globals directly (they are `@convention(c)` function values).
4. `shim_install()` — resolves the core's `retro_set_*` and hands it our
   trampolines. **Must** come after (3) and before (5).
5. `core.retro_init()`.
6. `core.retro_get_system_info(&info)` — read `library_name`,
   `library_version`, `need_fullpath` (copy strings immediately, they may be
   static, but copy to be safe).
7. `core.retro_get_system_av_info(&avInfo)` — capture geometry `base/max`
   (whichever non-zero) and `timing.fps` / `timing.sample_rate`.
8. **Pixel format:** `RETRO_ENVIRONMENT_SET_PIXEL_FORMAT` is requested by the
   core via the environment callback, but we also read the *actual* selected
   format in the env handler and store it on the session. If the core never
   sets one, default to `xrgb8888`. (See §3 for env details.)
9. **Load game:**
   - If `systemInfo.need_fullpath == true`: build `RetroGameInfo(path: cStr, data: nil, size: 0, meta: nil)` and call `retro_load_game(&gi)`. For mock core and melonDS, pass the ROM path as a C string (copy via `withCString`).
   - Else if ROM data provided: pin `romData` with `withUnsafeBytes` → `RetroGameInfo(path: nil, data: base, size: count, meta: nil)`.
   - Else (no-game core): call `retro_load_game(nil)` **only if** the core's
     `RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME` returned true earlier.
   - On `false`, throw `.loadGameFailed`.
10. `retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD)`.
11. Set `state = .loaded`; set `EmulatorSession.active = self`.

**`start()` / stop semantics (§5):**

- `start()` spawns the core thread. The thread body is the run loop.
- `requestStop()` sets the stop flag. The run loop checks the flag each
  iteration and exits. Caller then `threadDone.wait()` to join.
- `teardown()` (runs after join, on caller thread): `retro_unload_game()` →
  `retro_deinit()` → `core.unload()` (dlclose). Clear `active = nil`.

---

## 3. `Sources/GameDock/Launch/RetroEnvironment.swift` — environment handler

### 3.1 Responsibilities

Implement the full `retro_environment_t` command table as a **value type** owned
by the session, so the single `gd_environment` global can dispatch.

```swift
struct RetroEnvironment {
    // state accumulated here
    var pixelFormat: RetroPixelFormat = .xrgb8888
    var systemDirectory: String?
    var saveDirectory: String?
    var canDupe = false
    var supportNoGame = false
    var audioVideoEnable: (video: Bool, audio: Bool) = (true, true)
    var fastForwarding = false

    /// Returns true when the command was handled; false = "not implemented / decline".
    mutating func handle(cmd: UInt32, data: UnsafeMutableRawPointer?) -> Bool
}
```

### 3.2 Command table

**MUST implement (return `true`) — these keep cores alive, and many request data:**

| cmd | handle | data layout (canonical) |
|---|---|---|
| `SET_PIXEL_FORMAT` (10) | `true`; store format | `data = UInt32*` (one of 0/1/2) |
| `GET_CAN_DUPE` (3) | `true`; write `true` | `data = UInt32*` (write `1`/`0`) |
| `GET_LOG_INTERFACE` (27) | `true`; fill | `data = retro_log_callback*` { `log: retro_log_printf_t` } → set `.log = shim_log_printf` |
| `GET_SYSTEM_DIRECTORY` (9) | `true`; write path | `data = const char**` → point to a stable C string |
| `GET_SAVE_DIRECTORY` (31) | `true`; write path | `data = const char**` |
| `GET_LIBRETRO_PATH` (19) | `true`; write path | `data = const char**` (use `corePath`) |
| `GET_INPUT_BITMASKS` (52) | `true`; write `0` | `data = bool*` (write `0` = full-button analog not needed) |
| `GET_AUDIO_VIDEO_ENABLE` (48) | `true`; fill | `data = UInt32[2]` {videoEnabled, audioEnabled} → `{1,1}` |
| `GET_INPUT_MAX_USERS` (62) | `true`; write 1 | `data = UInt32*` |
| `GET_MESSAGE_INTERFACE_VERSION` (60) | `true`; write 1 | `data = UInt32*` |
| `GET_FASTFORWARDING` (50) | `true`; write `false` | `data = bool*` |
| `GET_TARGET_REFRESH_RATE` (51) | `true`; write fps | `data = float*` (write avInfo.timing.fps) |
| `GET_SAVESTATE_CONTEXT` (73) | `true`; write 0 | `data = UInt32*` (no savestate context) |
| `GET_JIT_CAPABLE` (75) | `true`; write `true` | `data = bool*` (Apple Silicon allows JIT) |
| `SET_SUPPORT_NO_GAME` (18) | `true`; record | `data = bool*` |
| `SET_PIXEL_FORMAT` handled above | | |
| `SHUTDOWN` (7) | `true`; set session stop flag | (no data) |
| `SET_MESSAGE` (6) | `true`; log it | `data = retro_message*` { msg, frames } — copy `msg` C string |
| `SET_VARIABLES`/`SET_CORE_OPTIONS`/`GET_VARIABLE` | `true` (ack) / `false` appropriately — see below | |

**MUST return `false` (graceful decline) — v1 software renderer:**

| cmd | reason |
|---|---|
| `SET_HW_RENDER` (14) | **returns `false`** → core falls back to software. This is the PPSSPP/melonDS safety gate. |
| `GET_HW_RENDER_INTERFACE` (41) | `false` |
| `GET_CURRENT_SOFTWARE_FRAMEBUFFER` (40) | `false` (we use the video callback, not direct readback) |
| `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` (43) | `false` |
| `GET_PREFERRED_HW_RENDER` (57) | `false` |
| `SET_PROC_ADDRESS_CALLBACK` (33) | `false` (no Vulkan/GL) |
| `GET_VFS_INTERFACE` (46) | `false` |
| `VAR` / `SET_VARIABLE` (71) / `SET_VARIABLES` (16) / `GET_VARIABLE` (15) / `GET_VARIABLE_UPDATE` (17) | `false` (no core options UI in v1; cores accept declines) |
| `GET_RUMBLE_INTERFACE` (23) | `false` |
| `SET_MEMORY_MAPS` (36) / `GET_MEMORY_MAPS` bit | `false` |
| `SET_GEOMETRY` (37) | `false` |
| `GET_PERF_INTERFACE` (28), `GET_LOCATION` (29), `GET_CAMERA` (26), `GET_SENSOR` (25), `GET_CORE_ASSETS_DIRECTORY` (30) | `false` |
| `SET_AUDIO_CALLBACK` (22), `SET_FRAME_TIME_CALLBACK` (21), `SET_AUDIO_BUFFER_STATUS_CALLBACK` (63) | `false` (we use the sample-beta pull model) |

**Every other cmd** (unknown/catch-all) → return `false` with a
`Log.debug("unhandled env cmd \(cmd)")`.

### 3.3 String lifetime pitfall

`GET_SYSTEM_DIRECTORY` / `GET_SAVE_DIRECTORY` / `GET_LIBRETRO_PATH` hand the
core a `const char*`. The core may read it **asynchronously** (usually at load
time). The session must own stable buffers:

```swift
// stored as [CChar] on the session, not on the stack; never realloc'd mid-run.
var systemDirC: [CChar]?   // terminated
var saveDirC: [CChar]?
var libretroPathC: [CChar]?
```

The env handler writes `data!.assumingMemoryBound(to: UnsafePointer<CChar>.self)
.pointee = withUnsafePointer(to: &systemDirC[0]) { $0 }`. Because `&array[0]`
is stable for the array's lifetime and the array lives in the session for the
session's lifetime, this is safe. **Do not** hand back pointers to Swift
`String` temporaries.

### 3.4 `SET_PIXEL_FORMAT` ordering

The core calls `SET_PIXEL_FORMAT` during `retro_load_game` (or `retro_init`).
We store the format in the env struct; after `retro_load_game` returns, the
session reads `environment.pixelFormat` as the authoritative source-format for
`PixelConverter`. Default `xrgb8888` if never set.

---

## 4. `Sources/GameDock/Launch/FrameSlot.swift` — thread-safe latest-frame slot

### 4.1 Purpose

The core thread receives frames via `gd_video` and must hand them to the Metal
draw thread **without** blocking either. We keep only the **latest** frame
(dupe frames from `retro_run` with `data == nil` simply do not update the slot,
matching `GET_CAN_DUPE` semantics).

### 4.2 Design

```swift
final class FrameSlot {
    private let lock = NSLock()
    private var buffer: UnsafeMutableRawPointer? = nil
    private var capacity = 0
    private(set) var width = 0
    private(set) var height = 0
    private(set) var pitch = 0
    private(set) var format: RetroPixelFormat = .xrgb8888
    private(set) var isBGRA = true         // always true post-convert
    private(set) var seq: UInt64 = 0       // increment per new frame (detect new frame)

    /// Core thread: copy `src` (raw, `pitch`-byte rows) → convert to BGRA.
    /// Reallocs internal buffer only when size grows.
    func push(_ src: UnsafeRawPointer?, width: Int, height: Int, pitch: Int, format: RetroPixelFormat)

    /// Render thread: return (pointer, width, height, rowBytes, seq) or nil if empty.
    func latest() -> (ptr: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int, seq: UInt64)?
}
```

**`push` internals (concrete):**

1. If `src == nil` → **dupe frame** → set `seq = 0`? No — keep a `hasNewFrame`
   flag the render thread can test. Simplest: don't touch the buffer, but bump
   nothing (so the renderer's last seq still matches). We'll instead increment
   `seq` only on a real copy and expose `seq` to let the renderer skip re-upload
   when unchanged.
2. `let needBytes = height * pitch` (source row stride is `pitch`, NOT
   `width*2/4`). Allocate/realloc `buffer` to `width * height * 4` (BGRA
   destination is tightly packed).
3. Call `PixelConverter.convert(format:format, src:src, width:width, height:height, srcRowBytes:pitch, dst:buffer!)`.
   > **This is the critical pitch detail**: source rows are `pitch` bytes apart
   > (frequently > `width * bpp` due to alignment). `PixelConverter` already
   > takes `srcRowBytes` and strides correctly.
4. Update `width/height/pitch/format`, `seq += 1`, release lock.

**`latest()` internals:** lock, return a tuple of `(buffer, width, height, width*4, seq)`.
The returned pointer is only valid until the next `push`; the renderer must
finish `replaceRegion` (or at least the copy out of the buffer) before
releasing, and must **not** hold the pointer across `waitUntilScheduled` etc.
For safety, the renderer will copy into a `Data` or use the pointer solely
within the locked `latest()` scope. **Recommended:** have the renderer do the
conversion-free copy under the slot's lock via a `withLatest(_:)` closure:

```swift
func withLatest<T>(_ body: (UnsafeRawPointer, Int, Int, Int, UInt64) -> T) -> T?
```

---

## 5. Run loop + pacing

### 5.1 Thread body (concrete)

```swift
private func runLoop() {
    let fps = avInfo.timing.fps > 0 ? avInfo.timing.fps : 60.0
    let frameInterval = 1.0 / fps
    var next = mach_absolute_time() // or Date-based cadence

    while !stopRequested.load() {
        core.retro_run()
        // pace
        next += interval
        // sleep until `next` (use Thread.sleep or a high-res wait)
        Thread.sleep(forTimeInterval: remaining)
    }
    threadDone.signal()
}
```

- Frame pacing is **driven by `retro_system_timing.fps`**, not by the video
  callback. The video callback fires inside `retro_run` and pushes to `FrameSlot`.
- Use a monotonic clock (use `DispatchTime`/`mach_absolute_time`) to avoid
  drift; compute `next += interval` (not `sleep(interval)` each lap) so we don't
  accumulate error.
- **Input polling:** `retro_run` internally calls our `gd_input_poll` + `gd_input_state`. We do nothing special on the pacing thread; `InputSnapshot` is already lock-protected for concurrent read.

### 5.2 Stop semantics (deadlock-safe ordering — critical)

1. Main/UI thread calls `session.requestStop()` → sets `stopRequested`.
2. `requestStop()` then `threadDone.wait()` (join). The core thread exits the
   loop, signals `threadDone`.
3. **Only after join** does the caller invoke `teardown()`:
   1. `core.retro_unload_game()` (only if a game was loaded).
   2. `core.retro_deinit()`.
   3. `core.unload()` → `dlclose`.
   4. `EmulatorSession.clearActive()` → nil.
4. **Audio teardown must come after** the core thread has fully stopped and
   before/after `retro_deinit` — the audio engine is **not** called by
   `retro_deinit` directly; it's a pull source. Stop the `AVAudioEngine` in
   `teardown()` (see §6) **after** the run loop exits to avoid feeding a doomed
   ring buffer. Do **not** call `AVAudioEngine.stop()` from the core thread.

> **Ordering pitfall:** `dlclose` must be **last**. `retro_deinit` may still
> reference `.rodata`/`.data` in the dylib; closing first would crash. Also never
> `dlclose` from the core thread itself (it would unmap code under the running
> stack frame).

---

## 6. `Sources/GameDock/Launch/RetroAudioEngine.swift` — audio pull source

### 6.1 Ring buffer

```swift
final class RetroAudioRingBuffer {
    private let lock = NSLock()
    private var storage: [Int16]      // interleaved L,R
    private var readIdx = 0
    private var writeIdx = 0
    private var count = 0             // number of samples (not frames)
    let channels = 2

    init(capacitySamples: Int)        // e.g. sampleRate * 2 (1 sec at 2ch)

    /// Core thread (batch): append interleaved samples; drop-oldest on overflow.
    func writeBatch(_ ptr: UnsafePointer<Int16>?, frames: Int) -> Int
    /// Core thread (single sample): fill the underlying int16[2].
    func writeSample(_ l: Int16, _ r: Int16)

    /// Audio render thread: copy up to `n` interleaved samples; returns count.
    /// Zero-fills (silence) on underflow.
    func read(_ out: UnsafeMutablePointer<Int16>, maxSamples: Int) -> Int
    func reset()
}
```

- `writeBatch` returns `frames` consumed (so the core thinks we ate them —
  mirrors `shim_audio_batch`'s contract), but on overflow it actually drops
  oldest. This is the standard "drop-oldest" policy.
- `read` fills `out` with up to `maxSamples` samples; if `count < maxSamples`,
  fill the remainder with `0` (silence) — underflow silence.

### 6.2 `AVAudioEngine` + `AVAudioSourceNode`

```swift
final class RetroAudioEngine {
    private let engine = AVAudioEngine()
    private let ring: RetroAudioRingBuffer
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false

    init(sampleRate: Double, ring: RetroAudioRingBuffer)

    func start() throws
    func stop()

    private func renderBlock() -> AVAudioSourceNodeRenderBlock
}
```

**Render block (concrete):**

```swift
let render: AVAudioSourceNodeRenderBlock = { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
    guard let self else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard let buf = abl[0].mData?.assumingMemoryBound(to: Int16.self) else { return noErr }
    let maxSamples = Int(frameCount) * 2   // 2 channels
    _ = self.ring.read(buf, maxSamples: maxSamples)
    return noErr
}
```

- Set the source node's format to interleaved `Int16` stereo at
  `avInfo.timing.sample_rate` (fallback 44100.0 if `<= 0`).
  `AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 2, interleaved: true)`.
- Attach source node → `engine.attach(sourceNode)`,
  `engine.connect(sourceNode, to: engine.mainMixerNode, format: fmt)`.
- **Sample-rate mismatch:** if the core's `sample_rate` differs from the mixer's
  hardware rate, `AVAudioEngine` resamples. Keep the node format @ core rate so
  the mixer does the conversion.
- Start with `engine.prepare(); try engine.start()` on a background thread
  (never the core thread). `stop()` → `engine.stop()`, detach node.

---

## 7. `Sources/GameDock/Launch/MetalRenderer.swift` — Metal draw

### 7.1 Responsibilities

- Own `MTLDevice`, `MTLCommandQueue`, the `MTLTexture` (BGRA8, sized to the
  frame), a fullscreen-quad pipeline (two triangles) with a passthrough vertex
  shader + a sampling fragment shader, and a `MTLBuffer` for the quad
  vertices.
- Provide `draw(in view: MTKView)` that:
  1. Pulls `frameSlot.withLatest { ... }`.
  2. If the frame size changed, recreate the texture.
  3. `texture.replaceRegion(...)` with the BGRA bytes (copy under the slot lock).
  4. Encode a draw of the quad with the texture bound, **aspect-fit**
     letterboxing by scaling the quad into a normalized clip-space rect derived
     from the view's drawable size + the frame's aspect ratio.

### 7.2 Aspect-fit letterbox (concrete math)

Given view `drawableSize` W×H and frame `fw×fh`:

- `scale = min(W/fw, H/fh)`.
- `sw = fw*scale`, `sh = fh*scale`.
- Normalized (NDC) rect: `x = (-sw/W .. sw/W)`, `y = (-sh/H .. sh/H)`.
- Vertices for the quad use those normalized coords; background clear color =
  black (letterbox bars).

### 7.3 Texture format + pitch

- `MTLTextureDescriptor` pool: `.bgra8Unorm` width=frame width, height=frame
  height, `usage = .shaderRead`, `storageMode = .shared` (or `.private` +
  `replaceRegion`, but `.shared` allows CPU writes directly — use `.shared` and
  `replaceRegion` for simplicity).
- `replaceRegion(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, withBytes: ptr, bytesPerRow: w*4)` — the destination is tightly packed BGRA.

### 7.4 Minimal stub shaders (inline MSL strings, no separate files needed)

```swift
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut vs(uint vid [[vertex_id]]) { ... }
fragment float4 fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}
"""
```

Compile once in `init` via `device.makeLibrary(source:...)`.

---

## 8. `Sources/GameDock/Launch/EmulatorMetalView.swift` — NSView wrapper

```swift
final class EmulatorMetalView: NSView, MTKViewDelegate { ... }
```

- `MTKView` with `device = MTLCreateSystemDefaultDevice()`,
  `.framebufferOnly = false`, `colorPixelFormat = .bgra8Unorm`,
  `delegate = self`, `preferredFramesPerSecond = 60`.
- Implements `mtkView(_:drawableSizeWillChange:)` and `draw(in:)` → forwards to
  `MetalRenderer.draw(in:)`.
- Exposes `var frameSlot: FrameSlot?` (assigned by the session/view controller)
  and `var renderer: MetalRenderer`.

---

## 9. `Sources/GameDock/UI/EmulatorView.swift` — SwiftUI wrapper (overlay only)

```swift
struct EmulatorView: NSViewRepresentable {
    var session: EmulatorSession   // (future wiring; the renderer/session ptr)

    func makeNSView(context: Context) -> EmulatorMetalView { ... }
    func updateNSView(...) { ... }
}
```

- Produces the `EmulatorMetalView` and assigns `frameSlot`/`renderer`.
- Overlay hints (PS button → quick bar, Share → Discord, B → back / quit emulator)
  are **pure SwiftUI** layered with a `.overlay` on the representable's container;
  they only need a `GamepadUIAction` receiver, no core-thread coupling.
- **Do NOT** wire `AppEnvironment` into owning `session` yet — pass the session
  explicitly for now (out of scope per instructions).

---

## 10. `Tests/MockCore/mockcore.c` — the mock libretro core

### 10.1 Contract

A self-contained C file exporting the **full** libretro core API surface that
`RetroCore.load()` requires (symbols resolved by `shim_install`). It is built by:

```
clang -O2 -fPIC -shared -o build/mockcore.dylib Tests/MockCore/mockcore.c
```

(the `Makefile` `mock-core` target already does exactly this — no Makefile change
needed, though the file itself must be created).

### 10.2 Behavior

- `retro_api_version()` → `RETRO_API_VERSION (1)`.
- `retro_get_system_info`: `library_name = "GameDock Mock Core"`,
  `library_version = "1.0.0"`, `valid_extensions = ""`,
  `need_fullpath = false`, `block_extract = false`.
- `retro_get_system_av_info`: geometry `base = 320×240`, `max = 320×240`,
  `aspect_ratio = 4.0/3.0`; timing `fps = 60.0`, `sample_rate = 44100.0`.
- `retro_set_environment`, `retro_set_video_refresh`,
  `retro_set_audio_sample`, `retro_set_audio_sample_batch`,
  `retro_set_input_poll`, `retro_set_input_state` — store the callbacks.
- `retro_init()`, `retro_deinit()`, `retro_reset()` — no-ops.
- `retro_load_game(info)`: **request** `SET_PIXEL_FORMAT = RGB565` via the
  environment callback (so we exercise the RGB565 convert path), then return
  `true`.
- `retro_unload_game()`: no-op.
- `retro_run()`: draw one **320×240 RGB565** frame. Background = black; a
  32×32 cyan square moves right by `squareX++` each frame; if `input_state`
  reports `RETRO_DEVICE_ID_JOYPAD_RIGHT` held, move right extra; if `DOWN`,
  move down. Then call `retro_video_refresh(fb, 320, 240, 640)` (pitch = 320*2
  = 640). Also emit audio: every `retro_run`, write a fixed number of 440 Hz
  square-wave samples (e.g. 44100/60 ≈ 735 frames) via
  `retro_audio_sample_batch`.
- `retro_input_state(port, device, index, id)`: delegate to the stored
  `input_state` callback if set, else return 0. (This exercises the input
  plumbing round-trip: Swift `InputSnapshot` → core → mock reads it.)
- On `retro_get_system_info`/`init`, also call `GET_LOG_INTERFACE`
  (`shim_log_printf`) and `GET_SYSTEM_DIRECTORY` to verify env plumbing; log a
  line.

> The square movement driven by `input_state` is the observable property the
> selftest asserts (§11).

---

## 11. `Sources/GameDock/CLI/CLI.swift` — `CLISelfTest.run()` (rewrite stub)

### 11.1 Harness flow (headless, no GUI)

```swift
enum CLISelfTest {
    static func run() -> Bool {
        let corePath = env "GAMEDOCK_CORE_PATH" or "build/mockcore.dylib"
        let session = EmulatorSession(corePath: corePath, romPath: nil, romData: nil)
        // 1. load
        // 2. set input (press RIGHT) into session.inputSnapshot
        // 3. start() ; run ~180 frames
        // 4. assert:
        //    - frameSlot received ≥ 1 frame, format == .rgb565, 320×240
        //    - audioRing received ≥ 1 sample batch
        //    - square moved (frame pixel diff on subsequent frames / seq advanced)
        //    - input: pressing RIGHT toggled movement (compare two runs or
        //      inspect a pixel column)
        // 5. requestStop + join + teardown
        // 6. print "SELFTEST PASS/FAIL"
    }
}
```

**Concrete assertions:**

- **Video received:** after 180 frames, `session.frameSlot.seq > 0`, width==320,
  height==240, `pixelFormat == .rgb565`.
- **Audio received:** `session.audioRing.availableSamples > 0`.
- **Input moves square:** run 30 frames with `setButton(port:0,id:RETRO_DEVICE_ID_JOYPAD_RIGHT, pressed:true)`, capture the square's center via reading back a
  frame through `withLatest`, release RIGHT for 30 frames, capture again — the
  X coordinate must have advanced by the expected amount; with the button
  released, movement must be exactly the per-frame `squareX++` (1 px/frame)
  — assert the delta with RIGHT held > delta with released.
- **Frame conversion verified:** read a specific pixel (the square's color) from
  the BGRA output and confirm it is cyan `(b=0xFF, g=0xFF, r=0x00, a=0xFF)` in
  BGRA byte order.

The harness uses `PixelConverter` output (already in the slot) directly — no
Metal needed headlessly. Print `Log.cliPrint("SELFTEST PASS")` / `FAIL` and
`return passed`.

### 11.2 Note on `GAMEDOCK_CORE_PATH`

The Makefile already injects `GAMEDOCK_CORE_PATH=build/mockcore.dylib`. `run()`
reads `ProcessInfo.processInfo.environment["GAMEDOCK_CORE_PATH"] ?? "build/mockcore.dylib"`.

---

## 12. Ordering of work (for the executing worker)

1. `Sources/GameDock/Launch/RetroCore.swift` — loader + typealiases + structs.
2. `Sources/GameDock/Launch/FrameSlot.swift` — frame slot (no deps beyond PixelConverter).
3. `Sources/GameDock/Launch/RetroAudioEngine.swift` + `RetroAudioRingBuffer` — audio.
4. `Sources/GameDock/Launch/RetroEnvironment.swift` — env handler.
5. `Sources/GameDock/Launch/EmulatorSession.swift` — orchestrator + `@convention(c)` globals + run loop + teardown.
6. `Tests/MockCore/mockcore.c` — mock core.
   - Build: `make mock-core` (no Makefile change; file must exist).
7. `Sources/GameDock/CLI/CLI.swift` — rewrite `CLISelfTest.run()`.
   - Verify: `make selftest` → `SELFTEST PASS`.
8. `Sources/GameDock/Launch/MetalRenderer.swift` — Metal renderer.
9. `Sources/GameDock/Launch/EmulatorMetalView.swift` — NSView/MTKView delegate.
10. `Sources/GameDock/UI/EmulatorView.swift` — SwiftUI representable + overlay
    (no AppEnvironment wiring).
11. `make build` clean + `make selftest` still PASS (commit point).

### New files (all under `Sources/GameDock/Launch/` unless noted)

| File | Contents |
|---|---|
| `Launch/RetroCore.swift` | dlopen/dlsym loader + typealiases + C-struct mirrors |
| `Launch/RetroEnvironment.swift` | environment command table |
| `Launch/EmulatorSession.swift` | orchestrator, `@convention(c)` globals, run loop, teardown |
| `Launch/FrameSlot.swift` | thread-safe latest-frame slot |
| `Launch/RetroAudioEngine.swift` | `RetroAudioRingBuffer` + `AVAudioSourceNode` engine |
| `Launch/MetalRenderer.swift` | Metal device/pipeline/texture/quad + aspect-fit draw |
| `Launch/EmulatorMetalView.swift` | `NSView` + `MTKViewDelegate` |
| `UI/EmulatorView.swift` | `NSViewRepresentable` + overlay hints |
| `Tests/MockCore/mockcore.c` | mock libretro core |

### Existing files to touch

| File | Change |
|---|---|
| `Sources/GameDock/CLI/CLI.swift` | replace `CLISelfTest.run()` stub with the full harness |
| `Package.swift` | **no change** (CLibretro already exposes shim; no new deps) |
| `Makefile` | **no change** (`mock-core` + `selftest` targets already correct) |
| `Sources/CLibretro/*` | **no change** (ABI-critical) |

---

## 13. Summary of landmines (for the worker)

1. `shim_set_callbacks` → `shim_install` → `retro_init` order is **mandatory**
   (shim.c comment). Installing after init means cors never receive callbacks.
2. `unsafeBitCast` only on pointer→`@convention(c)` pointer, matching typedefs;
   never on data pointers.
3. `need_fullpath` cores: pass path C string, data=nil. Mock core uses
   `need_fullpath=false` with data (or nil); melonDS is `need_fullpath=true`.
4. **Pitch**: `PixelConverter` takes `srcRowBytes = pitch`, not `width*bpp`.
5. **Dupe frames** (`data == nil`) must NOT clear the slot — skip silently.
6. **dlclose last**, never on the core thread.
7. **String env pointers** must live in session-owned `[CChar]`, not temporaries.
8. **`SET_HW_RENDER` must return `false`** — software only.
9. Audio `AVAudioEngine` start/stop on background thread, never the core thread.
10. `RTLD_NOW | RTLD_GLOBAL` on dlopen; `RTLD_GLOBAL` is what makes
    `shim_install`'s `dlsym(RTLD_DEFAULT, ...)` work.

---

*End of plan.*
