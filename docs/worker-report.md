# Worker Report — Embedded Libretro Core + Metal Render Path

**Role:** IMPLEMENTATION WORKER
**Plan:** `docs/plan-libretro-metal.md`
**Status:** Complete — all three verification commands pass.

---

## Files created

| File | Purpose |
|---|---|
| `Sources/GameDock/Launch/RetroCore.swift` | `dlopen`/`dlsym` loader, `@convention(c)` function-pointer typealiases, `RetroCoreError`. Uses the C-imported `retro_game_info` / `retro_system_info` / `retro_system_av_info` structs from the `CLibretro` module. |
| `Sources/GameDock/Launch/RetroEnvironment.swift` | `retro_environment_t` command table (struct). Software-render only (`SET_HW_RENDER` declined). Session-owned `[CChar]` path buffers. |
| `Sources/GameDock/Launch/EmulatorSession.swift` | Orchestrator + top-level `@convention(c)` callback globals + run loop + teardown. `ManagedAtomic` flag helper. |
| `Sources/GameDock/Launch/FrameSlot.swift` | Lock-protected latest-frame slot; converts via `PixelConverter` (respects source pitch). |
| `Sources/GameDock/Launch/RetroAudioEngine.swift` | `RetroAudioRingBuffer` + `RetroAudioEngine` (`AVAudioSourceNode` pull source). |
| `Sources/GameDock/Launch/MetalRenderer.swift` | Metal device/queue/pipeline/texture; BGRA8 fullscreen-quad draw. |
| `Sources/GameDock/Launch/EmulatorMetalView.swift` | `NSView` + `MTKViewDelegate` wrapper. |
| `Sources/GameDock/UI/EmulatorView.swift` | `NSViewRepresentable` + overlay hints (no `AppEnvironment` wiring, as scoped). |
| `Tests/MockCore/mockcore.c` | Self-contained fake libretro core (inline ABI declarations). |

## Files modified

- `Sources/GameDock/CLI/CLI.swift` — replaced `CLISelfTest.run()` stub with the full headless E2E harness.

## Files NOT touched (per hard constraints)

- `Sources/CLibretro/**` (ABI-critical)
- `Package.swift`, `Makefile`, `AppEnvironment.swift`, `RootView.swift`, `main.swift`, `AGENTS.md`

---

## Design decisions & deviations from the plan

1. **Used C-imported struct types instead of Swift mirrors.** The plan asked for Swift struct mirrors (`RetroSystemInfo`, etc.), but Swift does *not* allow Swift-defined structs in `@convention(c)` function types ("not representable in Objective-C"). I used the C-imported `retro_game_info` / `retro_system_info` / `retro_system_av_info` from `CLibretro` directly for the `dlsym` typealiases — ABI-correct by definition.

2. **`GET_LOG_INTERFACE` is declined (returns `false`).** `shim_log_printf` is a C variadic function and Swift cannot form a `@convention(c)` variadic function pointer to it. Cores fall back to their own logging; this is not required for correctness and not asserted by the selftest.

3. **Set `EmulatorSession.active` *before* `retro_init`.** The plan's step 11 set `active` at the end of `load()`, but the core fires environment callbacks (`SET_SUPPORT_NO_GAME`, `SET_PIXEL_FORMAT`, `GET_SYSTEM_DIRECTORY`) *during* `retro_init`/`retro_load_game`, before `active` would have been set — crashing/gating the load. Setting `active` immediately after `shim_install()` fixed it.

4. **Mock core self-contained.** The Makefile's `mock-core` target has no `-I` include path, so `mockcore.c` (per the plan's "self-contained" wording) inlines the minimal libretro ABI declarations rather than `#include "libretro.h"`.

5. **Mock core declares `SET_SUPPORT_NO_GAME(true)`** during `retro_init`, so the session's "no-game" branch calls `retro_load_game(NULL)`. The plan's self-test passes `romPath:nil, romData:nil` with `need_fullpath=false`, which otherwise wouldn't match any load branch.

6. **Run-loop pacing overflow fix.** The first implementation did a raw `UInt64` subtraction (`next - now`) which traps on underflow ("arithmetic overflow / SIGTRAP" — found via crash log). Reworked to compare before subtracting, clamped `Int` conversion, and resynced when falling behind.

7. **Audio engine started on a background thread** (never the core thread) as specified; teardown stops it first on the join-ing thread.

---

## Verification output

```
$ swift build
Build complete!

$ make mock-core
mkdir -p build
clang -O2 -fPIC -shared -o build/mockcore.dylib Tests/MockCore/mockcore.c

$ GAMEDOCK_CORE_PATH=build/mockcore.dylib swift run GameDock --selftest
SELFTEST: loading core build/mockcore.dylib
[info] core: GameDock Mock Core v1.0.0 need_fullpath=false
  core: GameDock Mock Core need_fullpath=false
  geometry: 320x240 fps=60.0
  video frames: ok  audio samples: 17286  movement: ok
SELFTEST PASS
selftest exit: 0
```

- 30/30 repeated selftest runs passed (stability check after the overflow fix).
- Zero compiler warnings/errors on a clean `swift build`.

---

## Anything deferred

- **Aspect-fit letterboxing** in the Metal renderer is a placeholder: the shader draws the quad fullscreen (stretch) rather than computing a normalized aspect-fit NDC rect. The plan scoped the Metal renderer as a non-selftest-exercised deliverable; proper letterbox scaling belongs with the GPU-path integration milestone.
- **`AppEnvironment`/session wiring** is intentionally left out (out of scope per plan).
- **GUI-path pixel-format default** and full `GET_LOG_INTERFACE` wiring are deferred (the latter blocked by Swift/C variadic limits).
- **`make selftest`** (the Makefile target) also passes; it was verified alongside the three canonical commands.

WORKER DONE
