---
name: leblanc-libretro-cores
description: Embedding libretro cores in Leblanc (melonDS for DS, mock core for tests) — EmulatorSession lifecycle, the retro_environment command table, the GL hardware-render bridge, and audio/video/input plumbing. Use when adding a core, fixing emulation, or extending the libretro surface.
---

# Leblanc — Libretro Cores

Frontend: `Sources/GameDock/Launch/` (RetroCore → EmulatorSession →
RetroEnvironment) + `Sources/CLibretro/` (C shim, ABI-critical).

## Lifecycle contract (EmulatorSession)

1. `load()` (main thread today): `dlopen` → `shim_set_callbacks` →
   `shim_install` → `retro_init` → `retro_get_system_info/av_info` →
   `retro_load_game` → re-query av_info → optional RetroAchievements start.
2. `start()`: spawns the **core thread** (named `GameDock.Core`) running
   `retro_run()` paced to `av_info.timing.fps`; audio engine starts on a
   background queue.
3. `requestStop()`: sets the stop flag, **joins the core thread with a 2 s
   timeout**. On timeout it marks `coreThreadStuck` and teardown then LEAKS the
   core (skips `dlclose`/GL teardown) rather than unmap under a live thread.
4. `teardown()`: audio stop → RA destroy → GL context_destroy → `retro_unload_game`
   → `retro_deinit` → `dlclose` **last**.

Only one session is active process-wide; the C trampolines route through
`EmulatorSession.active` (NSLock). Callbacks are non-capturing `@convention(c)`
globals.

## retro_environment table (RetroEnvironment.swift)

- Implemented: GET_CAN_DUPE, SET_MESSAGE, SHUTDOWN, GET_SYSTEM_DIRECTORY,
  GET_SAVE_DIRECTORY, GET_LIBRETRO_PATH, SET_PIXEL_FORMAT,
  SET_SUPPORT_NO_GAME, GET_LOG_INTERFACE, SET_GEOMETRY, GET_AUDIO_VIDEO_ENABLE,
  GET_FASTFORWARDING, GET_TARGET_REFRESH_RATE, GET_INPUT_BITMASKS,
  GET_PREFERRED_HW_RENDER, GET_MESSAGE_INTERFACE_VERSION, GET_INPUT_MAX_USERS,
  GET_SAVESTATE_CONTEXT, GET_JIT_CAPABLE, and the **core-options family**
  (GET_VARIABLE / SET_VARIABLES / SET_VARIABLE / GET_VARIABLE_UPDATE — see
  below).
- **Declined (return false)**: GET_HW_RENDER_INTERFACE,
  GET_CURRENT_SOFTWARE_FRAMEBUFFER, context negotiation, and
  GET_VARIABLE_UPDATE_VERSION (the v2 options interface is future work;
  melonDS/PPSSPP use v1).
- SET_HW_RENDER is intercepted by the session (`handleHWRenderRequest`) — only
  `RETRO_HW_CONTEXT_OPENGL`/`OPENGL_CORE` are accepted; Vulkan/D3D are declined.

### Core options (classic v1 retro_variable)

- `CoreOptionsModel` (`Launch/CoreOptionsModel.swift`) is the single source of
  truth: definitions ingested from SET_VARIABLES, values lock-guarded (env
  handlers run on the core thread during run; UI writes on main), `@Published`
  state mutated on main only. `CoreOptionParser` splits `"Title; opt1|opt2"`
  (pure, unit-tested).
- **Persistence is per game**: `coreOptions[coreID][gameID][optionKey]` in
  SettingsStore (`coreID` = source rawValue, `gameID` = the stable
  `GameEntry.id`). A game with no saved overrides starts from the core's
  defaults (first token) — never another game's values.
- UI: PS → Quick Bar → **Options** (emulation is paused while the overlay is
  open). ◀▶ cycles a value and applies it live (sets the model's changed flag →
  the core picks it up via GET_VARIABLE_UPDATE); CIRCLE/PS closes; there is no
  separate confirm step. A per-game "Reset to defaults" is a planned follow-up
  (`SettingsStore.clearCoreOptions` already exists).
- GET_VARIABLE answers come from **stable per-key C buffers** owned by the
  model (content rewritten in place on change; freed only in deinit) — the
  classic RetroArch pattern; cores read the pointer immediately after the env
  call returns.

### Landmines in env handlers

- `GET_CAN_DUPE` writes a Swift `Bool` (1 byte) into `data` — writing a 4-byte
  UInt32 there corrupts adjacent memory.
- Environment **string pointers must be stable before `retro_init`** (cores
  query dirs during init/load); the session owns the `[CChar]` buffers.
- `GET_PREFERRED_HW_RENDER` returns `RETRO_HW_CONTEXT_OPENGL_CORE` (3).

## GL hardware-render bridge (PPSSPP-class cores)

`GLHardwareBridge` hosts an NSOpenGLContext + FBO on the core thread. The core
renders into the FBO; after `retro_run` the frontend `glReadPixels` (BGRA,
vertical flip) into a CPU buffer → `FrameSlot` → Metal. Key quirks:

- **`context_reset` must be DEFERRED** to just before the first `retro_run` —
  calling it inside the SET_HW_RENDER handler segfaults PPSSPP (its context
  object finalizes after `load_game` returns).
- FBO size is seeded from the render target (PPSSPP never announces its own
  size via SET_GEOMETRY; av_info stays 0×0), so a 480×272 seed is used.
- `get_current_framebuffer` returns the FBO handle; `get_proc_address` resolves
  real GL symbols via `dlsym(RTLD_DEFAULT, -2)` + `CGLGetProcAddress` (a no-op
  stub corrupts return values and crashes cores).

## Audio

`RetroAudioRingBuffer` (interleaved Int16, NSLock, drop-oldest on overflow,
zero-fill on underflow) fed by `retro_audio_sample(_batch)`; `RetroAudioEngine`
pulls it via `AVAudioSourceNode`. Start/stop are serialized on a lifecycle
queue (start runs on a background queue; stop on main).

## Input

`retro_input_poll` is a no-op; `retro_input_state` reads `InputSnapshot`
(RETRO_DEVICE_JOYPAD ids 0-15, RETRO_DEVICE_ANALOG via `readAnalog`).
`retro_set_controller_port_device(0, RETRO_DEVICE_JOYPAD)` is set after load.

## RetroAchievements integration

`RCClientService` owns the rcheevos `rc_client_t`: memory regions cached from
`retro_get_memory_data/size`, console address map from
`rc_console_memory_regions`, `doFrame()` pumps per frame on the core thread,
server calls fan out through URLSession and responses are marshaled back on the
core thread. `rc_client_set_allow_background_memory_reads(0)` keeps reads
inside `do_frame`. RA toasts surface via `RAToastModel` (thread-safe).

## Pitfalls checklist

- Never call `retro_*` from two threads at once.
- Never `dlclose` while the core thread might still run (see `coreThreadStuck`).
- `RetroCore.load()` uses `RTLD_NOW | RTLD_GLOBAL` — see
  `leblanc-architecture` invariant #2 (one core at a time).
- New cores: verify headlessly first with `--probe-core <core.dylib> <rom>`,
  then add the DS/PSP path in `AppEnvironment+Launch.swift` + `CoreLocator`.
- After any change: `make test && make selftest` (see `leblanc-build-verify`).
