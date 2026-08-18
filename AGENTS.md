# Leblanc — AGENTS.md

A native macOS (Apple Silicon) **controller-first gaming frontend** — Steam + libretro emulators + Discord in one fullscreen, gamepad-navigable console dashboard. Built with SwiftUI + AppKit + Metal + GameController, with libretro cores embedded via `dlopen` (RetroArch-style architecture, Swift-native shell).

> **Status: v1 in development.** See [Module Status](#module-status) for live checkboxes.
> All builds/tests run headless-verifiable via CLI tools (no Xcode GUI required). See [Build & Test](#build--test).

> **Naming**: product name is **Leblanc** (executable, `.app`); project codename
> is **GameDock** (repo dir, bundle id `com.gamedock.GameDock`, UserDefaults
> suite). The split is intentional — do NOT rename the bundle id (it would
> orphan Keychain/UserDefaults persistence).

> **Agent skills**: `.pi/skills/` (leblanc-build-verify, leblanc-architecture,
> leblanc-controller-input, leblanc-libretro-cores) — load before feature work.

---

## 1. Project Brief (condensed from `frontend-launcher-prompt.md`)

1. **Home screen**: fullscreen grid/carousel of games from Steam library + scanned ROM folders; recently launched surfaced first.
2. **PS button → quick bar** (DualSense): overlay to jump to Home / Recently Played / Discord / Settings — from anywhere in the app.
3. **Everything inside one fullscreen window** as far as technically possible.
4. **Share button → Discord**: embeds the real discord.com/app in a small floating window (WKWebView, read-only); again to dismiss.

### Hard technical constraints (they shape everything)

- **Steam cannot be embedded.** Treat it as a *library source*: parse `steamapps/libraryfolders.vdf` + `appmanifest_*.acf` for installed games; launch via `steam://run/<appid>`. Manage handoff: minimize ourselves → launch Steam → restore on PS button / hotkey.
- **Emulators embed via libretro cores, never shelled-out apps.** Our own Swift libretro frontend: `dlopen` the core dylib, feed ROM, pull frames via the video callback into a Metal `MTKView`. PS5 input routed via the libretro input callback.
  - v1 emulator targets (software-render cores only — see limitation below): **melonDS** (DS), plus any 2D core. **PPSSPP**'s libretro core defaults to HW-render (Vulkan/GL); verify software mode availability before claiming PSP support.
  - 3DS is **out of scope** (Citra is dead; Azahar/Lime3DS libretro maturity unverified).
- **Discord**: never build a chat UI. Embed the real `discord.com/app` in a small floating WKWebView — a read-only wrapper (compose/emoji/gift controls hidden via stable aria-role CSS/JS; no token handling, ToS-compliant like a browser tab). Mic/camera usage strings are declared in `Info.plist`.

## 2. Architecture

```
GameDock/
├── Package.swift                  # SPM package (macOS 14+, arm64)
├── Makefile                       # build / run / test / mock-core / app-bundle
├── build-app.sh                   # assembles Leblanc.app from .build binary
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
│       ├── Launch/                # SteamLauncher, StandaloneEmulatorLauncher, EmulatorSession
│       │   └── ...                # libretro frontend + Metal renderer + audio
│       ├── Discord/               # WKWebView wrapper (read-only discord.com/app)
│       └── UI/                    # XMBView, QuickBarView, SettingsNavModel, EmulatorView, Theme
└── Tests/MockCore/mockcore.c      # fake libretro core (test pattern + input) for E2E self-test
```

### Threading model

- **Main thread**: SwiftUI, controller event handling, library scanning, launch orchestration.
- **Core thread** (per emulator session): `retro_run()` loop, frame-paced by `retro_system_timing.fps`.
- **Video handoff**: core thread memcpys frames into a lock-protected slot (`FrameSlot`) → Metal renderer consumes the latest slot in `draw()` → `MTKView`. No cross-thread SwiftUI mutation.
- **Audio**: `AVAudioEngine` source node pulls from a lock-protected ring buffer fed by `retro_audio_sample_batch`.
- **Input**: core thread reads a lock-protected `InputSnapshot` written by `ControllerManager` on main thread.
- **Thread safety rules**: never call `retro_*` from two threads at once; all core calls happen on the core thread except load/unload which happen on a dedicated session lock.

## 3. Module Map (ownership / status)

| Module | Path | Owner role | Status |
|---|---|---|---|
| C ABI shim | `Sources/CLibretro/` | "ABI engineer" | ✅ |
| App shell + fullscreen | `GameDockApp.swift`, `AppDelegate.swift` | "shell engineer" | ✅ |
| Models / paths / logging | `Core/` | "core engineer" | ✅ |
| Playtime formatter | `Core/PlaytimeFormatter.swift` | "core engineer" | ✅ |
| Steam library (VDF/ACF) | `Libraries/SteamLibrary.swift`, `VDFParser.swift` | "library engineer" | ✅ |
| ROM library scanning | `Libraries/RomLibrary.swift` | "library engineer" | ✅ |
| Recents persistence | `Libraries/RecentsStore.swift` | "library engineer" | ✅ |
| Steam artwork loader | `Libraries/ArtworkLoader.swift` | "library engineer" | ✅ |
| Steam screenshot store | `Libraries/SteamScreenshotStore.swift` | "library engineer" | ✅ |
| Steam localconfig playtime | `Libraries/SteamLocalConfigReader.swift` | "library engineer" | ✅ |
| Personal captures | `Libraries/CaptureStore.swift` | "library engineer" | ✅ |
| Controller abstraction | `Controllers/GamepadInput.swift` | "input engineer" | ✅ |
| DualSense/GameController manager | `Controllers/ControllerManager.swift` | "input engineer" | ✅ |
| Hold-to-repeat (RepeatPacer) | `Controllers/ControllerManager.swift` | "input engineer" | ✅ |
| Global HID capture (experimental) | `Controllers/GlobalHIDMonitor.swift` | "input engineer" | ⚠️ experimental |
| Steam launch + handoff | `Launch/SteamLauncher.swift` | "launch engineer" | ✅ |
| Launch orchestrator | `AppEnvironment.swift` (`launch(_:)`) | "launch engineer" | ✅ |
| Libretro core loader | `Launch/RetroCore.swift` | "emulator engineer" | ✅ |
| Libretro session (run loop, env) | `Launch/EmulatorSession.swift`, `RetroEnvironment.swift` | "emulator engineer" | ✅ |
| Metal renderer + MTKView | `Launch/MetalRenderer.swift`, `EmulatorMetalView.swift` | "graphics engineer" | ✅ |
| Emulator audio | `Launch/RetroAudioEngine.swift` | "audio engineer" | ✅ |
| Emulator session orchestrator | `Launch/EmulatorSession.swift` | "emulator engineer" | ✅ |
| Discord float/hide | `Discord/DiscordController.swift` | "integration engineer" | ✅ |
| XMB shell | `UI/XMBView.swift`, `XMBNavModel.swift`, `ArtworkView.swift` | "UI engineer" | ✅ |
| Selection preview panel | `UI/SelectionPreviewPanel.swift`, `SelectionPreviewModel.swift` | "UI engineer" | ✅ |
| Capture toast | `UI/RootView.swift` (`CaptureToastView`) | "UI engineer" | ✅ |
| Quick bar overlay | `UI/QuickBarView.swift` | "UI engineer" | ✅ |
| Settings rows | `UI/SettingsNavModel.swift` | "UI engineer" | ✅ |
| Navigation model | `AppEnvironment.swift` (`gamepad(_:)` router) | "UI engineer" | ✅ |
| Theme | `UI/Theme.swift` | "UI engineer" | ✅ |
| E2E self-test (mock core) | `Tests/MockCore/mockcore.c` + `--selftest` | "QA engineer" | ✅ |
| Preview check CLI | `CLI/CLIPreviewCheck.swift` | "QA engineer" | ✅ |

Status legend: ✅ implemented & compiles · ⚠️ experimental/needs hardware · 🔲 pending

## 4. Build & Test (CLI-only, no Xcode required)

```bash
make build            # swift build -c debug
make run              # build + open Leblanc.app
make app              # assemble Leblanc.app bundle (ad-hoc signed) into build/
make selftest         # headless E2E: mock core → dlopen → callbacks → frames → audio
make test             # pure-logic unit assertions (VDFParser / RomTitle / PixelConverter / ids)
make mock-core        # build Tests/MockCore/mockcore.dylib
make clean
```

- **Unit-ish self tests**: `GameDock --selftest` (no GUI): loads mock core, runs 180 frames, asserts video/audio/input plumbing, prints `SELFTEST PASS/FAIL`.
- **Unit assertions**: `GameDock --unit-test` (`make test`): pure-logic batteries (VDFParser, RomTitle, PixelConverter, entry ids, PlaytimeFormatter, SteamLocalConfigReader, SteamScreenshotStore). CLT-only machine has no XCTest/swift-testing, so these run via a CLI harness rather than `swift test` — migrate to a real test target if Xcode is ever available.
- **Steam scanner**: run `GameDock --scan-steam` to dump the parsed library (validated against the real Steam install on this machine).
- **Preview check**: run `GameDock --preview-check <appid> [title]` to verify the selection preview data plumbing (localconfig playtime + storefront screenshots + personal captures).
- Open in Xcode (optional): `open Package.swift` — Xcode treats SPM packages natively; run the `GameDock` scheme.

## 5. Key technical notes / landmines

- **libretro.h**: trimmed to the subset we use (software-render path). Struct layouts and command enums are ABI-critical and match the canonical header. Do NOT "modernize" types (e.g. `bool` is 1 byte; keep `Int32`-equivalent C types).
- **`@convention(c)` callbacks cannot capture**; the C shim stores a `context` pointer + Swift function pointers. Swift registers non-capturing closures that read `EmulatorSession.active`.
- **HW-render cores**: OpenGL + OpenGL Core contexts are hosted via `GLHardwareBridge` (FBO → `glReadPixels` readback into the Metal pipeline); Vulkan/D3D are declined (`SET_HW_RENDER` returns false for them). The embedded libretro path serves DS (melonDS) and other software/GL cores; **PSP runs via the user's standalone PPSSPPSDL.app handoff** (its libretro macOS GL path renders black).
- **PS button**: exposed in-app via GameController (`GCInputButtonHome`, system
  gesture disabled per-controller). System-wide capture while another app has
  focus was unreliable on macOS 14/15 (Apple DTS confirmed the IOHIDManager
  global-input bug) and is **re-enabled as an experiment on macOS 27 beta**
  (`GlobalHIDMonitor`, may require Input Monitoring permission — see
  `docs/ps-button-report.md`). The always-available cross-process restore is
  the global keyboard hotkey **`Cmd+Shift+Home`** (Carbon `RegisterEventHotKey`
  — no permission needed).
- **Share button**: DualSense share may not be individually exposed by GameController on macOS — `ControllerManager` probes `physicalInputProfile` by name ("Share"/"Create"), falls back to `buttonOptions`, and always provides the QuickBar→Discord path. Logs actual button inventory at connect time (see `--diagnose-input`).
- **Discord**: embedded WKWebView (`Discord/DiscordController.swift`) loading `discord.com/app` with `.default()` data store (login survives relaunch); read-only enforced structurally (no text input) + compose controls hidden via stable aria-role selectors.
- **Steam**: parse both default library folder and `libraryfolders.vdf` extra mount points. Grid art: local `userdata/<id>/config/grid/<appid>p.png` first, then Steam CDN `header.jpg`. Offline-safe fallback: generated placeholder.
- **Persistence**: recents JSON + settings in `~/Library/Application Support/GameDock/`; ROM folder config in `UserDefaults` (suite `com.gamedock.GameDock`). Steam screenshot cache in `preview-cache/steam-screenshots/`.
- **Hold-to-repeat**: d-pad, L1/R1, and sticks auto-repeat after 0.4 s hold at 12/s via `RepeatPacer` (Timer, main RunLoop, `.common` mode). Confirm/back stay edge-triggered.
- **Selection preview panel**: debounced 350 ms; Steam screenshots from storefront API (cached 1-week TTL); PSP/DS captures from `~/Pictures/Leblanc Captures/`; playtime from `localconfig.vdf` (Steam) or `RecentsStore` (emulator). See `leblanc-preview-panel` skill.

## 6. Known limitations (v1, by design)

- No 3DS. No Windows/Linux/Intel. No custom Discord UI. No cloud sync/profiles.
- **PPSSPP runs via the user's own standalone install** (PPSSPPSDL.app in
  ~/Downloads/ROMS), Steam-style handoff — NOT the libretro core (whose macOS
  GL path renders black) and NOT RetroArch. The embedded libretro path serves
  software-render cores (DS via melonDS, mock core self-test).
- Global PS-button capture while another app has focus was unreliable on
  macOS 14/15 (Apple DTS); **re-enabled as an experiment on macOS 27 beta** —
  check Console for `GlobalHIDMonitor` logs; Cmd+Shift+Home remains the
  fallback (details in `docs/ps-button-report.md`).
- Game handoff hides Leblanc via `NSApp.hide` (never terminate, never
  orderOut-from-fullscreen — see AppDelegate.hideFrontend). Restore-on-exit is
  event-based: `Process.terminationHandler` for PPSSPP,
  `NSWorkspace.didTerminateApplication` for Steam; the Cmd+Shift+Home hotkey
  restores manually while a game is still running.

## 7. Git workflow

Commit after every milestone (library scan → input layer → UI → launchers → emulator path → integration). Message style: `feat(module): what`. `main` is the only branch; never commit broken builds (`make build` must pass first).

## 8. Definition of Done (v1)

- [x] `make build` clean; `make selftest` passes (mock core E2E: dlopen → callbacks → frames → audio → input).
- [x] Home grid renders from real Steam scan + configured ROM folder; full controller/keyboard navigation.
- [x] PS button quick bar, Share/Discord toggle, Settings ROM paths.
- [x] Steam handoff (minimize → `steam://run` → restore).
- [x] Embedded libretro core render path (melondS/2D software cores; PPSSPP pending software-mode verification).
- [x] Selection preview panel: debounced rotating screenshots (Steam) / personal captures (PSP/DS) + playtime, ink panel to the right of the selected item.
- [x] Hold-to-repeat navigation: d-pad, sticks, and L1/R1 auto-repeat while held.
- [x] Screenshot capture confirmation toast.
- [x] Category rail item counts (Home/Steam/PSP/DS).
- [x] XMB header clock + emulator touchpad-capture hint.

## 9. Sub-agent workflow (pi SDK)

Role-specific agent sessions (scout → planner → worker) are orchestrated via
`node Scripts/subagents/orchestrate.mjs <role>` using the configured models
from `~/.pi/agent/settings.json`. Each role writes its deliverable to `docs/`
and respects read-only vs. write scope:

- **scout** (read-only): recon + report, e.g. `docs/scout-steam-report.md` (Steam VDF).
- **planner** (read-only): design + plan, e.g. `docs/plan-libretro-metal.md`.
- **worker** (write): implements the plan; must run the verification commands
  itself; writes `docs/worker-report.md`.

The orchestrator streams output, verifies the deliverable file exists, and
exits non-zero on failure. A human gatekeeper reviews the diff before commit
(audited fixes to worker output: `GET_LOG_INTERFACE` via `shim_get_log_printf`,
`GET_CAN_DUPE` bool-size write, analog input routing, env strings before
`retro_init`, letterboxed quad).
