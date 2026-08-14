# GameDock — AGENTS.md

A native macOS (Apple Silicon) **controller-first gaming frontend** — Steam + libretro emulators + Discord in one fullscreen, gamepad-navigable console dashboard. Built with SwiftUI + AppKit + Metal + GameController, with libretro cores embedded via `dlopen` (RetroArch-style architecture, Swift-native shell).

> **Status: v1 in development.** See [Module Status](#module-status) for live checkboxes.
> All builds/tests run headless-verifiable via CLI tools (no Xcode GUI required). See [Build & Test](#build--test).

---

## 1. Project Brief (condensed from `frontend-launcher-prompt.md`)

1. **Home screen**: fullscreen grid/carousel of games from Steam library + scanned ROM folders; recently launched surfaced first.
2. **PS button → quick bar** (DualSense): overlay to jump to Home / Recently Played / Discord / Settings — from anywhere in the app.
3. **Everything inside one fullscreen window** as far as technically possible.
4. **Share button → Discord**: opens real Discord.app in a small floating window; again to dismiss.

### Hard technical constraints (they shape everything)

- **Steam cannot be embedded.** Treat it as a *library source*: parse `steamapps/libraryfolders.vdf` + `appmanifest_*.acf` for installed games; launch via `steam://run/<appid>`. Manage handoff: minimize ourselves → launch Steam → restore on PS button / hotkey.
- **Emulators embed via libretro cores, never shelled-out apps.** Our own Swift libretro frontend: `dlopen` the core dylib, feed ROM, pull frames via the video callback into a Metal `MTKView`. PS5 input routed via the libretro input callback.
  - v1 emulator targets (software-render cores only — see limitation below): **melonDS** (DS), plus any 2D core. **PPSSPP**'s libretro core defaults to HW-render (Vulkan/GL); verify software mode availability before claiming PSP support.
  - 3DS is **out of scope** (Citra is dead; Azahar/Lime3DS libretro maturity unverified).
- **Discord**: never build a chat UI. Launch/focus the real app and resize/position its window via Accessibility (`AXUIElement`). Requires accessibility permission; graceful degradation to plain launch.

## 2. Architecture

```
GameDock/
├── Package.swift                  # SPM package (macOS 14+, arm64)
├── Makefile                       # build / run / test / mock-core / app-bundle
├── build-app.sh                   # assembles GameDock.app from .build/release binary
├── Info.plist                     # app bundle metadata
├── AGENTS.md                      # this file
├── Sources/
│   ├── CLibretro/                 # C shim target (ABI-critical, do not touch layout)
│   │   ├── include/libretro.h     # trimmed but ABI-correct libretro API subset
│   │   └── shim.c                 # @convention(c) trampolines + callback registry
│   └── GameDock/                  # Swift app target
│       ├── GameDockApp.swift      # @main entry, NSApplicationDelegateAdaptor
│       ├── AppDelegate.swift      # fullscreen setup, activation, hotkey monitor
│       ├── AppEnvironment.swift   # root ObservableObject: screens, libraries, launcher
│       ├── Core/                  # Models, Logger, AppPaths (dirs)
│       ├── Libraries/             # Steam (VDF/ACF), ROM folders, recents, artwork
│       ├── Controllers/           # GamepadInput protocol, ControllerManager, HID monitor
│       ├── Launch/                # SteamLauncher, GameLauncher, EmulatorSession
│       │   └── ...                # libretro frontend + Metal renderer + audio
│       ├── Discord/               # AX window float/hide controller
│       └── UI/                    # HomeView, QuickBarView, SettingsView, EmulatorView, Theme
└── Tests/MockCore/mockcore.c      # fake libretro core (test pattern + input) for E2E self-test
```

### Threading model

- **Main thread**: SwiftUI, controller event handling, library scanning, launch orchestration.
- **Core thread** (per emulator session): `retro_run()` loop, frame-paced by `retro_system_timing.fps`.
- **Video handoff**: core thread memcpys frames into a lock-protected slot ring (`FrameSlotRing`) → Metal renderer consumes latest slot in `draw()` → `MTKView`. No cross-thread SwiftUI mutation.
- **Audio**: `AVAudioEngine` source node pulls from a lock-protected ring buffer fed by `retro_audio_sample_batch`.
- **Input**: core thread reads a lock-protected `InputSnapshot` written by `ControllerManager` on main thread.
- **Thread safety rules**: never call `retro_*` from two threads at once; all core calls happen on the core thread except load/unload which happen on a dedicated session lock.

## 3. Module Map (ownership / status)

| Module | Path | Owner role | Status |
|---|---|---|---|
| C ABI shim | `Sources/CLibretro/` | "ABI engineer" | ✅ |
| App shell + fullscreen | `GameDockApp.swift`, `AppDelegate.swift` | "shell engineer" | ✅ |
| Models / paths / logging | `Core/` | "core engineer" | ✅ |
| Steam library (VDF/ACF) | `Libraries/SteamLibrary.swift`, `VDFParser.swift` | "library engineer" | ✅ |
| ROM library scanning | `Libraries/RomLibrary.swift` | "library engineer" | ✅ |
| Recents persistence | `Libraries/RecentsStore.swift` | "library engineer" | ✅ |
| Steam artwork loader | `Libraries/SteamArtLoader.swift` | "library engineer" | ✅ |
| Controller abstraction | `Controllers/GamepadInput.swift` | "input engineer" | ✅ |
| DualSense/GameController manager | `Controllers/ControllerManager.swift` | "input engineer" | ✅ |
| Global HID capture (experimental) | `Controllers/GlobalHIDMonitor.swift` | "input engineer" | ⚠️ experimental |
| Steam launch + handoff | `Launch/SteamLauncher.swift` | "launch engineer" | ✅ |
| Launch orchestrator | `Launch/GameLauncher.swift` | "launch engineer" | ✅ |
| Libretro core loader | `Launch/RetroCore.swift` | "emulator engineer" | ✅ |
| Libretro session (run loop, env) | `Launch/RetroGame.swift`, `RetroEnvironment.swift` | "emulator engineer" | ✅ |
| Metal renderer + MTKView | `Launch/MetalRenderer.swift`, `EmulatorMetalView.swift` | "graphics engineer" | ✅ |
| Emulator audio | `Launch/RetroAudioEngine.swift` | "audio engineer" | ✅ |
| Emulator session orchestrator | `Launch/EmulatorSession.swift` | "emulator engineer" | ✅ |
| Discord float/hide | `Discord/DiscordController.swift` | "integration engineer" | ✅ |
| Home grid UI | `UI/HomeView.swift`, `GameCardView.swift`, `ArtworkView.swift` | "UI engineer" | ✅ |
| Quick bar overlay | `UI/QuickBarView.swift` | "UI engineer" | ✅ |
| Settings UI | `UI/SettingsView.swift` | "UI engineer" | ✅ |
| Navigation model | `UI/NavigationModel.swift` | "UI engineer" | ✅ |
| Theme | `UI/Theme.swift` | "UI engineer" | ✅ |
| E2E self-test (mock core) | `Tests/MockCore/mockcore.c` + `--selftest` flag | "QA engineer" | ✅ |

Status legend: ✅ implemented & compiles · ⚠️ experimental/needs hardware · 🔲 pending

## 4. Build & Test (CLI-only, no Xcode required)

```bash
make build            # swift build -c debug
make run              # build + open GameDock.app
make app              # assemble GameDock.app bundle (ad-hoc signed) into build/
make selftest         # headless E2E: mock core → dlopen → callbacks → frames → audio
make mock-core        # build Tests/MockCore/mockcore.dylib
make clean
```

- **Unit-ish self tests**: `GameDock --selftest` (no GUI): loads mock core, runs 180 frames, asserts video/audio/input plumbing, prints `SELFTEST PASS/FAIL`.
- **Steam scanner**: run `GameDock --scan-steam` to dump the parsed library (validated against the real Steam install on this machine).
- Open in Xcode (optional): `open Package.swift` — Xcode treats SPM packages natively; run the `GameDock` scheme.

## 5. Key technical notes / landmines

- **libretro.h**: trimmed to the subset we use (software-render path). Struct layouts and command enums are ABI-critical and match the canonical header. Do NOT "modernize" types (e.g. `bool` is 1 byte; keep `Int32`-equivalent C types).
- **`@convention(c)` callbacks cannot capture**; the C shim stores a `context` pointer + Swift function pointers. Swift registers non-capturing closures that read `EmulatorSession.active`.
- **HW-render cores (Vulkan/GL) are NOT supported in v1** — we implement `RETRO_ENVIRONMENT_SET_HW_RENDER` by returning `false` (graceful). PPSSPP may need its software renderer verified; melonDS 2D path is the safe proof-of-concept. Documented in `RetroEnvironment.swift`.
- **PS button**: exposed in-app via GameController (`buttonMenu` on DualSense extended pad). System-wide capture while *Steam* has focus needs IOHIDManager-level access → `GlobalHIDMonitor` (experimental, default-off). The reliable v1 handoff is: in-app PS button + global keyboard hotkey (`Cmd+Shift+Home`, via CGEventTap) that restores GameDock.
- **Share button**: DualSense share may not be individually exposed by GameController on macOS — `ControllerManager` probes `physicalInputProfile` by name ("Share"/"Create"), falls back to `buttonOptions`, and always provides the QuickBar→Discord path. Logs actual button inventory at connect time (see `--diagnose-input`).
- **Discord bundle id**: `com.hnc.Discord`. AX resize requires `AXIsProcessTrusted`; if not trusted, degrade to plain launch + log.
- **Steam**: parse both default library folder and `libraryfolders.vdf` extra mount points. Grid art: local `userdata/<id>/config/grid/<appid>p.png` first, then Steam CDN `header.jpg`. Offline-safe fallback: generated placeholder.
- **Persistence**: recents JSON + settings in `~/Library/Application Support/GameDock/`; ROM folder config in `UserDefaults` (suite `com.gamedock.GameDock`).

## 6. Known limitations (v1, by design)

- No 3DS. No Windows/Linux/Intel. No custom Discord UI. No cloud sync/profiles.
- No HW-render libretro cores yet (no Vulkan/GL bridge).
- Global PS-button capture while another app has focus = experimental.
- Steam game-exit detection is polling-based (`NSWorkspace` frontmost-app observation + process checks); not signal-perfect.

## 7. Git workflow

Commit after every milestone (library scan → input layer → UI → launchers → emulator path → integration). Message style: `feat(module): what`. `main` is the only branch; never commit broken builds (`make build` must pass first).

## 8. Definition of Done (v1)

- [ ] `make build` clean; `make selftest` passes (mock core E2E).
- [ ] Home grid renders from real Steam scan + configured ROM folder; full controller/keyboard navigation.
- [ ] PS button quick bar, Share/Discord toggle, Settings ROM paths.
- [ ] Steam handoff (minimize → `steam://run` → restore).
- [ ] At least one emulator title runs in-app via embedded libretro core (melonDS software path as PoC; PPSSPP pending software-mode verification).
