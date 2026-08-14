# RA Worker Report — RetroAchievements Integration

## Summary

Wired the vendored `CRcheevos` (rcheevos v12.4.0) into the libretro emulator
path per `docs/plan-retroachievements.md`. The Swift wrapper `RCClientService`
owns a single `rc_client_t`, with three non-capturing `@convention(c)`
trampolines (read-memory, server-call transport, event handler) routed through
a dedicated `RCClientService.active` static pointer (it does **not** reuse
`EmulatorSession.active`, avoiding the §1.2 race). No changes were made to
`Sources/CLibretro/**` or `Package.swift`.

## Key plan corrections confirmed at build time

1. **Module name** — the vendored `module.modulemap` declares `module
   rcheevos`, not `CRcheevos`. Swift code uses `import rcheevos` (the plan's
   `import CRcheevos` does not compile). All other `rc_*` symbols resolve
   against the real binary with no header edits.

2. **Console IDs** — verified from `rc_consoles.h`:
   - `RC_CONSOLE_NINTENDO_DS = 18`
   - `RC_CONSOLE_PSP = 41`

3. **Identify is compiled out** — `nm` on the built binary confirms
   `rc_client_begin_identify_and_load_game` is absent while `rc_client_create`,
   `rc_client_begin_login_with_token`, `rc_client_begin_load_game`, and the
   full `rc_hash_*` family are present. Implemented **Path A** (local
   `rc_hash_generate` + `rc_client_begin_load_game`).

## Files created

| File | Purpose |
|---|---|
| `Sources/GameDock/RetroAchievements/RCClientService.swift` | Client owner: create/destroy, login/load, `doFrame`, read-memory region mapping, URLSession server transport + pending-callback drain, event→toast |
| `Sources/GameDock/RetroAchievements/RAConsole.swift` | `GameSource → rc_console id` (DS=18, PSP=41) |
| `Sources/GameDock/RetroAchievements/RAHash.swift` | Local `rc_hash_generate` wrapper (Path A) |
| `Sources/GameDock/RetroAchievements/RAToastModel.swift` | `ObservableObject` toast queue with auto-dismiss |
| `Sources/GameDock/CLI/CLIRASelfTest.swift` | `--ra-selftest` headless smoke test (fake read/server callbacks) |

## Files modified

| File | Change |
|---|---|
| `Sources/GameDock/Launch/EmulatorSession.swift` | Added `rcService`, owned `raToasts`, optional `raConsoleID`/`raSettings` init params; `startRetroAchievements()` in `load()`; `rcService.doFrame()` in `runLoop()`; unload/destroy in `teardown()` |
| `Sources/GameDock/AppEnvironment.swift` | Passes `raConsoleID` + settings into session; RA settings actions + `promptForRAUsername()` (NSAlert) |
| `Sources/GameDock/Libraries/SettingsStore.swift` | `raUsername`/`raAPIToken`/`raHardcore`/`raUnofficial` + accessors + `raConfigured` |
| `Sources/GameDock/UI/SettingsNavModel.swift` | Three RA rows (sign-in, hardcore, unofficial) |
| `Sources/GameDock/UI/EmulatorScreen.swift` | Achievement toast pill (observes `RAToastModel`) |
| `Sources/GameDock/UI/RootView.swift` | Passes `session.raToasts` to `EmulatorScreen` |
| `Sources/GameDock/CLI/CLI.swift` → `main.swift` | `--ra-selftest` dispatch |
| `Sources/GameDock/Core/Logger.swift` | Added `--ra-selftest` to `isCLIMode` |

`Package.swift` and `Sources/CLibretro/**` were **not** modified.

## Architecture details

### Server-call transport (Design A)

`rc_client`'s `server_call` builds the full `rc_api_request_t` (URL +
`post_data` + `content_type`) for every endpoint; the Swift transport treats all
requests identically. The non-capturing `ra_server_call` trampoline snapshots
the request strings into Swift `String`s, dispatchs an async URLSession POST/GET
on a utility queue, and enqueues a `Pending` (callback + `callback_data` +
response body + HTTP status) under an `NSLock`. `doFrame()` (core thread, after
`retro_run`) drains the queue and invokes each stored `rc_client_server_callback_t`
on the core thread — the only safe thread for `rc_client` re-entrancy.

### Read memory mapping

`cacheRegions(from:)` snapshots libretro `retro_get_memory_data`/`size` base
pointers once per session. Runtime reads serve `RETRO_MEMORY_SYSTEM_RAM` (2)
first, then SAVE_RAM (0) → RTC (1) → VIDEO_RAM (3), mapping native address 0 to
region base (melonDS exposes main RAM canonically). Partial reads are returned
on region-boundary overrun, which rcheevos tolerates.

### Frame loop + events

`rc_client_do_frame`/`rc_client_idle` run once per frame on the core thread.
The event handler copies C strings immediately and dispatches to main to push a
toast (achievement / game-completed / server-error / reset / hardcore status).

## Selftest output

```
$ swift run GameDock --ra-selftest
RA SELFTEST: constructing rc_client with fake callbacks
RA SELFTEST: server calls=1 loginObserved=true loadState=0
RA SELFTEST PASS

$ swift run GameDock --selftest
SELFTEST: loading core build/mockcore.dylib
  core: GameDock Mock Core need_fullpath=false
  geometry: 320x240 fps=60.0
  video frames: ok  audio samples: 50096  movement: ok
SELFTEST PASS
```

`make build` is clean (no warnings/errors after the initial cleanup).

## Notes / deferred

- **API token only** — `begin_login_with_token` is the sole auth path; no
  plaintext passwords are persisted (per plan §6).
- **Hardcore reset** — `RC_CLIENT_EVENT_RESET` currently surfaces a status toast;
  calling `core.retroReset()` + `rc_client_reset()` is deferred until core reset
  is exercised (per plan §9 step 6).
- **Badge art / rich presence / summary pill** — not implemented (optional;
  plan §5.3 marks them non-required for RA correctness).
- **Keychain** — API token stored in UserDefaults plaintext, noted for a future
  migration.

RA WORKER DONE
