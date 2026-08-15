---
name: leblanc-architecture
description: Codebase map and hard invariants for the Leblanc (GameDock) macOS controller-first gaming frontend. Read before any feature work to understand module boundaries, the threading model, and the constraints that shape every change.
---

# Leblanc — Architecture

SwiftUI shell + AppKit + Metal + GameController, with libretro cores embedded
via `dlopen` (RetroArch-style). Product name **Leblanc**, project codename
**GameDock** (bundle id `com.gamedock.GameDock`, UserDefaults suite
`com.gamedock.GameDock`) — the dual naming is intentional; do not rename the
bundle id (it would orphan Keychain/UserDefaults persistence).

## Module map (Sources/)

| Path | Owns |
|---|---|
| `GameDockApp.swift`, `AppDelegate.swift` | @main, fullscreen window, activation, Cmd+Shift+Home global hotkey (Carbon `RegisterEventHotKey`) |
| `AppEnvironment.swift` | root ObservableObject: screen state, XMB/quick-bar state, **input router** (`gamepad(_:)`) |
| `AppEnvironment+Launch.swift` | game launch orchestration (Steam/PPSSPP/embedded core), keep-awake, screenshots |
| `AppEnvironment+Settings.swift` | settings row actions + file/alert panels |
| `Core/` | Models, Logger, AppPaths, PixelConverter, GlobalHotkeyManager, StatusMonitor, VolumeController, ScreenshotController, Haptics, KeychainStore, RomTitle |
| `Libraries/` | SteamLibrary+VDFParser (reads Steam install), RomLibrary, RecentsStore, SettingsStore, LibraryStore, ArtworkLoader, CoreLocator |
| `Controllers/` | GamepadInput (InputSnapshot, GamepadUIAction), ControllerManager, GlobalHIDMonitor (capture DISABLED) |
| `Launch/` | RetroCore (dlopen), EmulatorSession (run loop), RetroEnvironment (env table), GLHardwareBridge, MetalRenderer, EmulatorMetalView, RetroAudioEngine, FrameSlot, SteamLauncher+SteamHandoffMonitor, StandaloneEmulatorLauncher |
| `Discord/` | DiscordController — embedded read-only WKWebView of discord.com/app |
| `RetroAchievements/` | RAClient (HTTP), RAHash, RACache, RAHubModel, RAModels, RAToastModel, RCClientService (rcheevos owner) |
| `UI/` | XMBView + XMBNavModel, QuickBarView, SettingsNavModel, EmulatorScreen/EmulatorView, WaveField, Theme, RemoteImage, ArtworkView, RootView |
| `CLI/` | CLI.swift + CLISelfTest, CLIProbeCore, CLIDiagnoseInput, CLIRASelfTest, CLIUnitTest |

Entry point: `main.swift` routes CLI flags before falling through to
`GameDockApp.main()`.

## Threading model

- **Main thread**: SwiftUI, controller handlers, library scanning, launch orchestration.
- **Core thread** (per EmulatorSession): `retro_run()` loop, frame-paced by `av_info.timing.fps`.
- **Audio render thread**: AVAudioEngine pulls from `RetroAudioRingBuffer` (NSLock).
- Cross-thread handoffs are lock-protected: `FrameSlot` (core→renderer),
  `RetroAudioRingBuffer` (core→audio), `InputSnapshot` (main→core), `RAToastModel`.
- GLHardwareBridge makes its NSOpenGLContext current **on the core thread**
  (context_reset deferred to just before the first `retro_run` — calling it
  inside the SET_HW_RENDER handler segfaults PPSSPP).

## Hard invariants (do not break)

1. **`Sources/CLibretro/` is ABI-critical.** Struct layouts and enum values match
   canonical libretro.h exactly; cores are compiled against them. Never
   "modernize" the C types.
2. **One libretro core loaded at a time.** Cores are `dlopen`ed with
   `RTLD_NOW | RTLD_GLOBAL`; a second mapped core can collide on symbol
   resolution. Sessions are serialized; teardown must fully complete before a
   new launch.
3. **`@convention(c)` callbacks cannot capture.** Global trampolines route
   through `EmulatorSession.active` (NSLock-guarded).
4. **No global PS-button capture on macOS 14/15.** Apple-confirmed IOHIDManager
   global-input bug + GameController is frontmost-only (see
   `docs/ps-button-report.md`). Cross-process restore = **Cmd+Shift+Home**
   (Carbon hotkey, no permission needed).
5. **PSP runs via the user's standalone PPSSPPSDL.app handoff** (its libretro
   macOS GL path renders black) — never shell out to RetroArch.
6. **Game handoff = `NSApp.hide`, never terminate / never orderOut a
   fullscreen window** (`AppDelegate.hideFrontend`): ordering a fullscreen
   window out can close it, and
   `applicationShouldTerminateAfterLastWindowClosed` then kills the whole app
   ("Leblanc disappears when launching a game"). `hideFrontend()` exits
   fullscreen first, then `NSApp.hide`; `restoreFrontend()` unhides +
   activates + re-enters fullscreen. Restore-on-exit: PPSSPP
   `Process.terminationHandler`, Steam `didTerminateApplication` observer.
6. **Discord is embedded + read-only by structure** (no text input); compose
   controls hidden via aria-role CSS. Mic/camera usage strings are in Info.plist.
7. **RA credentials live in the Keychain only** (never UserDefaults/plists/logs).
8. Swift 5 language mode is intentional (GameController/Metal/libretro
   callbacks aren't Swift-6-concurrency friendly).

## Rules for the agent

- CLI flags are the verification surface (`leblanc-build-verify` skill).
- `docs/` holds design + audit reports; read `docs/design-spec.md` and
  `docs/review-current-tree.md` before large changes.
- Big refactors go through the subagent pipeline (`Scripts/subagents/orchestrate.mjs`
  scout → planner → worker; note its pi imports are absolute to this machine).
