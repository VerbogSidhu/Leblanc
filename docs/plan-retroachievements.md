# GameDock — RetroAchievements Integration Plan (planner, read-only)

> Status: **PLAN** — no files were edited. This document is the design contract for a
> follow-up worker role. It supersedes the hook notes in `docs/audit-v2.md` §4.

---

## 0. Executive summary

Wire the vendored `CRcheevos` (rcheevos **v12.4.0**) into the libretro emulator path
(melonDS / DS today, any software-render core tomorrow) via a thin
`RCClientService` that owns a single `rc_client_t`. Three non-capturing
`@convention(c)` trampolines (read-memory, server-call transport, event handler)
route into `EmulatorSession`, following the exact `EmulatorSession.active` pattern
already used by the `CLibretro` shim. No changes to `Sources/CLibretro` are required.

**Two hard planning corrections vs. the audit (verified against the vendored headers
and the built binary):**

1. **Console IDs** — `Sources/CRcheevos/include/rc_consoles.h` says:
   - `RC_CONSOLE_NINTENDO_DS = 18` (audit guessed "33", wrong)
   - `RC_CONSOLE_PSP = 41`  (audit guessed "14/25", wrong)
   - `RC_CONSOLE_NINTENDO_DSI = 78` (not used in v1)

2. **Identify-and-load is compiled OUT of the current build.** `rc_client_begin_identify_and_load_game`
   is wrapped in `#ifdef RC_CLIENT_SUPPORTS_HASH` (`rc_client.h:265`, `.c` line 1202+),
   and `nm .build/arm64-apple-macosx/debug/GameDock` shows the symbol is **absent**,
   while `rc_client_create`, `rc_client_begin_load_game`, and the full `rc_hash_*`
   family ARE present. The hash *library* is compiled in; the *client identify glue*
   is not. This plan therefore proposes a **two-stage hash flow** (hash locally with
   `rc_hash_generate`, then load with `rc_client_begin_load_game`) plus an **optional
   build flag** to re-enable identify if desired. See §2.

---

## 1. Import surface — direct Swift `import CRcheevos`

The module map (`Sources/CRcheevos/include/module.modulemap`) exports an umbrella
`rcheevos` module with submodules. Swift code should do:

```swift
import CRcheevos
```

Availability note: `rc_client.h` is importable, but the `rc_client_*` types are
`typedef struct rc_client_t* rc_client_t;` — an **opaque C pointer** imported as an
`OpaquePointer`. All `rc_client_*` functions that Swift will call are plain
`@convention(c)` exports (declared `RC_EXPORT`, which on Apple Silicon resolves to
`__attribute__((visibility("default")))` under `RC_STATIC`) and are directly callable.

### 1.1 — Functions the service will call (all present in the binary)

| Function | Purpose | Thread |
|---|---|---|
| `rc_client_create(read_memory_func, server_call_func)` | create client with the two mandatory callbacks | main (session `load()`) |
| `rc_client_destroy(client)` | free client | teardown (after core joined) |
| `rc_client_set_host(client, hostname)` | override API host (default is fine) | once at create |
| `rc_client_set_get_time_millisecs_function(client, fn)` | monotonic clock (rcheevos needs ms-since-epoch or monotonic; default is `time(NULL)`-based seconds — **must supply** a ms monotonic fn) | once at create |
| `rc_client_enable_logging(client, level, callback)` | route rcheevos logs → `Log.*` | once at create |
| `rc_client_set_event_handler(client, handler)` | achievement/leaderboard/reset events | once at create |
| `rc_client_set_hardcore_enabled(client, enabled)` | softcore vs hardcore | at create / settings change |
| `rc_client_set_unofficial_enabled(client, enabled)` | include unofficial sets | at create (default false) |
| `rc_client_set_allow_background_memory_reads(client, allowed)` | must be **false** (reads only inside do_frame) | once at create |
| `rc_client_begin_login_with_token(client, username, token, callback, userdata)` | login via API token | session start / pre-game |
| `rc_client_begin_login_with_password(client, username, password, callback, userdata)` | login via password (optional) | session start |
| `rc_client_begin_load_game(client, hash, callback, userdata)` | load identified game by hash | after hash computed |
| `rc_client_get_load_game_state(client)` | poll async load progress | run loop / idle |
| `rc_client_is_game_loaded(client)` | gate `do_frame` | run loop |
| `rc_client_do_frame(client)` | advance achievement state (advances internal frame counter) | core thread, once per `retro_run` |
| `rc_client_idle(client)` | pump periodic queue when paused | core thread |
| `rc_client_is_processing_required(client)` | skip work when nothing active | core thread |
| `rc_client_unload_game(client)` | release game before core unload | teardown |
| `rc_client_reset(client)` | on `RC_CLIENT_EVENT_RESET` | event handler |
| `rc_client_get_user_game_summary(client, &summary)` | "unlocked X of Y" | UI |
| `rc_client_get_achievement_info(client, id)` | toast metadata | UI |
| `rc_client_achievement_get_image_url(achievement, state, buf, size)` | badge URL | UI/ArtworkLoader |
| `rc_client_has_rich_presence(client)` / `rc_client_get_rich_presence_message(...)` | overlay text | UI (optional) |

### 1.2 — `@convention(c)` non-capturing constraint (mirror the shim)

C function pointers passed to `rc_client_create` / `set_event_handler` / `set_get_time_millisecs`
/ `enable_logging` **cannot capture** Swift context. Use exactly the pattern in
`EmulatorSession.swift:7-47` and `CLibretro/include/shim.h`: top-level `private` free
functions that dereference `EmulatorSession.active` (or a dedicated global RA pointer).

**Proposed routing:** instead of overloading `EmulatorSession.active` (which the shim
already owns and which the audit §1.2 flagged as a race), add a dedicated
`RCActive.global: RCClientService?` static guarded by its own `NSLock`. This isolates RA
callback routing from libretro callback routing and avoids enlarging §1.2's existing race.

```swift
// RCClientService.swift — file scope, non-capturing
private func rc_read_memory(_ address: UInt32, _ buffer: UnsafeMutablePointer<UInt8>?,
                            _ numBytes: UInt32, _ client: OpaquePointer?) -> UInt32 {
    RCClientService.active?.readMemory(address, buffer, numBytes) ?? 0
}
private func rc_server_call(_ request: UnsafePointer<rc_api_request_t>?,
                            _ callback: @convention(c) (UnsafePointer<rc_api_server_response_t>?, UnsafeMutableRawPointer?) -> Void,
                            _ callbackData: UnsafeMutableRawPointer?,
                            _ client: OpaquePointer?) {
    RCClientService.active?.serverCall(request, callback, callbackData)
}
private func rc_event(_ event: UnsafePointer<rc_client_event_t>?, _ client: OpaquePointer?) {
    RCClientService.active?.handleEvent(event)
}
private func rc_log(_ message: UnsafePointer<CChar>?, _ client: OpaquePointer?) {
    guard let message else { return }
    Log.debug("rcheevos: \(String(cString: message))")
}
private func rc_get_time_ms(_ client: OpaquePointer?) -> UInt64 {
    // monotonic ms, e.g. DispatchTime or mach_absolute_time-based
    UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
}
```

The `rc_server_call_t` callback signature is awkward to name directly in Swift because it
passes a `rc_client_server_callback_t` (a function pointer) as an argument. Swift *can*
name it via `@convention(c)` closures; if the module import flattens it awkwardly, wrap the
signature in a `typealias`:

```swift
typealias RCClientServerCallback = @convention(c) (UnsafePointer<rc_api_server_response_t>?, UnsafeMutableRawPointer?) -> Void
```

The worker should verify the exact imported spelling with a scratch compile (see §8).

---

## 2. Hashing + identify (two-stage; no `RC_CLIENT_SUPPORTS_HASH`)

Because identify is compiled out, we hash locally and load by hash.

### 2.1 — Path A (recommended, works today): `rc_hash_generate` + `rc_client_begin_load_game`

`rc_hash_generate(char hash[33], uint32_t console_id, const rc_hash_iterator_t*)` is
present in the binary and handles the DS/PSP hash algorithms internally (including
zip-embedded `.nds` when `rc_hash_initialize_iterator` is given a `buffer`+`buffer_size`).

Flow in `RCClientService.loadGame(…)` (called from `EmulatorSession.load()` after
`loadedGame = true`):

```
romPath / romData already held by EmulatorSession
  ├─ case DS (melonDS, need_fullpath=false): read full ROM bytes (Data(contentsOf:))
  │    and hash the buffer.
  │      rc_hash_initialize_iterator(&it, path_or_nil, bytes, size)
  │      rc_hash_generate(hash, RC_CONSOLE_NINTENDO_DS, &it)
  │      rc_hash_destroy_iterator(&it)
  ├─ case PSP (fullpath, standalone — NOT the libretro path in v1): out of scope
  │    unless a libretro PSP core ships later; then RC_CONSOLE_PSP + file path.
  └─ fall back to rc_hash_generate_from_buffer / from_file (deprecated but present).
```

Then `rc_client_begin_load_game(client, hash, load_callback, userdata)`.

> Note: the local hash must match the RetroAchievements canonical hash used for that
> console. For DS, rcheevos hashes the decrypted/trimmed `.nds` per its own logic; the
> `rc_hash_generate` path is the same code the identify flow would use, so it will
> produce a matching hash. The mock-core self-test should use a fake hash (see §7), not a
> real ROM.

### 2.2 — Path B (optional, requires build change): re-enable identify

If one-shot identify UX is preferred (single server round-trip that returns *both* the
hash match and the game data), add `-DRC_CLIENT_SUPPORTS_HASH` to the `CRcheevos` target in
`Package.swift`:

```swift
cSettings: [ ...existing...,
    .define("RC_CLIENT_SUPPORTS_HASH")   // enables rc_client_begin_identify_and_load_game
]
```

This is a build-config-only change (no C source edit). It pulls `rc_hash` *callbacks*
into `rc_client` (it will then need `rc_client_set_hash_callbacks` for custom file/CD
readers — default `stdio`-based filereader is fine for `.nds` since `need_fullpath` DS
cores read the file themselves). **Decision for v1: Path A.** It avoids touching the
ABI-critical build and keeps the surface exactly what the already-compiled binary exposes.
Path B is documented for a future PR if identify turns out to be needed for `pbp`/multi-disc.

---

## 3. `read_memory` — map libretro regions + ROM

The single `read_memory` callback serves both runtime achievement checks and (during the
hash phase, if Path B were used) ROM reads. With Path A the ROM hash happens locally, so
`read_memory` is **runtime-only**: map addresses against the libretro regions.

### 3.1 — Address mapping

rcheevos addresses are in the console's native memory space (DS: `RC_CONSOLE_NINTENDO_DS`
defines its `rc_console_memory_regions`). libretro exposes *contiguous base pointers* per
region id:

| rcheevos region (native addr) | libretro id | notes |
|---|---|---|
| main RAM | `RETRO_MEMORY_SYSTEM_RAM` (2) | primary; melonDS exposes main RAM here |
| SRAM/battery | `RETRO_MEMORY_SAVE_RAM` (0) | progression state |
| RTC | `RETRO_MEMORY_RTC` (1) | time-based achievements |
| VRAM | `RETRO_MEMORY_VIDEO_RAM` (3) | rare |

**Recommended implementation (simple, correct for v1):** serve `RETRO_MEMORY_SYSTEM_RAM`
for the low address window, and fall back through the other regions for addresses that
fall outside it. Do this by fetching each region's base+size once per session (cached in
`RCClientService` after `retro_load_game`), not per-byte.

```swift
final class RCClientService {
    struct Region { let base: UnsafeMutableRawPointer?; let size: Int }
    private(set) var regions: [UInt32: Region] = [:]   // libretro id -> region

    func cacheRegions(from core: RetroCore) {
        for id in [0, 1, 2, 3] as [UInt32] {
            if let fn = core.retroGetMemoryData, let sz = core.retroGetMemorySize {
                let base = fn(id); let size = sz(id)
                if base != nil && size > 0 { regions[id] = Region(base: base, size: size) }
            }
        }
    }

    func readMemory(_ address: UInt32, _ buffer: UnsafeMutablePointer<UInt8>?,
                    _ numBytes: UInt32) -> UInt32 {
        guard let buffer, numBytes > 0 else { return 0 }
        // Serve SYSTEM_RAM (2) for the whole native address space first (melonDS maps
        // its main RAM as the canonical region). Then SAVE_RAM/RTC/VIDEO_RAM windows.
        let order: [UInt32] = [2, 0, 1, 3]
        for id in order {
            guard let r = regions[id] else { continue }
            // find the native sub-range that overlaps [address, address+numBytes)
            ...
            memcpy(buffer, base + offset, count)
            return count   // partial copies are expected by rcheevos
        }
        return 0
    }
}
```

**Constraints (must be explicit in worker code):**
- Runs **only on the core thread** (invoked inside `rc_client_do_frame`). Never call
  `retro_get_memory_data`/`size` here — use cached pointers (they are stable for the
  session). The contents are only valid after `retro_run` commits and before the next.
- `retro_get_memory_data` is `O(1)` — cache it once after `retro_load_game`, do not
  re-resolve per read.
- Handle `address + numBytes > size`: return a **partial** read (count < numBytes) — rcheevos
  tolerates this. Never read past the region end.
- Do **not** retain the region pointer across a `retro_reset`/`retro_unload_game` (the
  core thread is the only writer of those, so same-thread correctness holds).

For the **DS console memory map**, the worker should optionally verify against
`rc_console_memory_regions(RC_CONSOLE_NINTENDO_DS)` (exported) to decide the native→libretro
base offsets. melonDS-libretro's `RETRO_MEMORY_SYSTEM_RAM` is the main RAM and generally
corresponds to the canonical achievement address space; for v1 a direct
"address 0 = SYSTEM_RAM base" mapping is the correct MVP and matches the audit's §4.4.

---

## 4. `server_call` — URLSession transport

This is the #1 new complexity (audit §4.6). Key simplification discovered: **`rc_client`
/ the `rapi/` layer build the complete `rc_api_request_t` (URL + `post_data` +
`content_type`) for every request type** — login (`rc_api_init_login_request_hosted`),
start-session, award-achievement, ping, etc. all funnel through `rc_api_url_build_dorequest`.
The Swift `server_call` callback does **not** parse JSON or know endpoint names; it only:
1. POSTs `request->post_data` (or GET if `post_data == NULL`) to `request->url`.
2. Copies the raw body + `Content-Length` + HTTP status into a `rc_api_server_response_t`.
3. Marshals that response back to rcheevos via the provided `rc_client_server_callback_t`.

### 4.1 — Callback signature & responsibilities

```c
typedef void (RC_CCONV *rc_client_server_call_t)(
    const rc_api_request_t* request,
    rc_client_server_callback_t callback,
    void* callback_data,
    rc_client_t* client);
```

`rc_api_request_t` (from `rc_api_request.h`) fields:
- `url` (full URL with query args, e.g. `https://retroachievements.org/dorequest.php?...`)
- `post_data` (may be `NULL` → GET; else POST body)
- `content_type` (e.g. `application/x-www-form-urlencoded`)
- `buffer` (owned by rcheevos; the strings point into it — valid only during the call)

`rc_api_server_response_t` (build this):
- `body` → copy of the HTTP response body
- `body_length` → `Content-Length`
- `http_status_code` → e.g. 200

The `callback` (a `rc_client_server_callback_t`) *owns the response handling*:
`rc_client.c` will call `rc_api_process_login_server_response` / `…_start_session_…` /
`…_award_achievement_…` internally and then complete the async pipe. We just invoke it
with a valid `rc_api_server_response_t`.

### 4.2 — Asynchronous vs synchronous

`rc_client`'s `server_call` is invoked on the **pumping thread** (our core thread) and is
expected to eventually call `callback` — but it must **not** block the core thread while the
HTTP round-trip happens (that would stall `retro_run`). Design:

- `server_call` copies `request->url`, `post_data`, `content_type` into Swift-owned buffers
  (Swift `String` / `Data`), snapshots the `callback`/`callback_data`/`client` pointers,
  and immediately returns.
- A `DispatchQueue.global(qos: .utility)` (URLSession delegate queue) issues the POST/GET.
- On completion, URLSession's completion handler runs **off the core thread**. rcheevos
  expects the `callback` on the **same thread that pumps `do_frame`**. Therefore marshal
  the result back to the core thread before calling `callback`.

### 4.3 — Marshaling the result back to the core thread (the crux)

Two viable mechanisms; recommend the **pending-response queue + do_frame drain** because
`rc_client_idle`/`rc_client_do_frame` already give us a per-frame core-thread hook:

**Design A (recommended): pending-callback FIFO drained by `do_frame`/`idle`.**
- `RCClientService` keeps `PendingCallbacks: [(callback, callbackData, rc_api_server_response_t)]`
  guarded by an `NSLock`.
- URLSession completion pushes (copies) into the queue and sets a `needsPump` flag.
- The next `do_frame`/`idle` on the core thread (which GameDock calls after `retro_run`)
  drains the queue and invokes each stored `callback(response, data)`.
- Because `rc_client` re-enters `server_call` for *subsequent* steps of the async chain
  (login → load → start-session → …), draining must tolerate re-entrancy (don't hold the
  lock while invoking callbacks).

**Design B (alternative): `DispatchQueue` hop to the core thread directly.** The core
thread runs a manual `while !stopRequested { retro_run(); … }` loop, not a runloop, so
`DispatchQueue.main`/custom-queue hops won't run *on* the core thread. A dedicated
`Thread` with a `CFRunLoop` could host it, but that adds a second emulator thread — reject.
Design A is the correct fit.

### 4.4 — Endpoints (informational; the Swift code should NOT hardcode these)

For the worker's understanding (and error-logging/allow-list), the endpoints rcheevos 12.4
generates are (all `https://retroachievements.org/dorequest.php` + `r=…` in `post_data`
or query):

| `r=` value | purpose | built by |
|---|---|---|
| `login` | auth (password or token) | `rc_api_init_login_request_hosted` |
| `start_session` | begin a game session (returns prior unlocks) | `rc_api_init_start_session_request_hosted` |
| `award_achievement` | submit an unlock | runtime award |
| `patch` (identify) / `gameid` | fetch game data + patch | `rc_api_init_fetch_…` (identify Path B) |
| `ping` | keepalive during long sessions | scheduled callback |
| `lb_submit` / leaderboard | leaderboard submit/fetch | leaderboard API |

**The Swift transport treats all identically.** The only value in knowing them is logging
("requesting r=start_session") and a minimal debug allow-list. Host override:

```swift
rc_client_set_host(client, "retroachievements.org")   // default; leave as-is
```

User-Agent: append `rc_client_get_user_agent_clause` (e.g. `"rcheevos/12.4.0"`) to a
`GameDock/<version>` UA so the RA servers can identify the client.

---

## 5. Frame loop, events, and UI surface

### 5.1 — Call sites in `EmulatorSession.swift`

1. **Property:** add `private(set) var rcService: RCClientService?` to `EmulatorSession`.

2. **`load()`** (`EmulatorSession.swift:168-252`), **after** `loadedGame = true` and the
   post-load `retroGetSystemAVInfo` re-query (before `state = .loaded`):
   ```
   let service = RCClientService(session: self)
   if let creds = service.credentialsFromSettings() {   // username + api token set
       service.create()                                   // rc_client_create + callbacks + config
       EmulatorSession or AppEnvironment passes consoleId + rom bytes → service.begin(…)
   }
   self.rcService = service   // nil if no creds → achievements disabled, no-op
   ```
   Credentials come from `SettingsStore` (see §6), threaded in via a new
   `EmulatorSession` init parameter or read directly from an injected settings reference.
   Cleanest: pass `GameSource` (already available from `AppEnvironment.startEmulator`) so
   the service can pick the console id without coupling to settings plumbing.

3. **`runLoop()`** (`EmulatorSession.swift:301-355`), **after** `core?.retroRun?()` at
   line ~323 and **after** the HW readback block:
   ```
   if let rc = rcService, rc.isReady, rc_client_is_processing_required(rc.client) != 0 {
       rc_client_do_frame(rc.client)
       rc.drainPendingCallbacks()        // core-thread server-return delivery (§4.3)
   }
   ```
   Always call `rc.drainPendingCallbacks()` each frame regardless of processing-required
   (login/load callbacks must be delivered even before a game is loaded; if
   `is_processing_required` is false but callbacks are pending, the drain still runs).

4. **`requestStop()`** (`EmulatorSession.swift:361-388`): no change; `rc_client_idle` is
   not needed here because the loop is about to exit.

5. **`teardown()`** (`EmulatorSession.swift:390-410`), **before** `core?.retroUnloadGame?()`:
   ```
   rcService?.unloadGame()     // rc_client_unload_game
   rcService?.destroy()        // rc_client_destroy
   rcService = nil
   ```
   Order caveat from audit §1.1: destroy must run after the core thread has joined (true —
   teardown runs post-`requestStop`), never while `retro_run` is on the stack. The ROM
   hash/token buffers must be released before `core.unload()` only if they reference core
   memory (they don't — they're `Data` copies).

6. **`retro_reset` hook** — future: if hardcore enable raises `RC_CLIENT_EVENT_RESET`
   (event type 14), the event handler calls `core?.retroReset?()` (present at
   `RetroCore.swift:169-172`) and `rc_client_reset(client)`.

### 5.2 — Event handler → UI toast (thread-safe)

The `rc_client_set_event_handler` callback runs on the core thread. It must **not** touch
SwiftUI. Map events to main-thread notifications:

| event type | value | action |
|---|---|---|
| `RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED` | 1 | toast "Achievement Unlocked: <title>" |
| `RC_CLIENT_EVENT_LEADERBOARD_STARTED/SUBMITTED` | 2/4 | toast (optional) |
| `RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW/UPDATE` | 7/9 | progress pill |
| `RC_CLIENT_EVENT_RESET` | 14 | `core.retroReset()` + `rc_client_reset` |
| `RC_CLIENT_EVENT_GAME_COMPLETED` | 15 | completion toast + summary |
| `RC_CLIENT_EVENT_SERVER_ERROR` / `DISCONNECTED` / `RECONNECTED` | 16/17/18 | status pill |

Implementation: the event handler extracts `event->type` + `event->achievement->title`
(**copy** the `CChar` strings immediately — rcheevos buffers are only valid within the
callback) and dispatches to main:

```swift
DispatchQueue.main.async {
    AppEnvironment.toastSubject.send( .achievement(title) )   // or NotificationCenter
}
```

Add an `ObservableObject`-backed toast store (e.g. `RAToastModel` in `RCClientService.swift`
or `AppEnvironment`) surfaced in `EmulatorScreen` (`Sources/GameDock/UI/EmulatorScreen.swift`).

### 5.3 — `EmulatorScreen` overlay additions (non-blocking)

`EmulatorScreen` is the natural surface. Add:
- A **toast** view (top-right beneath the title pill) bound to the RA toast store, with
  auto-dismiss after ~4 s, reusing `Theme.meta` styling.
- An optional **rich-presence / unlocked-count** pill using `rc_client_get_user_game_summary`
  (only when a game is loaded) — queried on main thread after login/load events.
- Badge art via `rc_client_achievement_get_image_url` → reuse `ArtworkLoader`'s disk cache.
  (Audit §3.2 suggests adding an LRU cap — the RA badges share that path; note for the
  library engineer, not required for RA correctness.)

Do not add any network work on the SwiftUI thread; badges/HTTP are already off-main.

---

## 6. Settings (username + API key + hardcore)

Extend `Sources/GameDock/Libraries/SettingsStore.swift`:

```swift
private enum Key {
    static let raUsername       = "raUsername"      // String?
    static let raAPIToken       = "raAPIToken"      // String?
    static let raHardcore       = "raHardcore"      // Bool (default true, matches rcheevos)
    static let raUnofficial     = "raUnofficial"    // Bool (default false)
}

@Published private(set) var raUsername: String?
@Published private(set) var raAPIToken: String?
@Published private(set) var raHardcore: Bool = true
@Published private(set) var raUnofficial: Bool = false
// + get/set methods persisting to UserDefaults (same pattern as romFolders/coreOverrides)
```

**API token vs password:** use the **API token** (the modern RA credential; users generate
it at retroachievements.org/controlpanel.php). `rc_client_begin_login_with_token` is the
primary path; `begin_login_with_password` is optional and **not** stored in settings (we
never persist a plaintext password).

**Settings UI** — `SettingsView` lives inside the XMB (not a standalone file; it is one of
the `AppEnvironment`/`XMBView` categories). Add a "RetroAchievements" category with:
- Username text field (gamepad + keyboard editing; reuse existing text-edit path if any,
  else a simple `TextField`).
- API token `SecureField`.
- Hardcore/softcore `Toggle` (hardcore disables save/load + rewinds; note this disables
  features not yet implemented, so still OK).
- Unofficial achievements `Toggle`.
- "Sign in / signed in as <display_name>" status row (driven by a login test).

When either credential is empty, `RCClientService` is a no-op (achievements silently off),
matching the "optional integration" posture.

---

## 7. Minimal C smoke-test (headless, deterministic)

The worker must prove the link + callback plumbing **without** a real ROM, ROM hash, or
network. Add a CLI mode or extend `--selftest`:

**`Tests/TestRCCore` (or reuse `MockCore`) + a Swift `--ra-smoke` CLI** that:

1. Creates an `rc_client_t` with:
   - a fake `read_memory` that returns a small fixed RAM image (e.g. a static 64-byte buffer),
   - a fake `server_call` that (synchronously) returns canned `rc_api_server_response_t`
     bodies (a fake login success JSON, a fake patch response), and records the sequence of
     `url`/`post_data` it received for assertions.
2. Calls `rc_client_create` + `set_event_handler` + `enable_logging`, asserts the client is
   non-nil and the callbacks are stored (no crash).
3. Calls `rc_client_begin_login_with_token("smoketest", "token", cb, nil)`, pumps
   `rc_client_idle`/`do_frame` (with `is_processing_required` forced true), and asserts:
   - the fake `server_call` was invoked with a URL containing `login`,
   - the login callback fired with `result == RC_OK`.
4. Calls `rc_client_begin_load_game` with a known hash, pumps, asserts the patch load
   progressed (`rc_client_get_load_game_state` advanced past `FETCHING_GAME_DATA`).
5. Registers a fake achievement that triggers on a memory write and asserts
   `RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED` fires via the event handler.
6. `rc_client_destroy` and asserts no leak/abort (run under a quick `NSZone`/malloc scribble
   or simply repeat N× and watch RSS).

Deliverable: the smoke test must pass under `swift run GameDock --ra-smoke` with
`--selftest` still green. This is the **gate** before touching `EmulatorSession`.

What it does **not** need: a real emulator core, real ROM hashing, real network. It proves
the Swift↔C `@convention(c)` signatures, the server-call transport contract, and the
event→callback plumbing end-to-end.

---

## 8. File-by-file change list (worker checklist)

| File | Change | New? |
|---|---|---|
| `Package.swift` | **no change** for Path A; (optional) add `.define("RC_CLIENT_SUPPORTS_HASH")` for Path B | edit (optional) |
| `Sources/GameDock/RetroAchievements/RCClientService.swift` | new class: create/destroy/login/loadGame/doFrame/unload, `active` static, non-capturing globals, readMemory, serverCall+URLSession transport+pending queue, handleEvent→toast store | **new** |
| `Sources/GameDock/RetroAchievements/RAConsole.swift` | `GameSource → rc_console id` enum (DS=18, PSP=41) | **new** |
| `Sources/GameDock/RetroAchievements/RAHash.swift` | `rc_hash_initialize_iterator` + `rc_hash_generate` wrapper returning `String` hash | **new** |
| `Sources/GameDock/RetroAchievements/RAToastModel.swift` | `ObservableObject` toast queue (title, type, auto-dismiss) | **new** |
| `Sources/GameDock/Launch/EmulatorSession.swift` | add `rcService`; hook `load()` / `runLoop()` / `teardown()`; pass `GameSource` | edit |
| `Sources/GameDock/AppEnvironment.swift` | pass `entry.source` + settings into session init; add RA toast model; `exitEmulation` already calls teardown | edit |
| `Sources/GameDock/Libraries/SettingsStore.swift` | add `raUsername/raAPIToken/raHardcore/raUnofficial` keys + accessors | edit |
| `Sources/GameDock/UI/EmulatorScreen.swift` | toast view + optional summary/rich-presence pill | edit |
| `Sources/GameDock/UI/XMBView.swift` | Settings category rows (username / token / hardcore / unofficial / status) | edit |
| `Sources/GameDock/CLI/CLI.swift` | `--ra-smoke` entry point running §7 smoke test | edit |
| `Tests/` (or CLI) | smoke test harness (fake read/server callbacks) | **new** |

ABI-critical files (`Sources/CLibretro/**`) — **do not touch.**

---

## 9. Order of work

1. **§7 smoke test + §1.1 typealias verification** — prove `import CRcheevos` compiles and
   the three `@convention(c)` callback signatures resolve against the real binary. This
   de-risks everything else. (`--ra-smoke` green is the gate.)
2. **§6 settings + `RAConsole` + `RAHash`** — persistence + console mapping + local hash.
3. **§3 read_memory + §5.1 EmulatorSession hooks** — hook the service into the session
   (no network, no real login yet); verify `do_frame` runs without crashing under
   `--selftest` (mock core + empty creds → no-op service).
4. **§4 server_call transport** — URLSession + pending-callback drain; wire a real login
   (with API token from settings) and load-by-hash for a real DS ROM.
5. **§5.2/§5.3 events + UI** — toast, summary pill, rich presence.
6. **§9 hardcore/softcore + reset event** — `retro_reset`/`rc_client_reset` on hardcore
   toggle (deferred until core reset is exercised).
7. Run: `make build`, `make selftest`, `swift run GameDock --ra-smoke`, then manual DS ROM
   with a real RA account; write `docs/worker-report.md`.

---

## 10. Risks / notes

- **`@convention(c)` callback spelling for `rc_client_server_call_t`** is the highest-risk
  compile detail — mitigate with §1.2 typealiases + the §7 gate before proceeding.
- **`RC_CLIENT_SUPPORTS_HASH` absence** means no `begin_identify_and_load_game`; Path A
  (local hash + `begin_load_game`) is the v1 design. Document Path B for future `pbp`.
- **Threading** is the other top risk: server-call callbacks must return on the core
  thread (§4.3 Design A). Never call `retro_*` or SwiftUI from a URLSession thread.
- **`rc_client` is not thread-safe** across arbitrary threads; all `do_frame`/`idle`/
  `read_memory` stay on the core thread, all `create`/`destroy` on the session owner
  (main), and the pending queue is the only cross-thread bridge.
- **Credentials are never logged** and the API token is stored in UserDefaults (plaintext
  in `~/Library/Preferences`; acceptable for v1 — note a future Keychain migration).
- Audit §1.2's `EmulatorSession.active` race is **not** reused for RA; a separate
  `RCClientService.active` global avoids widening it.

---

RA PLAN DONE
