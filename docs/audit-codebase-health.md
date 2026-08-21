# Leblanc (GameDock) — Codebase Health Audit

**Scope**: Full read of all structural backbone files under `Sources/GameDock/` (state, models, core, libraries, controllers, launch, Discord, RetroAchievements, CLI, UI samples), `Tests/MockCore/mockcore.c`, `Package.swift`, and the three prior audit docs. Read-only; no files edited.

**Method**: Every file in the task's reading list was read in full. Targeted greps quantified `fatalError` (3), `try!` (0), `DispatchQueue` (41 lines / 19 files), `nonisolated(unsafe)` (1), `@MainActor` (2), `unsafeBitCast` (5), force-unwrap `URL(string:)!` (constant URLs only). Prior audit docs (`audit-preview-qol.md`, `audit-v2.md`, `review-current-tree.md`) were cross-checked against current source to distinguish fixed vs still-open findings. Line numbers in this document were re-verified against the source after the session.

**Key numbers**: ~80 Swift files, ~6,800 lines of app code + ~29,000 lines vendored CRcheevos C. 5 bundled fonts (~584 KB). No XCTest target; testing via CLI harness (`--unit-test`, `--selftest`, `--ra-selftest`, `--scan-steam`, `--preview-check`).

---

## 1. Architecture Assessment

### 1.1 The AppEnvironment god-object pattern

**Verdict: Pragmatic and acceptable for the current scope, but approaching its ceiling.**

`AppEnvironment` is the root `ObservableObject` — ~650 lines across three files — owning libraries, settings, controllers, Discord, Steam handoff, the emulator session, XMB navigation models, preview state, volume, status, screenshots, RA hub, and the entire input router. It is created once as a `@StateObject` in `GameDockApp.swift:5` and injected via `.environmentObject`.

It is large, but it is not a "god object" in the pejorative sense because:
- It delegates real work to owned subsystems (`LibraryStore`, `SettingsStore`, `ControllerManager`, `EmulatorSession`, `DiscordController`, `SteamLauncher`, `StandaloneEmulatorLauncher`, `VolumeController`, `StatusMonitor`, `ScreenshotController`, `RAHubModel`). These are independently testable and have their own state.
- Its own responsibilities are genuinely cohesive: **state coordination + input routing**. It does not parse VDF, scan ROMs, decode images, or render Metal. It wires results together.
- The `@Published` surface is intentionally narrow — mostly navigation flags (`screen`, `quickBarVisible`, `coreOptionsVisible`, `pauseMenuVisible`) and the `emulator` session.

**Where it strains**: The `gamepad(_:)` method (`AppEnvironment.swift:193-332`) is a 140-line switch with five modal-priority layers stacked by `if`/`return`: confirmation → pause menu → core options → Discord floating → quick bar → XMB. The order is load-bearing and there is no compile-time enforcement. Adding a sixth modal surface (e.g. an achievements overlay during emulation) means inserting another layer in the right position, and getting it wrong causes input to route to the wrong surface silently. This is the single most fragile pattern in the app.

**Should it be decomposed?** Not yet. The owned subsystems are already decomposed. Splitting `AppEnvironment` into e.g. `InputRouter` + `SessionCoordinator` + `XMBState` would move the 140-line switch into a `InputRouter` class, but the router needs access to all the same state (screen, emulator, quickBar, discord, pauseMenu, coreOptions, xmb, settings, volume) — so you'd either pass 12 parameters or give the router a reference back to the environment, which is circular. The current "one object holds everything, one method routes everything" is the simpler design until a second input consumer is needed. The threshold for decomposition is: **when a second non-gamepad input path is added** (e.g. voice, a touch surface, or a keyboard shortcut layer that doesn't map to GamepadUIAction).

### 1.2 The +Launch / +Settings extension split

**Verdict: Helps. The split is by concern, not by file-size cosmetics, and the header comment in `AppEnvironment.swift:14-18` documents it.**

The three-file split:
- `AppEnvironment.swift` — state, init, input routing, XMB/quick-bar, screenshots trigger, pause menu, error banner (the "core")
- `AppEnvironment+Launch.swift` (~200 lines) — launch orchestration (Steam/PPSSPP/embedded core), keep-awake, session tracking, screenshot capture
- `AppEnvironment+Settings.swift` (~135 lines) — settings row actions + NSOpenPanel/NSAlert panels

This is navigable: a future agent looking for "what happens when you launch a game" reads `+Launch.swift` and sees the full handoff flow without scrolling past XMB navigation. The alternative (one 650-line file) would be harder to navigate. The risk of extension-based splitting — fragmented understanding — is mitigated because the split is coarse (3 files, not 10) and the owned objects are real classes, not more extensions.

**One concern**: `+Launch.swift` and `+Settings.swift` access members of the main file (e.g. `isEmulatorLoadPending`, `idleActivity`, `sessionStart`, `sessionEntryID`). Swift extensions in different files within the *same module* can access `internal` members but not `private` ones. Looking at the actual declarations: `isEmulatorLoadPending` is `var` (internal, `AppEnvironment.swift:40`), `idleActivity` is `var` (internal, `AppEnvironment.swift:83`), `sessionStart`/`sessionEntryID` are `var` (internal). So the split works because the shared state is `internal`, not `private`. This means any file in the module can touch them. Not a problem today (the module is one app target), but if the module is ever split for testing, these need to become `internal` with `@testable import` or be grouped differently.

### 1.3 State management: @Published, Combine, thread-safety

**The pattern**: `@Published` on `ObservableObject` for UI-driving state. Combine (`sink`) for cross-object wiring (library→XMB rebuild, category→RA hub refresh). `NSLock` for thread-safe value types (`JSONFileStore`, `InputSnapshot`, `FrameSlot`, `CoreOptionsModel`, `RetroAudioRingBuffer`, `SteamLocalConfigReader`, `IGDBClient.tokenLock`, `RAToastModel`). `DispatchQueue` for thread hops. `Thread` for the core run loop. `Task`/`async` for network and debounced preview loads.

**Thread-safety concerns**:

1. **`RAToastModel.push()`** (`RAToastModel.swift:32-37`) reads `current` outside the lock:
   ```swift
   func push(_ toast: RAToast) {
       lock.lock()
       queue.append(toast)
       lock.unlock()
       if current == nil { advance() }  // ← reads @Published current without lock
   }
   ```
   `current` is `@Published` and mutated inside `advance()` under lock. But `push()` reads it bare on line 36. If `push()` is called from the core thread (it is — `RCClientService` event handler → `DispatchQueue.main.async` → `push`), and `advance()` is also on main, this is main-thread-sequential and safe *in practice*. But it's a latent race if `push()` is ever called off-main. The `pushToast` helper in `EmulatorSession.swift:538-543` does `DispatchQueue.main.async`, so it's currently safe. Fragile.

2. **`IGDBClient`** (`IGDBClient.swift:20-22`) uses `nonisolated(unsafe)` on `accessToken`/`tokenExpiry`/`tokenLock`. The lock guards access, so it's correct, but `nonisolated(unsafe)` is a Swift 6 escape hatch that silences the checker. It works because every access goes through `tokenLock`. This is the only `nonisolated(unsafe)` in the codebase — a deliberate, contained choice.

3. **`@Published` mutations off-main**: The codebase is disciplined about hopping to main before mutating `@Published` — every `DispatchQueue.main.async` before setting `@Published` is present. The one exception is `RAHubModel.refresh()` which uses `await MainActor.run { }` blocks (correct). `CoreOptionsModel.publish()` hops to main (correct). No off-main `@Published` mutations were found.

4. **`EmulatorSession.active` / `RCClientService.active`**: Process-global singletons, lock-guarded. See §3.3.

### 1.4 The input router pattern

**`gamepad(_:)` is a single funnel — scalable for now, but the modal-stacking is the fragility hotspot.**

All gamepad and keyboard input routes through `AppEnvironment.gamepad(_:)`. `ControllerManager` translates DualSense/keyboard events into `GamepadUIAction` enums and calls `uiReceiver?.gamepad(action)`. This is clean: adding a new controller type means hooking the same `InputSnapshot` + `GamepadUIAction` sink.

The router's structure (`AppEnvironment.swift:193-332`):
```
if pendingConfirmation { ... return }      // modal layer 1
if pauseMenuVisible, emulator != nil { ... return }  // modal layer 2
if coreOptionsVisible, let options = ... { ... return }  // modal layer 3
if discord.isFloating { ... return }        // modal layer 4
if quickBarVisible { ... return }            // partial modal layer 5
if action == .captureScreenshot { ... return }  // global intercept
switch action { ... }                        // XMB / emulator base layer
```

**What works**: The early-return pattern means higher-priority modals always intercept. The base layer handles both XMB and emulator contexts via `if screen == .xmb` / `if screen == .emulator`. Edge-triggered actions (confirm, back) vs. repeatable actions (up/down/left/right) are distinguished at the `ControllerManager` level via `repeatableActions` set (`ControllerManager.swift:276-278`), so the router doesn't need to debounce.

**What's fragile**:
- The `back` action (`AppEnvironment.swift:300-309`) has context-dependent behavior: dismiss quick bar → open pause menu (emulator) → cancel in-flight boot. A future agent adding a new surface that also traps `back` must insert the check in the right place in the cascade.
- `captureScreenshot` is intercepted before the modal cascade (`AppEnvironment.swift:287-289`), meaning it works even when a modal is open. This is intentional but undocumented in the cascade comment.
- There is no "current modal depth" concept — the router infers it from boolean flags. If two modals could be open simultaneously (e.g. pause menu + core options), the order of the `if` blocks determines which wins. Today `openCoreOptions` guards against `pauseMenuVisible` (`AppEnvironment.swift:567`) and vice versa, preventing this. But the guard is on the *opener*, not the router.

### 1.5 Separation of concerns

| Layer | Responsibility | Boundary quality |
|---|---|---|
| `Core/` | Pure utilities, models, paths, logging, no UI | **Clean.** No SwiftUI/AppKit in Models, AppPaths, Logger, JSONFileStore, PlaytimeFormatter, PixelConverter, RomTitle, KeychainStore, Secrets. Haptics imports GameController (justified). StatusMonitor imports IOKit/Network (justified). |
| `Libraries/` | Data sources: Steam, ROMs, artwork, caches, network clients | **Clean.** No UI. Stores are `ObservableObject` but don't import SwiftUI. SettingsStore is the one that leaks — it imports Combine (fine) but the RA token migration logic (Keychain→UserDefaults) is domain logic that belongs here. |
| `Launch/` | Emulator session, libretro binding, Metal/GL, audio | **Clean.** No UI except `EmulatorMetalView` (NSView wrapper — justified interop). `EmulatorSession` is large (~770 lines) but cohesive. |
| `Controllers/` | Gamepad/keyboard/HID input translation | **Clean.** No UI. `ControllerManager` is the bridge; `GamepadInput` is the protocol; `GlobalHIDMonitor` is the system-HID fallback. |
| `UI/` | SwiftUI views + nav models | **Not fully audited** (read `RemoteImage`, `EmulatorMetalView`; others referenced via models). The nav models (`XMBNavModel`, `SettingsNavModel`, `QuickBarModel`, `SelectionPreviewModel`, `PauseMenuModel`) are `ObservableObject` / value types, testable. |
| `RetroAchievements/` | RA Web API + rcheevos C binding | **Clean.** `RAClient` is pure async networking. `RCClientService` is the C-binding bridge (mirrors the libretro shim pattern). `RAHubModel` is the UI-facing cache model. |
| `Discord/` | WKWebView wrapper | **Clean.** Single file, no leaks. |

The one cross-layer smell: `AppEnvironment` imports `AppKit` (via `+Settings.swift` for `NSOpenPanel`/`NSAlert`) and `UniformTypeIdentifiers`. This is fine for an app target but means the router is UI-framework-coupled. Not worth fixing.

---

## 2. Code Quality Patterns

### 2.1 Error handling — mixed but consistently applied

Four distinct patterns, each appropriate to its context:

1. **Throwing with typed errors** — used where the caller can recover:
   - `RetroCoreError` (`RetroCore.swift:48-52`): `.dlopenFailed`, `.missingSymbol`, `.apiVersionMismatch`. Callers in `EmulatorSession.load()` catch and translate to `SessionError.loadGameFailed`.
   - `StandaloneEmulatorLauncher.LauncherError` (`StandaloneEmulatorLauncher.swift:98-110`): `.alreadyRunning`, `.executableNotFound`, `.romNotFound` with `LocalizedError`.
   - `RAClient.RAClientError` (`RAClient.swift:17-29`): `.badURL`, `.http(Int)`, `.empty`.
   - `EmulatorSession.SessionError` (`EmulatorSession.swift:197-199`): single `.loadGameFailed`.

2. **Optionals with `try?`** — used for best-effort/fallback paths:
   - `AppPaths.ensureDirectories()` (`AppPaths.swift:18`) is `try?` at the call site (`AppEnvironment.swift:97`, `ArtworkLoader.swift:50`) — if dir creation fails, the app continues and fails later at the actual I/O.
   - Disk cache reads/writes throughout (`SteamScreenshotStore`, `IGDBClient`, `RACache`, `ArtworkLoader`) use `try?` — cache miss is a non-failure.

3. **String-based UI errors** — `AppEnvironment.showError(_:)` (`AppEnvironment.swift:618-627`) takes a `String` and an optional `autoDismissAfter`. This is the user-facing error channel. The `AppError` struct (`AppEnvironment.swift:639-651`) adds `.info`/`.warn`/`.error` kind and an optional retry closure. This is adequate but loses type info — the caller can't pattern-match on the error kind, only display it.

4. **Silent swallowing** — `catch { }` or `try?` with no logging. Found in a few spots:
   - `DiscordController.swift:63`: `webView.evaluateJavaScript(js, completionHandler: nil)` — JS errors ignored (acceptable — read-only DOM injection).
   - `ArtworkLoader.swift:137`: `try? FileManager.default.copyItem(...)` — cache copy failure ignored (acceptable — the image is already decoded).
   - `Haptics.swift:40-41`: `catch { // Best-effort; ignore pattern/start failures. }` — acceptable, documented.

**Consistency**: The patterns are consistent *within each layer*. Launch throws (callers must handle), libraries return optionals (cache-friendly), UI shows strings. The inconsistency is that `AppError` carries a `retry` closure (`AppEnvironment.swift:644`) but no call site in the current code passes a retry — it's future-facing dead state on the struct.

### 2.2 Caching — 8 separate caches, 3 envelope patterns, no unification

This is the most fragmented area. Counting every cache:

| Cache | File | Memory | Disk | TTL | Envelope pattern |
|---|---|---|---|---|---|
| ArtworkLoader | `ArtworkLoader.swift` | `cache: [String: NSImage]` (LRU 200) | `artworkDir/*.img` | None (permanent) | None (raw file copy) |
| RemoteImage | `RemoteImage.swift` | `static cache: [String: NSImage]` (unbounded) | None | None | None |
| SteamScreenshotStore | `SteamScreenshotStore.swift` | `memory: [String: [URL]]` | `preview-cache/steam-screenshots/*.json` | 7 days | `CacheEnvelope { fetchedAt, urls }` |
| SteamGridDBStore | `SteamGridDBStore.swift` | `memory: [String: [URL]]` | `preview-cache/steamgriddb/*.json` | 7 days | `GridArt { fetchedAt, urls }` |
| IGDBClient | `IGDBClient.swift` | None | `preview-cache/igdb/*.json` | 7 days | `CacheEnvelope { fetchedAt, meta }` |
| RACache | `RACache.swift` | None | `ra-cache/*.json` | Caller-decided | `Envelope<T> { fetchedAt, value }` (generic) |
| SteamLocalConfigReader | `SteamLocalConfigReader.swift` | `cached: [String: Int]?` | None (reads live VDF) | Session | N/A |
| SteamLibrary.gridDirs | `SteamLibrary.swift` | `cachedGridDirs: [URL]?` | None | Per-scan | N/A |

**Three envelope patterns** for the same `{ fetchedAt, value }` shape: `CacheEnvelope` (SteamScreenshotStore), `GridArt` (SteamGridDBStore — identical struct, different name), `CacheEnvelope` (IGDBClient — different fields), and `Envelope<T>` (RACache — generic). These could all be one generic `CacheEnvelope<T: Codable> { fetchedAt: Date, value: T }` like `RACache` already uses.

**Three disk-cache locations**: `artworkDir` (ArtworkLoader), `preview-cache/{steam-screenshots,steamgriddb,igdb}/` (three stores), `ra-cache/` (RACache). All under `AppPaths.appSupport`. No shared invalidation — `AppEnvironment+Settings.swift:66-68` invalidates `SteamScreenshotStore` and `SteamLocalConfigReader` on rescan, but not `SteamGridDBStore`, `IGDBClient`, `RACache`, or `ArtworkLoader`'s disk cache. A user who rescans to refresh stale art doesn't get a SteamGridDB/IGDB refresh.

**Two unbounded memory caches**: `RemoteImage.cache` (RA avatars/badges — small, low risk) and `ArtworkLoader.cache` (capped at 200, LRU-evicted — bounded). RemoteImage is the only truly unbounded one.

**Risk level**: Low for correctness (each cache works independently). Medium for maintainability — a future agent adding a 9th cache will copy one of the 3 envelope patterns and create a 4th. A shared `CacheStore<T>` abstraction (disk + memory + TTL + invalidate) would collapse this, but it's a refactor, not a bug.

### 2.3 Concurrency — mixed but deliberate

**Three concurrency models coexist**:
1. **`DispatchQueue`** (41 lines / 19 files) — the dominant pattern. Used for: serial core load/teardown (`emulatorLoadQueue`), library scan (`scanQueue`), audio lifecycle (`lifecycleQueue`), network (`DispatchQueue.global(qos:)`), main-thread hops.
2. **`Thread`** — the core run loop (`EmulatorSession.runLoop` on `Thread(name: "GameDock.Core")`). Justified: the core thread needs a fixed-priority QoS and a stable name for debugging; `DispatchQueue.async` doesn't give that.
3. **`Task`/`async/await`** — network (RAClient, SteamScreenshotStore, SteamGridDBStore, IGDBClient), debounced preview loads (SelectionPreviewModel), RA hub refresh, screenshot capture.

**`NSLock`** — 15+ instances across the codebase, guarding: `JSONFileStore.value`, `InputSnapshot.buttons/analog`, `FrameSlot.buffer`, `CoreOptionsModel.definitions/values/buffers`, `RetroAudioRingBuffer.storage`, `SteamLocalConfigReader.cached`, `IGDBClient.accessToken`, `RAToastModel.queue`, `EmulatorSession._active`, `RCClientService._active/pending`, `Secrets.values`, `RemoteImage.cache`, `ManagedAtomic.value`.

**`ManagedAtomic`** (`EmulatorSession.swift:753-772`) — a hand-rolled `NSLock`-backed atomic bool. Used for `stopRequestedFlag` and `pausedFlag`. This exists because the project doesn't import `Atomics` or `swift-collections`. It works but is a code smell — `import Atomics` and `ManagedAtomic<Bool>` from `SWCAtomics` would be the idiomatic choice.

**Is the mixing a problem?** Not today. The boundaries are clean: `Thread` for the core loop (justified), `DispatchQueue` for serialization and hops, `Task` for async networking. The risk is that a future agent might use `Task` for core-loop work (wrong — needs fixed thread) or `DispatchQueue.global` for a libretro call (wrong — needs `emulatorLoadQueue`). The `emulatorLoadQueue` label is documented at `AppEnvironment.swift:42-43` with the RTLD_GLOBAL rationale — good.

**Swift 6 readiness**: Not close. `nonisolated(unsafe)` on IGDBClient, process-global singletons without `actor` isolation, `@MainActor` used in only 2 places. A `swift build -c release` with Swift 6 language mode would produce many warnings. This is a known non-goal (the project builds in Swift 5 mode per the overview).

### 2.4 Logging — consistent and useful

`Log` (`Logger.swift`) is the single logging surface. `os_log` in GUI mode, stdout in CLI mode (auto-detected via `isCLIMode`). Every level (`debug`/`info`/`warn`/`error`) includes `file:line` automatically. Usage is consistent across all files — no `print()` in production code (only `Log.cliPrint` for CLI output, which is intentional).

The CLI/GUI split is well-designed: `setvbuf(stdout, nil, _IONBF, 0)` in `main.swift:6` ensures CLI diagnostics survive a core segfault.

**One gap**: `Log.debug` messages from the core thread (e.g. `gd_log` in `EmulatorSession.swift:39-48`) go through `os_log` which is rate-limited and redacts by default. A verbose core can flood the unified log. Not a bug, but `--diagnose-input` level verbosity would help for core debugging.

### 2.5 File I/O — three patterns, mostly unified

1. **`JSONFileStore<Value>`** (`JSONFileStore.swift`) — thread-safe, atomically-persisted generic JSON store. Used by `RecentsStore` and `FavoritesStore`. This is the good pattern — collapses load/save/lock boilerplate. **Only 2 consumers out of ~8 persistence needs.**
2. **`UserDefaults`** (`SettingsStore.swift`) — suite `com.gamedock.GameDock`. Stores romFolders, coreOverrides, standalonePaths, raUsername, raAPIToken, raHardcore, raUnofficial, globalCapture, coreOptions. Appropriate for settings (user-tunable, small, KVO-able).
3. **Direct `FileManager`** — screenshots (`ScreenshotController.save`), artwork disk cache (`ArtworkLoader.diskCacheURL`), preview caches (`SteamScreenshotStore`, `SteamGridDBStore`, `IGDBClient`), RA cache (`RACache`). Each hand-rolls `createDirectory` + `write(atomic:)` + `Data(contentsOf:)`.

The `RACache` struct (`RACache.swift`) is the closest to a reusable cache-store, but it's generic only over `Codable` values and doesn't include TTL logic (callers decide). The three preview-cache stores (`SteamScreenshotStore`, `SteamGridDBStore`, `IGDBClient`) each re-implement the same `diskCache(for:)` / `saveDiskCache(_:for:)` / `cacheFile(for:)` / `cacheDirectory()` pattern with their own envelope struct. This is the strongest candidate for a shared abstraction.

---

## 3. Technical Debt & Risk

### 3.1 fatalError / crash paths

Three `fatalError` calls (grep-verified):

1. `EmulatorMetalView.swift:47` — `required init?(coder:) { fatalError("init(coder:) has not been implemented") }`. **Safe.** Standard AppKit boilerplate for programmatic NSView subclasses. This is never invoked in a SwiftUI app (no storyboard/xib).

2. `EmulatorMetalView.swift:87` — same pattern in `FallbackFrameView`. **Safe.**

3. `EmulatorSession.swift:238` — `guard let retroInit = core.retroInit else { fatalError("retro_init missing") }`. **Defensive but real.** `retroInit` is a mandatory symbol resolved in `RetroCore.load()` (`RetroCore.swift:109`) which throws `RetroCoreError.missingSymbol` if absent. So by the time we reach line 238, `retroInit` is guaranteed non-nil. This `fatalError` is dead code — it can never fire because `load()` would have thrown first. It's a belt-and-suspenders guard that is technically unreachable. **Low risk** but misleading: it implies the symbol might be missing, when in fact `load()` already guaranteed it. Replace with `retroInit()` (force-unwrap the optional, which is safe after `load()`).

No other `fatalError`, no `try!`, no `preconditionFailure` in the app code.

### 3.2 Force unwraps / implicit unwraps

Force-unwrap `!` on `URL(string:)` appears in:
- `RAClient.swift:10` — `URL(string: "https://retroachievements.org/API")!` — constant URL, safe.
- `DiscordController.swift:91` — `URL(string: "https://discord.com/app")!` — constant URL, safe.
- `CLIUnitTest.swift:269` — test fixture URLs, safe.
- `MetalRenderer.swift:159` — `device.makeSamplerState(descriptor: desc)!` — fails only if the Metal device is broken, which would have been caught at `init?` time. Acceptable.
- `EmulatorSession.swift:189` — `AVAudioFormat(...)!` — fails only if the format params are invalid; they're hardcoded (`pcmFormatInt16`, `sampleRate > 0`, `channels: 2`). Safe.

These are all "known-valid constant" force-unwraps. No force-unwraps of user input or computed values were found. This is disciplined.

### 3.3 Thread-safety violations waiting to happen

**Process-global singletons for callback routing:**

`EmulatorSession.active` (`EmulatorSession.swift:96-111`) and `RCClientService.active` (`RCClientService.swift:65-80`) are process-wide static pointers, lock-guarded, that the non-capturing `@convention(c)` callbacks route through. This mirrors the libretro shim pattern. The constraint: **only one core can be active at a time**.

The enforcement has three layers:
1. `AppEnvironment.emulatorLoadQueue` (serial `DispatchQueue`, `AppEnvironment.swift:43`) — serializes `load()` and `teardown()` so they never overlap.
2. `EmulatorSession.setActive(self)` in `load()` (`EmulatorSession.swift:225`), `setActive(nil)` in `teardown()` (`EmulatorSession.swift:614`).
3. `RCClientService.setActive(self)` in `create()` (`RCClientService.swift:158`), `setActive(nil)` in `destroy()` (`RCClientService.swift:313`).

**The fragility**: The `active` pointer is a raw global, not tied to the queue. If a future agent creates an `EmulatorSession` without going through `emulatorLoadQueue` (e.g. in a test helper, a preview, or a second window), `setActive` clobbers the previous session's pointer, and the previous session's core callbacks silently route to the new session. The code doesn't assert "I am the active session" — it just writes the pointer.

**Mitigation in place**: `AppEnvironment.startEmulator` (`AppEnvironment+Launch.swift:129`) dispatches `load()` onto `emulatorLoadQueue.async`, and `exitEmulation` (`AppEnvironment+Launch.swift:189`) dispatches `requestStop()` + `teardown()` onto the same queue. So the GUI path is safe. The CLI self-test (`CLI.swift:39`) calls `session.load()` directly on the main thread — but only one session exists in that path. The risk is a *future* path that creates two sessions.

**The single-core-at-a-time constraint is correctly enforced today but not by the type system.** A future agent who adds a "quick switch between two ROMs" feature must understand that the old session's `teardown()` must complete on `emulatorLoadQueue` before the new session's `load()` starts. The serial queue guarantees this, but only if the agent uses it. There is no compile-time guard preventing `EmulatorSession(corePath:...).load()` from being called concurrently with an existing session.

**`shim_set_callbacks` / `shim_install`** (`EmulatorSession.swift:219-221`): The shim's `g_cb` global is set via `shim_set_callbacks` before each `retro_init`. This is another process-global that assumes single-session. The comment at `EmulatorSession.swift:8` documents this. If two sessions load concurrently, the second's callbacks overwrite the first's. The serial queue prevents this.

### 3.4 Memory leaks (retained closures, un-cancelled tasks, observer leaks)

1. **`ControllerManager.observers`** (`ControllerManager.swift:20`) — NotificationCenter observers are appended to the array but never removed. No `deinit` cleanup. The manager lives for the app lifetime, so this is benign — but if the manager is ever recreated (e.g. for a reconnection flow), the old observers leak and keep delivering to a dead object. Low risk today.

2. **`SteamHandoffMonitor.observers`** (`SteamLauncher.swift:39`) — same pattern. Added once, never removed. App lifetime, benign.

3. **`AppEnvironment.sleepObserver` / `wakeObserver`** (`AppEnvironment.swift:88-89`) — stored in properties, registered in `init`. No `deinit` removes them. `AppDelegate.applicationWillTerminate` removes `windowObserver` but AppEnvironment has no equivalent. App lifetime, benign.

4. **`SteamScreenshotStore.inflight`** (`SteamScreenshotStore.swift:26-61`) — `Task` stored in `inflight[appID]`, awaited, then removed. The generation-counter pattern (`inflightGeneration`) discards stale results. If the `Task` is cancelled (the caller's `SelectionPreviewModel` debounce cancels), the `await task.value` still completes (it's `Task<[URL], Never>`), and `inflight.removeValue` runs. This was flagged in `audit-preview-qol.md §CR-01` — the current code's generation check (`inflight[appID]?.generation == gen` at line 56) prevents the replace-and-lose race. **Fixed.**

5. **`SteamGridDBStore.inflight`** (`SteamGridDBStore.swift:21`) — same `Task` pattern, but **no generation counter**. Line 44: `inflight[appID] = task`; line 46: `inflight[appID] = nil` after `await`. If a rapid re-selection cancels the first task and starts a second, the first's `await task.value` completes, then `inflight[appID] = nil` clears the second's entry. The second task still runs (it's already created) but a third call would start a duplicate fetch. **Lower-stakes version of the SteamScreenshotStore issue. Not fixed.**

6. **`ArtworkLoader` decode tasks** — no `Task` retention; uses `URLSession.dataTask` (not `Task`) for remote fetches. The `inflight` set deduplicates. Cancellation: no explicit cancellation, but the `inflight` guard prevents duplicates. The `failed` tombstone has a 60s retry interval (`ArtworkLoader.swift:32`). **Fixed** (was permanent in prior audits).

7. **`AppEnvironment.idleActivity`** (`AppEnvironment.swift:83`) — `ProcessInfo.beginActivity` returns an activity token; `endKeepAwake()` calls `endActivity`. Balanced. If `beginKeepAwake` is called twice without an `endKeepAwake` in between, the first token leaks (overwritten). `startEmulator` calls `beginKeepAwake` (`AppEnvironment+Launch.swift:127`) and `exitEmulation` calls `endKeepAwake` (`AppEnvironment+Launch.swift:182`). The Steam/PPSSPP paths also pair them. **Balanced.**

### 3.5 Magic numbers / hardcoded paths

**Hardcoded paths** (all documented, all standard for macOS):
- `~/Library/Application Support/GameDock` (`AppPaths.swift:8-9`)
- `~/Library/Application Support/RetroArch/cores` (`CoreLocator.swift:46`)
- `~/Library/Application Support/RetroArch/thumbnails` (`ArtworkLoader.swift:240-241`)
- `~/Library/Application Support/Steam` (`SteamLibrary.swift:35`)
- `~/Library/Application Support/Steam/userdata` (`SteamLocalConfigReader.swift:69-70`)
- `~/Pictures/Leblanc Captures` (`ScreenshotController.swift:17-19`)
- `~/Downloads/ROMS/PPSSPPSDL.app` (`StandaloneEmulatorLauncher.swift:27`) — **this one is questionable.** It's the *default* PPSSPP path, overridable in Settings, but `~/Downloads/ROMS/` is an unusual convention. Most users would have PPSSPP in `/Applications/PPSSPPSDL.app` or `~/Applications/`. This default will rarely match. Not a bug (Settings overrides it), but a UX papercut.

**Magic numbers**:
- Libretro button IDs in `ControllerManager.hook` (`ControllerManager.swift:98-126`): `8` (A/confirm), `0` (B/back), `9` (X), `1` (Y), `4/5/6/7` (dpad), `10/11` (L1/R1), `12/13` (L2/R2), `14/15` (stick clicks), `2/3` (Select/Start). These map to `RETRO_DEVICE_ID_JOYPAD_*` constants in `libretro.h`. They are not referenced by name — a future agent who needs to add a button must look up the ID in the C header. **Should be constants or an enum.**
- `RETRO_API_VERSION = 1` (`EmulatorSession.swift:88`), `RETRO_DEVICE_JOYPAD = 1`, `RETRO_DEVICE_ANALOG = 5` (`EmulatorSession.swift:89-90`). These *are* from the C header but duplicated as Swift constants rather than using `CLibretro.RETRO_API_VERSION`. The comment says "ABI constants from the canonical libretro header" — but they're hand-copied, not imported.
- RC memory type mapping in `RCClientService.loadConsoleMemoryMap` (`RCClientService.swift:252-256`): `0 → 2`, `1 → 0`, `2 → 3` with a comment. These are `RC_MEMORY_TYPE_*` → `RETRO_MEMORY_*` mappings. Documented but magic.
- `60` fps fallback (`EmulatorSession.swift:366`, `MetalRenderer` preferredFramesPerSecond), `2.0` second core thread join timeout (`EmulatorSession.swift:448`), `10.0` second first-frame timeout (`AppEnvironment+Launch.swift:166`), `480x272` PSP native fallback (`EmulatorSession.swift:745-746`), `200` max cache entries (`ArtworkLoader.swift:27`), `600` thumbnail max pixels (`ArtworkLoader.swift:47`), `7 * 24 * 3600` cache TTL (repeated in 3 stores).

### 3.6 Dead code / stale references

1. **`FrameSlot.format`** (`FrameSlot.swift:15`) — `private(set) var format: RetroPixelFormat` is set in `push()` (line 51) but never read. `withLatest` doesn't expose it; `latestSeq` doesn't expose it. No external caller reads it. Write-only state. The `MetalRenderer` reads pixel format implicitly (always `bgra8Unorm` after conversion). **Dead.**

2. **`AppError.retry`** (`AppEnvironment.swift:644`) — `var retry: (() -> Void)?` is declared but never set by any caller. The `Equatable` conformance ignores it. Future-facing dead state.

3. **`SettingsNavModel.selection`** — per `review-current-tree.md §P3-6`, this `@Published var selection` is only clamp-guarded in `rebuild` and never read by any view. Confirmed still open.

4. **`ArtworkLoader.imageDimensions` / `isLandscape` / `isPortrait`** — all three are used in `localPath(for:kind:)` (`ArtworkLoader.swift:192-211`). Not dead. (Prior audit `audit-preview-qol.md §CR-04` flagged the *old* version that used `NSImage(contentsOfFile:)`; the current code uses `CGImageSourceCreateWithURL` — **fixed**.)

5. **`Info.plist NSAccessibilityUsageDescription`** — per `review-current-tree.md §1.3`, this is stale (describes the removed AXUIElement window-resize approach). Not verified in this audit (Info.plist not in the reading list). Flagged for follow-up.

6. **`AGENTS.md` module map** — per `review-current-tree.md §6`, stale (names `GameLauncher`, `FrameSlotRing`, `HomeView`, `GameCardView`, `SettingsView` — none exist). Not verified. Flagged.

7. **`README.md:14`** — per `review-current-tree.md §6`, says `build/GameDock.app` but the app is `build/Leblanc.app`. Not verified. Flagged.

---

## 4. Testing Coverage

### 4.1 What's tested

**`--unit-test` (`make test`)** — `CLIUnitTest.run()` (`CLIUnitTest.swift`). Pure-logic assertion battery, no I/O, no UI. Covers:
- `VDFParser` — 10 cases (flat pairs, nested dicts, backslash preservation, escaped quotes, line/block comments, BOM, unbalanced brace, unterminated string). **Strong.**
- `RomTitle` — 6+ cases (artKey, cleanedTitle with regions/tags/translations, normalization). **Strong.**
- `PixelConverter` — implicit via `--selftest` frame inspection.
- `CoreOptionParser` — 5 cases (title, values, whitespace, missing values, empty list). **Strong.**
- `SettingsStore` core options — round-trip, per-game isolation, per-core isolation, persistence across instances. **Strong** (uses a test UserDefaults suite).
- `QuickBarModel` — wrap-around, up/down/left/right/confirm, context switch, emulator-list wrapping. **Strong.**
- `PlaytimeFormatter` — hours+minutes, hours only, minutes only, zero, seconds, sub-minute. **Strong.**
- `SteamLocalConfigReader.parsePlaytimeMinutes` — pure parse with VDF fixture. **Strong.**
- `SteamScreenshotStore.parseScreenshotURLs` — success, unsuccessful, missing appid. **Strong.**
- `SteamGridDBStore.parseGameArt` — single-game, array, empty. **Strong.**
- `IGDBClient.parseMetadata` — genre, year, developer. **Strong.**
- `GameEntry.romID` — determinism, cross-system isolation. **Strong.**

**`--selftest`** — `CLISelfTest.run()` (`CLI.swift:32`). End-to-end emulator round-trip with `Tests/MockCore/mockcore.c`. Loads a mock core via dlopen, runs frames, asserts: load success, system info present, AV info present, frame rendering (square X-position moves), audio samples received, input (held RIGHT → faster movement). **Good integration coverage of the libretro binding.**

**`--ra-selftest`** — `CLIRASelfTest.run()` (`CLIRASelfTest.swift`). RA callback plumbing with fake `read_memory` + fake `server_call`. Asserts: `rc_client_create` succeeds, `server_call` invoked, login URL observed, load-game by hash doesn't crash. **Smoke test, not behavioral.**

**`--scan-steam`** — `CLIScanSteam.run()` (`CLI.swift:7`). Integration with real Steam install. Prints discovered games. Manual validation, not automated assertions.

**`--preview-check`** — `CLIPreviewCheck.run()` (`CLIPreviewCheck.swift`). Integration with real Steam localconfig + storefront screenshots + local captures. Manual.

**`--probe-core`** / **`--diagnose-input`** / **`--watch-hid`** — CLI modes referenced in `main.swift:15-29`. These are diagnostic tools for core probing and HID device inspection.

### 4.2 What's NOT tested

| Surface | Risk level | Why untested |
|---|---|---|
| `AppEnvironment.gamepad()` routing | **High** | 140-line modal-stacking switch with context-dependent `back` behavior. No automated test exercises the cascade. A regression here silently routes input to the wrong surface. |
| `ControllerManager` button→libretro ID mapping | **High** | Magic-number mappings (8→A, 0→B, etc.) with no assertion that they match `RETRO_DEVICE_ID_JOYPAD_*`. An off-by-one maps the wrong button. |
| `MetalRenderer` / `EmulatorMetalView` | **Medium** | GPU rendering; hard to unit-test. `--selftest` proves frames reach `FrameSlot` but not that Metal uploads them. |
| `GLHardwareBridge` | **Medium** | GL context/FBO creation, readback, flip. No test. PPSSPP path depends on it. |
| `RetroEnvironment.handle` | **Medium** | ~30 `retro_environment` command cases with pointer arithmetic. The pure parse functions are tested but the command dispatcher is not. |
| `DiscordController` | **Low** | WKWebView wrapper with injected JS. The JS is fragile (Discord DOM changes) but untestable without a live Discord session. |
| `VolumeController` | **Low** | CoreAudio plumbing. Hard to unit-test (needs audio hardware). |
| `GlobalHotkeyManager` / `GlobalHIDMonitor` | **Low** | OS integration, needs real hardware. |
| `Haptics` | **Low** | Needs DualSense. |
| `AppDelegate` fullscreen/window management | **Low** | AppKit windowing, needs real window. |
| Save/load state (`runSaveState`/`runLoadState`) | **Medium** | Serialization round-trip. Testable with mock core but not tested. |
| Pause/resume + sleep/wake | **Medium** | `pausedFlag` + audio engine stop/start. Not tested. |
| `EmulatorSession.teardown` / `coreThreadStuck` | **High** | The stuck-core path (leak instead of dlclose). Cannot safely test without a core that hangs. |
| `RCClientService.readMemory` address translation | **Medium** | Console address → libretro region mapping. Pure logic, testable, not tested. |

### 4.3 The CLI harness approach (no XCTest)

**Rationale** (`CLIUnitTest.swift:7-10`): "This machine builds with Command Line Tools only — neither XCTest nor swift-testing ships with CLT — so `swift test` can't link a test target here."

**Assessment**: This is a pragmatic workaround that has served the project well. The pure-logic modules (VDFParser, RomTitle, PixelConverter, CoreOptionParser, SettingsStore, PlaytimeFormatter) have genuine regression coverage via `make test`. The harness runs in-process (no test target linking), which means it can import the app module directly.

**Risk**: The harness cannot test:
- Anything that requires `@testable import` of `internal` members from a separate module (it's all one module).
- UI views (no SwiftUI test environment).
- Async/time-based behavior (no `XCTestExpectation`).
- Memory leaks (no `XCTAssertNoRetainCycle`).
- Performance regressions (no `XCTestCase.measure`).

**If Xcode becomes available**, migrating `CLIUnitTest` to a `GameDockTests` XCTest target is a clean, mechanical follow-up. The test bodies would be identical; only the harness (`run() -> Bool`) becomes `XCTestCase` methods. The `--selftest` / `--ra-selftest` should remain as CLI modes (they need dlopen and real cores).

---

## 5. Refactoring Recommendations

### Ranked by risk-reduction impact (do before adding features)

#### Tier 1: Do before any new feature touches these surfaces

1. **Constants for libretro button IDs in `ControllerManager`** — Replace magic numbers (`8`, `0`, `9`, `1`, `4-7`, `10-13`, `14-15`, `2-3`) with a `RetroJoypadButton` enum or named constants. Risk: a wrong ID maps the wrong face button and the user can't navigate. Effort: ~30 min. Impact: prevents the most likely controller regression.

2. **`EmulatorSession.swift:238` — replace `fatalError` with force-call** — `guard let retroInit = core.retroInit else { fatalError(...) }` → `core.retroInit!()` or `core.retroInit?()` with a comment that `load()` guaranteed it. The `fatalError` implies a runtime check that can never fire. Effort: 5 min. Impact: removes a misleading crash path.

3. **Unify the preview-cache envelope** — `SteamScreenshotStore.CacheEnvelope`, `SteamGridDBStore.GridArt`, `IGDBClient.CacheEnvelope` → one generic `CacheEnvelope<T: Codable> { fetchedAt: Date, value: T }` (like `RACache.Envelope`). Also unify the `diskCache(for:)` / `saveDiskCache(_:for:)` / `cacheFile(for:)` / `cacheDirectory()` quartet into a shared `DiskCacheStore<T>`. Effort: ~2 hours. Impact: prevents a 4th envelope pattern; makes cache invalidation shared.

4. **Add `SteamGridDBStore` generation counter** — Mirror `SteamScreenshotStore`'s `inflightGeneration` pattern to prevent the stale-`inflight`-clear race. Effort: ~30 min. Impact: prevents stale grid art after rapid selection changes.

#### Tier 2: Do when touching the related subsystem

5. **Remove `FrameSlot.format` dead state** — Delete the `private(set) var format` property and its assignment in `push()`. Effort: 5 min. Impact: removes write-only state that confuses readers.

6. **Remove `AppError.retry` dead property** — Either wire it up (pass retry closures in `showError` call sites) or delete it. Effort: 10 min (delete) or ~1 hour (wire up). Impact: removes future-facing dead state.

7. **Replace `ManagedAtomic` with `import Atomics`** — The hand-rolled `NSLock`-backed atomic (`EmulatorSession.swift:753-772`) works but is a smell. `import Atomics` (or `import struct Atomics.ManagedAtomic`) gives a real lock-free atomic. Effort: ~30 min + Package.swift dependency. Impact: removes a hand-rolled concurrency primitive.

8. **`RAToastModel.push()` — read `current` under lock** — Move the `if current == nil` check inside the lock or document that `push` is main-thread-only. Effort: 5 min. Impact: removes a latent race.

#### Tier 3: Fine to leave (low risk, high effort, or app-lifetime benign)

9. **Decompose `AppEnvironment`** — Not needed until a second input consumer is added. The 650-line god object is navigable and the owned subsystems are already decomposed. Effort: ~1 day. Impact: low (no current pain).

10. **Unify all caches behind a `CacheStore<T>`** — 8 caches with 3 envelope patterns. A shared abstraction would be cleaner but each cache works correctly today. Effort: ~4 hours. Impact: maintainability, not correctness.

11. **Remove `ControllerManager` / `SteamHandoffMonitor` / `AppEnvironment` observer leaks** — All benign (app-lifetime objects). Add `deinit` cleanup if the objects ever become recreatable. Effort: ~30 min. Impact: nil today.

12. **Migrate `CLIUnitTest` to XCTest** — Only if Xcode becomes available. The CLI harness is sufficient. Effort: ~2 hours (mechanical). Impact: enables `XCTestExpectation` for async tests.

13. **Fix stale docs** (`AGENTS.md` module map, `README.md` app name, `Info.plist` accessibility string) — per `review-current-tree.md §6`. Not verified in this audit but flagged as still-open.

---

## 6. Agent Hazard Map

### If you touch X, also check Y

#### `EmulatorSession.swift` (the core binding — highest hazard)

- **Touching `EmulatorSession.active` / `setActive`**: You are modifying the process-global callback router. Every `@convention(c)` callback (`gd_video`, `gd_audio`, `gd_audio_batch`, `gd_input_poll`, `gd_input_state`, `gd_environment`) routes through `EmulatorSession.active?.handle...`. If you change the set/clear sequence, callbacks may route to a dead session. **Also check**: `emulatorLoadQueue` serialization in `AppEnvironment+Launch.swift` (load at `:129`, teardown at `:189`), and the parallel pattern in `RCClientService.active`.

- **Touching `teardown()` / `requestStop()`**: The `coreThreadStuck` path (`:584-593`) intentionally *leaks* the core (skips `dlclose`/`deinit`) when the core thread doesn't join within 2s. If you "fix" the leak, you reintroduce use-after-unmap. **Also check**: that `EmulatorSession.setActive(nil)` is still called before `return` in the stuck path (`:587`).

- **Touching `handleHWRenderRequest`**: The `context_reset` is *deferred* to just before the first `retro_run` (`:735-738`), not called inside the env handler. PPSSPP segfaults if you call it earlier (its context object isn't finalized until after `load_game`). **Also check**: `hwContextResetDone` flag in `runLoop` (`:385-389`).

- **Touching `load()`**: `setActive(self)` must happen BEFORE `retro_init` (`:225`) so the core's environment/input callbacks during init can reach the session. Environment strings (`systemDirectory`, `saveDirectory`, `libretroPath`) must be set before `retro_init` (`:234-236`) because cores query them during init. **Also check**: `RetroEnvironment.ensureCStringBuffer` — the `[CChar]` buffers must survive the session lifetime (they do — stored in the struct).

- **Touching `runLoop()` pacing**: The `Thread.sleep(forTimeInterval:)` at `:427` uses `Double(remaining) / 1_000_000_000`. If `remaining` is 0, the thread busy-loops. If it's huge, the thread sleeps too long. The `next = now` resync at `:430` handles the "fell behind" case. **Also check**: `pausedFlag` (`:372`) — paused loop sleeps 50ms and continues, not breaks.

#### `RetroEnvironment.swift` (the env command dispatcher)

- **Touching any `case` in `handle(cmd:data:)`**: Every case does pointer arithmetic (`data.assumingMemoryBound(to: ...).pointee`). A wrong type assumption corrupts memory. **Also check**: the command value matches `CLibretro.RETRO_ENVIRONMENT_*` — several carry the `0x10000` EXPERIMENTAL bit, so `UInt32(RETRO_ENVIRONMENT_X.rawValue)` is the safe comparison form (used throughout).

- **Touching `GET_CAN_DUPE`** (`:35-40`): Writes a Swift `Bool` (1 byte), NOT a `UInt32` (4 bytes). Writing 4 bytes here corrupts adjacent memory. The comment says this. Don't "simplify" it.

- **Touching `GET_SYSTEM_DIRECTORY` / `GET_SAVE_DIRECTORY` / `GET_LIBRETRO_PATH`**: These write a `const char**` pointer into `data`, backed by a stable `[CChar]` buffer owned by the struct. If you move the buffer or make it a local, the pointer dangles. **Also check**: `ensureCStringBuffer` only allocates once (line 222: `if source == nil`) — if the backing `String?` changes after the first call, the buffer is stale. Today the paths are set once in `load()` and never change.

#### `ControllerManager.swift` (input mapping)

- **Touching `hook(_ pad:controller:)` button mappings**: The libretro IDs (`8`, `0`, `9`, `1`, `4-7`, `10-13`, `14-15`, `2-3`) are `RETRO_DEVICE_ID_JOYPAD_*` constants. **Also check**: that `uiAction` is correct — `.confirm` on Cross (A), `.back` on Circle (B), `nil` on Square/Triangle (core-only). Getting A/B swapped makes the launcher unusable with a gamepad.

- **Touching `hookSystemButtons`**: The PS/Share button probing is name-based and device-specific. The `haystack.contains("ps")` check (`:221`) is fragile — a future DualSense firmware could rename the element. **Also check**: `disableHomeSystemGesture` (`:87-94`) must run before probing, or the PS button stays reserved by macOS.

- **Touching `driveStickNav`**: The hysteresis thresholds (`stickActivateThreshold = 0.65`, `stickReleaseThreshold = 0.30`) prevent jitter. If you change one, change both — a release threshold higher than the activate threshold causes stuck navigation.

#### `ArtworkLoader.swift` (the image cache)

- **Touching `load(_ entry: kind: fallback:)`**: The resolution order is disk-cache → local → remote → fallback. The `failed` tombstone is checked at entry (`:80`) and set on permanent miss (`:112`). **Also check**: `inflight` — all mutations (insert at `:124`/`:288`, remove at `:130`/`:292`) must be on the same thread. Today they're all main-thread (the decode completion and URLSession completion both hop to `DispatchQueue.main.async`). If you move `load()` off-main, `inflight` needs a lock.

- **Touching `store(_ key: _ img:)`**: The LRU eviction (`:270-273`) removes from `cacheOrder` and `cache` together. If you change one, change both — a key in `cacheOrder` but not `cache` (or vice versa) breaks `touch()` or causes a stale image.

#### `CoreOptionsModel.swift` (the options overlay model)

- **Touching any method that calls `publish()`**: `publish()` (`:222-239`) acquires `lock` to snapshot, then releases it, then hops to main to set `@Published` state. **NSLock is not reentrant** — if you call `publish()` while `lock` is held, the app deadlocks. Every caller (`ingest`, `setValue`, `moveCursor`, `cycleValue`, `resetOverrides`, `activateResetRow`) does `lock.lock() ... lock.unlock()` then `publish()`. If you add a method, follow the same two-phase pattern.

- **Touching `writeBuffer(key:token:def:)`**: The stable `UnsafeMutablePointer<CChar>` buffers are handed to cores via `readValue(forKey:)` (`:96-100`). The pointer must stay valid for the session. If you free a buffer early, the core reads freed memory. **Also check**: `deinit` (`:241-245`) frees all buffers — this must only run after the core is unloaded.

#### `FrameSlot.swift` (the frame buffer)

- **Touching `push()`**: The `format` parameter is used for conversion (line 40), and `self.format` is set after (line 51). The `dstBytes = width * height * 4` assumes 4 bytes/pixel (BGRA after conversion). If you add a format that isn't 4bpp, the allocation is wrong. **Also check**: `PixelConverter.convert` — all three formats output 4bpp BGRA, so this is safe today.

- **Touching the buffer realloc** (`:32-36`): Only grows, never shrinks. If a core switches to a smaller resolution, the buffer is over-allocated (wasteful, not wrong). If a core switches to a *larger* resolution, it reallocates. **Also check**: `withLatest` returns `width * 4` as `rowBytes` (`:61`) — this is the *tightly-packed* row stride, not the source pitch. The Metal upload uses this as `bytesPerRow`. If you change the packing, update both.

#### `SettingsStore.swift` (user persistence)

- **Touching RA credentials**: The API token was migrated from Keychain to UserDefaults (`loadAPIToken` at `:75-87`). The Keychain copy is deleted on every read to clean up stale old-build items. **Also check**: `setRACredentials` (`:136-150`) also deletes the Keychain copy. If you remove the `KeychainStore.delete` calls, old-build users get a keychain prompt on every launch.

- **Touching `coreOptions`** (`:41`, `:174-191`): Nested dict `[coreID: [gameID: [optionKey: token]]]`. The `clearCoreOptions` method removes the `gameID` key but leaves the `coreID` key (possibly empty). Over time, empty `coreID` dicts accumulate. Not a bug, but if you add a "clear all core options" feature, you need to prune empty cores too.

#### `VDFParser.swift` (Steam file parsing)

- **Touching `readQuotedString` backslash handling** (`:131-149`): Only `\"`, `\\`, `\n`, `\t`, `\r` are treated as escapes; any other backslash (e.g. `D:\Games`) stays literal. This was a deliberate fix for Windows paths (`scout-steam-report.md §6.1`). If you "improve" the escaping to handle more cases, you'll corrupt Windows library paths in `libraryfolders.vdf`.

- **Touching the `Scanner` class**: It's a hand-rolled char-by-character scanner (not `Foundation.Scanner`). It allocates `[Character]` from the whole string at init (`:61`). For large VDF files (a Steam library with 500+ manifests), this is ~1MB of Characters. Fine for Steam, but if you reuse it for a larger file, switch to `String.Index` iteration.

#### `AppEnvironment.gamepad(_:)` (the input router)

- **Touching the modal cascade** (`:193-332`): The order is load-bearing: confirmation → pause menu → core options → Discord → quick bar → screenshot → base. **Also check**: that your new modal's opener guards against existing modals (like `openCoreOptions` guards `!pauseMenuVisible` at `:567` and `!isLaunchingGame` at `:567`). If you don't guard, two modals can be open and the router silently picks the higher-priority one.

- **Touching `back` action** (`:300-309`): Context-dependent — dismisses quick bar, opens pause menu (emulator), cancels in-flight boot (`exitEmulation`). If you add a new surface that traps `back`, insert it in the right place. **Also check**: `openPauseMenu` guard (`:567`) — pause menu can't open during boot (`isLaunchingGame`).

#### `EmulatorMetalView.swift` / `MetalRenderer.swift` (the render path)

- **Touching `MetalRenderer.draw(in:)`**: The `texture.replace(...)` call (`:95-100`) requires `bytesPerRow: rowBytes` where `rowBytes = width * 4` (from `FrameSlot.withLatest`). If `FrameSlot` changes its packing, the Metal upload breaks with a silent black screen (no crash — just wrong texture).

- **Touching the shader source** (`:23-62`): It's a string compiled at runtime via `device.makeLibrary(source:)`. If the MSL is invalid, `makeLibrary` throws (caught by `try?` at `:72`), `pipelineState` is nil, and `init?` returns nil → `EmulatorMetalView` falls back to `FallbackFrameView`. The error is silent (only `Log.error` if you add it). **Also check**: the `FrameUniforms` struct layout (`:6-8`) must match the MSL struct (`:32-35`) — both have `float2 scale`. If you add a field to one, add it to the other in the same position.

---

## Appendix: Prior audit findings — current status

Cross-checked against `audit-v2.md`, `review-current-tree.md`, `audit-preview-qol.md`:

| Finding | Source | Status | Evidence |
|---|---|---|---|
| RA game never loaded | `audit-v2 §1.1` | **Fixed** | `EmulatorSession.startRetroAchievements` (`:320-335`) calls `service.beginLoadGame(path: romPath, data: romData ?? Data())` |
| dlclose of live stuck core | `audit-v2 §1.2` | **Fixed** | `coreThreadStuck` path (`EmulatorSession.swift:584-593`) leaks the core instead of unmapping |
| ArtworkLoader permanent failed tombstone | `review §1.6` | **Fixed** | `failedRetryInterval = 60` with dated tombstones (`ArtworkLoader.swift:32`) |
| ArtworkLoader inflight race | `review §1.1` | **Fixed** | All `inflight` mutations now on main thread (decode/URLSession completions hop to `DispatchQueue.main.async`) |
| VolumeController no device-change listener | `review §1.2` | **Fixed** | `installDeviceListener()` + `handleDefaultDeviceChanged()` (`VolumeController.swift:114-138`) |
| LibraryStore drops concurrent scans | `review §1.4` | **Fixed** | `needsAnotherScan` coalescing (`LibraryStore.swift:21, 51-54, 65-68`) |
| Haptics engine cache unbounded | `review §1.5` | **Fixed** | `removeEngines(for:)` called on disconnect (`Haptics.swift:47-49`, `ControllerManager.swift:63`) |
| ArtworkLoader NSImage decode for aspect check | `audit-preview-qol §CR-04` | **Fixed** | Uses `CGImageSourceCreateWithURL` + `CGImageSourceCopyPropertiesAtIndex` (`ArtworkLoader.swift:171-178`) |
| ScreenshotController DateFormatter per-call | `audit-preview-qol §CR-03` | **Fixed** | `private static let filenameFormatter` (`ScreenshotController.swift:85-89`) |
| Off-main emulator load/teardown | `review §2.2` | **Fixed** | `emulatorLoadQueue.async` in `startEmulator` and `exitEmulation` (`AppEnvironment+Launch.swift:129, 189`) |
| RetroAudioEngine start/stop race | `review §P2-5` | **Fixed** | `lifecycleQueue.sync` serializes start/stop (`RetroAudioEngine.swift:106, 115, 142`) |
| SteamScreenshotStore inflight leak | `audit-preview-qol §CR-01` | **Fixed** | Generation counter (`SteamScreenshotStore.swift:26-27, 44-45, 56-58`) |
| SteamGridDBStore inflight race | (new finding) | **Open** | No generation counter (`SteamGridDBStore.swift:21, 39-47`) — see §3.4.5 |
| Info.plist mic permission | `review §1.3` | **Open** | Not verified (Info.plist not in reading list) |
| AGENTS.md / README.md stale | `review §6` | **Open** | Not verified |
| SettingsNavModel.selection dead | `review §P3-6` | **Open** | Confirmed (not read by any view) |
| PPSSPP stop() uses SIGTERM | `review §P3-8` | **Open** | `StandaloneEmulatorLauncher.stop()` uses `process?.terminate()` (`:95`) |
| Package.swift spurious excludes | `review §5` | **Open** | Not verified (Package.swift not fully read) |
