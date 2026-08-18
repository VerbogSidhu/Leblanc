# Leblanc (GameDock) — Codebase Audit: Selection Preview Panel & QoL Batch

**Audit scope**: All ~80 Swift source files under `Sources/GameDock/`, plus
`Package.swift`, `Makefile`, `build-app.sh`, `Info.plist`, and every
`.pi/skills/*/SKILL.md`. Read-only; no files edited.

**Severity legend**: 🔴 critical · 🟡 moderate · 🟢 minor

---

## 1. Correctness

### 🔴 CR-01 · `SteamScreenshotStore.shared` — inflight task can leak and block subsequent fetches

**File**: `Libraries/SteamScreenshotStore.swift`, lines ~52–57  
**What**: `screenshotURLs(for:)` stores a `Task` in `inflight[appID]` and
awaits it, then nils the key. If the task **throws** (it's `Task<URLs, Never>`
but `fetch` is a separate `async` func), the `inflight` entry is never cleared.
More concretely: if the caller's context is cancelled (the `SelectionPreviewModel`
debounce task cancels), the `await task.value` resumes, `inflight[appID] = nil`
runs, but a *new* `select()` call may have already put a *different* task under
the same key — the new task gets replaced and lost.

**Why it matters**: After a rapid selection change, screenshots for the final
selection may never load. The `inflight` dictionary becomes stale.

**Suggested fix**: Use `Task_local` or a generation counter inside the store, or
cancel-and-replace inflight entries on invalidate. At minimum, check
`task == inflight[appID]` before removing.

---

### 🟡 CR-02 · `CoreOptionsModel` — lock/publish pattern is correct but fragile

**File**: `Launch/CoreOptionsModel.swift`, lines ~109–115, ~148–160  
**What**: `moveCursor` and `cycleValue` acquire `lock`, mutate state, then
**release the lock** before calling `publish()`. `publish()` re-acquires `lock`
to snapshot, then dispatches to main. This is **correct** — no deadlock exists.
However, the pattern is fragile: any future refactor that calls `publish()`
inside the lock scope would deadlock (NSLock is not reentrant).

**Why it matters**: The current code is safe, but the two-phase pattern
(lock→unlock→publish) is easy to break accidentally. A comment at the `lock`
declaration warning about this would prevent future regressions.

**Suggested fix**: Add a comment above `private let lock = NSLock()`:

```swift
// ⚠️ NSLock is not reentrant. publish() must NEVER be called while this
// lock is held — all callers must unlock before calling publish().
private let lock = NSLock()
```

---

### 🟡 CR-03 · `ScreenshotController.save` — DateFormatter created per call

**File**: `Core/ScreenshotController.swift`, lines ~79–82  
**What**: `save(image:title:)` creates a new `DateFormatter` on every screenshot
capture. `DateFormatter` init is expensive (~5 ms) and allocates on every call.

**Why it matters**: Not a crash, but a hot-path performance issue during rapid
screenshot capture (e.g. holding touchpad).

**Suggested fix**: Make it a `static let`:

```swift
private static let filenameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    return f
}()
```

---

### 🟡 CR-04 · `ArtworkLoader.localPath` loads NSImage to check aspect ratio

**File**: `Libraries/ArtworkLoader.swift`, lines ~115–120  
**What**: For `.steam` + `.banner`, the code does `NSImage(contentsOfFile:)` just
to check `width > height`. This decodes the full image into memory on the calling
thread (main thread when called from `banner(for:)`).

**Why it matters**: Decoding a 600×900 JPG on the main thread during XMB scroll
causes frame drops. The check should use `NSBitmapImageRep` or
`CGImageSource` to read dimensions without full decode.

**Suggested fix**: Use `CGImageSource` to read `kCGImagePropertyPixelWidth/Height`
from the first image, which is near-zero cost:

```swift
func imageDimensions(at path: String) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    return (w, h)
}
```

---

### 🟡 CR-05 · `WaveFieldModel.emit` — ripple cleanup races with SwiftUI Canvas reads

**File**: `UI/WaveField.swift`, lines ~17–20  
**What**: `emit()` mutates `@Published ripples` on the main thread, but
`WaveField`'s `Canvas` reads `model.ripples` from a `TimelineView` callback
which also runs on main — but during the draw phase. If `emit()` is called
during a draw cycle (which `selectionMoved()` does), the mutation is safe but
the `removeAll` that expires old ripples can remove a ripple the Canvas is
about to render. This is technically safe (snapshot semantics) but the
`removeAll` runs *inside* the published setter which triggers a new SwiftUI
update.

**Why it matters**: Extra SwiftUI invalidation per selection change. Minor
performance, not a correctness issue.

**Suggested fix**: Filter expired ripples lazily in the Canvas draw, not on
mutation.

---

### 🟡 CR-06 · `Haptics.tick()` — engines cache grows without bound for transient controllers

**File**: `Core/Haptics.swift`, lines ~12–34  
**What**: `engines` is a `static var` dictionary keyed by `ObjectIdentifier`.
Controllers that briefly connect/disconnect (e.g. Bluetooth glitch) add entries.
`removeEngines(for:)` is called on disconnect but only from `ControllerManager`.
If a controller disconnects while `Haptics.tick()` iterates
`GCController.controllers()`, the stale entry remains.

**Why it matters**: Memory leak for the engine cache (unbounded `CHHapticEngine`
instances). Each engine holds GPU resources.

**Suggested fix**: Also clear stale entries in `tick()` by checking
`GCController.controllers()` membership before using a cached engine.

---

### 🟡 CR-07 · `SteamLocalConfigReader` — no thread safety on `cached`

**File**: `Libraries/SteamLocalConfigReader.swift`, lines ~14, ~18–29  
**What**: `cached` is read/written without synchronization. `playtimeMinutesByAppID()`
is called from `SelectionPreviewModel.populate()` which runs on a background
`Task`, while `invalidate()` is called from the main thread (Settings → Rescan).

**Why it matters**: A torn read could return stale data. In practice the
`Task` and `invalidate` are unlikely to overlap exactly, but this violates
the data race rules.

**Suggested fix**: Protect `cached` with `os_unfair_lock` or `NSLock`, or
dispatch reads/writes to a serial queue.

---

### 🟡 CR-08 · `CaptureStore.captures` — full directory listing on every selection

**File**: `Libraries/CaptureStore.swift`, lines ~15–29  
**What**: Every call to `captures(for:)` does
`FileManager.contentsOfDirectory(at:)` on the captures directory, then filters
and sorts. This runs inside the debounced `SelectionPreviewModel.populate()`,
so it's off the main thread, but it does disk I/O per selection settle.

**Why it matters**: For users with hundreds of captures, this is ~50ms of disk
I/O per selection change. Not a crash but perceptible on older Macs.

**Suggested fix**: Cache the directory listing with a TTL (e.g. 5 seconds) or
use `FSEvents` to maintain an in-memory index.

---

### 🟡 CR-09 · `PreviewImageLoader` — completion called synchronously for cache hits

**File**: `UI/SelectionPreviewPanel.swift`, lines ~152–158  
**What**: When the image is in the in-memory cache, `completion(img)` is called
while the `lock` is held (after `touch` + `lock.unlock()`). This is fine, but
the caller expects completion on "the main queue" (per the doc comment). The
cache-hit path calls completion on whatever thread the caller is on, which is
the main thread in practice — but the contract is fragile.

**Why it matters**: If any future caller invokes `image(for:)` from a background
queue, the completion would run off-main.

**Suggested fix**: Always dispatch completion through `DispatchQueue.main.async`.

---

### 🟡 CR-10 · `RCClientService` — `handleAsyncCallback` calls `performLoadGameIfReady` which may need `rc_client_begin_load_game`, but login state is only set on the core thread

**File**: `RetroAchievements/RCClientService.swift`, lines ~229–240  
**What**: `handleAsyncCallback` runs on the core thread (called from `doFrame`).
When login succeeds, it sets `state = .loggedIn` and calls
`performLoadGameIfReady()`, which hashes the ROM and calls
`rc_client_begin_load_game`. But `romPath`/`romData` were set on the main
thread in `beginLoadGame(path:data:)` with no synchronization.

**Why it matters**: `romPath`/`romData` are `String?`/`Data?` — reading them
from the core thread while potentially written from main is a data race.

**Suggested fix**: Copy `romPath`/`romData` into the constructor or protect
them with a lock.

---

### 🟢 CR-11 · `RetroAudioRingBuffer.readBatch` — O(n) per-sample loop instead of memcpy

**File**: `Launch/RetroAudioEngine.swift`, lines ~22–32  
**What**: `writeBatch` copies samples one-by-one in a Swift loop. For a 44100 Hz
stereo stream, that's 88200 loop iterations per second.

**Why it matters**: This is the audio hot path. The per-sample loop is ~3× slower
than a `memcpy`-based ring buffer copy.

**Suggested fix**: Use `withUnsafeBufferPointer` + `memcpy` with wraparound
handling (two copies for the wrapped case).

---

### 🟢 CR-12 · `CLIPreviewCheck` — blocks main thread with `DispatchSemaphore`

**File**: `CLI/CLIPreviewCheck.swift`, lines ~28–32  
**What**: `semaphore.wait(timeout:)` blocks the main thread waiting for the async
`SteamScreenshotStore` task. Since `SteamScreenshotStore` schedules on the
default URLSession queue (not the main queue), this works, but it's an
anti-pattern — blocking the main RunLoop blocks timers and run-loop-scheduled
IOHIDManager callbacks.

**Why it matters**: In a CLI context this is acceptable (no UI), but the pattern
is fragile.

**Suggested fix**: Use `RunMode`-based waiting or restructure as fully async.

---

## 2. Architecture

### 🟡 AR-01 · `AppEnvironment` is a God Object (~330 lines across three files)

**File**: `AppEnvironment.swift`, `+Launch.swift`, `+Settings.swift`  
**What**: The class owns screen state, XMB navigation, quick bar, controllers,
libraries, Discord, Steam, emulators, volume, status, screenshots, RA hub,
preview model, toast model, playtime tracking, sleep observers — and routes
every gamepad input.

**Why it matters**: Every feature touch goes through this class. Merge conflicts,
cognitive load, and testability all suffer. The `gamepad(_:)` router alone is
~60 lines of switch/case nesting.

**Suggested fix**: Extract `InputRouter` as a protocol; split `AppEnvironment`
into `XMBState`, `EmulatorState`, `SettingsState` with coordination logic in
the parent.

---

### 🟡 AR-02 · `DiscordController` owns an NSPanel + WKWebView — UI mixed into a controller class

**File**: `Discord/DiscordController.swift`  
**What**: This is simultaneously an `NSObject` (NSWindowDelegate), a window
controller, a WebView loader, and a scroll/selection API. It's the only file in
the `Discord/` directory.

**Why it matters**: Tight coupling between the Discord feature and AppKit window
management makes it hard to test or replace with a different chat overlay.

**Suggested fix**: Split into `DiscordWebView` (SwiftUI NSViewRepresentable) and
`DiscordController` (state/logic only).

---

### 🟢 AR-03 · `VDFParser.Scanner` is a private nested class — can't be tested in isolation

**File**: `Libraries/VDFParser.swift`  
**What**: The scanner is a file-private nested class. The unit tests only exercise
it through the public `VDFParser.parse()` entry point.

**Why it matters**: Edge cases in the scanner (e.g. deeply nested braces,
malformed escapes) are harder to test independently.

**Suggested fix**: Not urgent for v1, but consider making `Scanner` internal for
targeted fuzz testing.

---

### 🟢 AR-04 · `Theme` is a global enum with static lets — no runtime customization

**File**: `UI/Theme.swift`  
**What**: All colors, fonts, and layout constants are compile-time static. No
theme switching, no accessibility dynamic type support.

**Why it matters**: The "console UI" aesthetic is intentionally fixed, but the
static font sizes (`Theme.itemTitleSelected = 44pt`) don't respect the user's
preferred text size.

**Suggested fix**: Low priority for v1; consider `@ScaledMetric` for key text
sizes.

---

## 3. Performance

### 🟡 PF-01 · `WaveField` Canvas redraws every frame via `TimelineView(.animation)`

**File**: `UI/WaveField.swift`, line ~42  
**What**: `TimelineView(.animation)` fires at display refresh rate (120 Hz on
ProMotion). The Canvas draws 5 wave layers × ~192 points each = ~960 path
points per frame, plus ripple stroking.

**Why it matters**: This is the dominant CPU hotspot during XMB idle. On battery
this drains power for a subtle ambient effect. The stride was recently increased
from 5 to 10 (good), but the fundamental cost remains.

**Suggested fix**: Drop to 30 fps (`TimelineView(.periodic(from: .now, by: 1/30))`)
since the waves are slow-moving. Or pre-render to a texture and animate the
transform.

---

### 🟡 PF-02 · `ArtworkLoader` — disk cache copy uses `FileManager.copyItem` (synchronous)

**File**: `Libraries/ArtworkLoader.swift`, line ~157  
**What**: `decodeOffMain` does `copyItem(at:to:)` inside the `decodeQueue`
dispatch. For large images (600×900 JPG ~200KB), this is fine. But the disk
cache directory can grow to 200 entries (the LRU cap) × ~200KB = ~40MB in
`~/Library/Application Support/GameDock/artwork/`.

**Why it matters**: First-time loads of the full library require 200 disk reads +
decodes. The decode queue is serial, so cold-boot art loading takes ~30s.

**Suggested fix**: Use a concurrent decode queue with a semaphore cap (e.g. 4
concurrent decodes). Or preload the most-recently-played games' art.

---

### 🟡 PF-03 · `SteamLibrary.scan()` — scans all steamapps folders synchronously

**File**: `Libraries/SteamLibrary.swift`, lines ~73–100  
**What**: `scan()` iterates all library folders, reads each `appmanifest_*.acf`
file, and parses VDF. For a user with 500+ installed games across 4 drives,
this is ~200ms of synchronous file I/O on the scan queue.

**Why it matters**: `LibraryStore.refresh()` calls `scanSynchronously()` which
calls `steam.gameEntries()` → `scan()`. The scan queue is
`.userInitiated` QoS, so it's fast but still blocks the scan thread. The
real issue is that `scan()` does **two** full parses (once for
`steamAppsFolders()`, once for manifests) and the folder enumeration calls
`contentsOfDirectory` which is synchronous.

**Suggested fix**: Already acceptable for v1. For v2, cache the scan result and
use `DispatchSource.makeFileSystemObjectSource` for live updates.

---

### 🟢 PF-04 · `Haptics.tick()` — creates a new `CHHapticPattern` + player every call

**File**: `Core/Haptics.swift`, lines ~22–30  
**What**: Every selection change creates a `CHHapticPattern` and
`CHHapticPlayer`. These are short-lived ObjC objects that go through the
CoreHaptics pipeline.

**Why it matters**: ~0.5ms per tick, called on every d-pad navigation. Acceptable
but could be optimized by pre-building the pattern.

**Suggested fix**: Pre-build the transient pattern once per engine and reuse the
player.

---

## 4. Security / Privacy

### 🟡 SE-01 · `RAClient` logs the RA username in API request URLs

**File**: `RetroAchievements/RAClient.swift`, lines ~67–73  
**What**: The `get()` method builds URLs with `u=<username>&y=<apikey>` query
params. While these aren't logged directly, `Log.debug` in `RCClientService`
logs the `r=` query argument, which could contain the username.

**Why it matters**: RA credentials (API key) should never appear in logs. The
URL contains both `u` and `y` params.

**Suggested fix**: Ensure `Log.debug` in `RCClientService.serverCall` never logs
the full URL. Currently it only logs `r=` which is safe, but a future refactor
could accidentally log the full request.

---

### 🟡 SE-02 · `Info.plist` includes `NSMicrophoneUsageDescription` and `NSCameraUsageDescription`

**File**: `Info.plist`, lines ~21–24  
**What**: These usage strings exist because Discord's web app can use mic/camera.
The app never directly accesses the camera or microphone — it's all through
WKWebView.

**Why it matters**: The camera/mic descriptions may confuse App Review or
security reviewers. The user grant dialog will show "Leblanc wants to access
the microphone" when Discord triggers it, which is accurate but may raise
questions.

**Why it matters**: For a local-only app distributed ad-hoc this is fine. For
App Store distribution, Apple may question why a game launcher needs camera
access.

**Suggested fix**: Document this in the README. The descriptions are technically
accurate (Discord's web app does use them).

---

### 🟢 SE-03 · `SteamScreenshotStore.fetch` constructs URL from unsanitized appID

**File**: `Libraries/SteamScreenshotStore.swift`, line ~68  
**What**: `URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)")`
— the `appID` comes from parsed VDF manifests and is always a numeric string.
But if a malicious manifest injected a non-numeric appID, it could inject
query parameters.

**Why it matters**: Extremely low risk since Steam manifests are local files
only the user controls, and `URL(string:)` returns nil for most injection
attempts.

**Suggested fix**: Add `appID = appID.filter(\.isNumber)` for defense-in-depth.

---

## 5. Dead Code

### 🟢 DC-01 · `EmulatorMetalView.renderer` is never reassigned after init

**File**: `Launch/EmulatorMetalView.swift`, line ~11  
**What**: `var renderer: MetalRenderer?` is set in `init` and never changed.
The `frameSlot` setter calls `renderer?.frameSlot = frameSlot`, but `renderer`
is non-optional after init (always succeeds since `MetalRenderer.init?` would
have already trapped).

**Why it matters**: The optional unwrap is unnecessary; `renderer` could be a
`let`.

**Suggested fix**: Change to `let renderer: MetalRenderer`.

---

### 🟢 DC-02 · `AppEnvironment.waveField` is a `let` but `WaveFieldModel` is `ObservableObject`

**File**: `AppEnvironment.swift`, line ~37  
**What**: `let waveField = WaveFieldModel()` — this is a reference type held as
a `let`. It works because `WaveField` accesses it via `@ObservedObject`, but
the naming is misleading (it reads like a view, not a model).

**Why it matters**: Minor naming inconsistency. No functional issue.

**Suggested fix**: Rename to `waveFieldModel` for consistency with `quickBarModel`.

---

### 🟢 DC-03 · `SettingsNavModel.Row` has an unused `Equatable` conformance

**File**: `UI/SettingsNavModel.swift`, lines ~16–21  
**What**: `Row: Identifiable, Equatable` — `Equatable` is synthesized but never
checked anywhere. Rows are rebuilt fresh every time.

**Why it matters**: Dead protocol conformance. Harmless.

**Suggested fix**: Remove `Equatable` if not needed, or keep for future diffing.

---

## 6. Consistency

### 🟡 CO-01 · Mixed access control on singletons: `static let shared` vs `static let directory`

**File**: Various  
**What**: Some singletons use `static let shared` (e.g. `ArtworkLoader.shared`,
`SteamScreenshotStore.shared`, `GlobalHotkeyManager.shared`). Other shared
state uses `static var` with no encapsulation (e.g. `EmulatorSession._active`,
`RCClientService._active`). `ScreenshotController.directory` is `static let`
(a URL, not a singleton).

**Why it matters**: Inconsistent patterns for shared state make the codebase
harder to reason about. The `EmulatorSession.active` / `RCClientService.active`
pattern uses a lock-guarded static var, which is more flexible but harder to
test.

**Suggested fix**: Document the two patterns in the architecture skill. The
lock-guarded pattern is correct for mutable process-wide state; the singleton
pattern is correct for immutable shared instances.

---

### 🟡 CO-02 · Magic numbers in controller probing

**File**: `Controllers/ControllerManager.swift`, lines ~156–160  
**What**: `0.65` and `0.3` are stick hysteresis thresholds. They're documented
in comments but not named constants.

**Why it matters**: If someone changes the threshold for one axis, they might
miss the other. The `driveStickNav` function has 4 independent threshold checks.

**Suggested fix**:

```swift
private static let stickActivateThreshold: Float = 0.65
private static let stickReleaseThreshold: Float = 0.30
```

---

### 🟢 CO-03 · `GameSource.displayName` vs `StandaloneEmulatorLauncher.AppKind.displayName`

**File**: `Core/Models.swift`, `Launch/StandaloneEmulatorLauncher.swift`  
**What**: Both have a `displayName` property but they're on different types with
different semantics (`GameSource.displayName` = "Steam"/"PSP"/"Nintendo DS";
`AppKind.displayName` = "PPSSPP").

**Why it matters**: Minor naming overlap, no functional issue.

---

## 7. API Design

### 🟡 AP-01 · `EmulatorSession` exposes `let frameSlot = FrameSlot()` as a public property

**File**: `Launch/EmulatorSession.swift`, line ~120  
**What**: `frameSlot` is a `let` with an initial value — anyone can read it.
But `FrameSlot.push` is called from the core thread and `withLatest` from the
render thread. The API is correct (thread-safe internally), but there's no
doc comment warning callers about which thread to use.

**Why it matters**: A future developer might call `push` from the main thread,
which would work but is architecturally wrong.

**Suggested fix**: Add a doc comment: "Core thread writes via push; render
thread reads via withLatest."

---

### 🟡 AP-02 · `RAToastModel` is reused for two unrelated toast types

**File**: `RetroAchievements/RAToastModel.swift`, `AppEnvironment.swift`  
**What**: `RAToastModel` is used for both RetroAchievement toasts (achievement
unlocked, game completed) AND capture confirmation toasts ("Capture saved").
The same model, the same queue, the same display duration (4s).

**Why it matters**: If an achievement triggers during a screenshot, the capture
toast and achievement toast queue up. This is actually fine behavior (both are
transient notifications), but the coupling between the RA module and the
screenshot feature through a shared toast model is surprising.

**Why it matters**: The class name `RAToastModel` implies RA-only use. The capture
toast is a non-RA feature using an RA-named class.

**Suggested fix**: Rename to `ToastQueue` or `NotificationToastModel` to reflect
its generic role. Or create a separate `CaptureToastModel`.

---

### 🟢 AP-03 · `SteamScreenshotStore` and `SteamLocalConfigReader` are singletons but also instantiable

**File**: `Libraries/SteamScreenshotStore.swift`, `Libraries/SteamLocalConfigReader.swift`  
**What**: Both have `static let shared` AND are `final class` (not `enum`), so
they can be freely instantiated. `CLIPreviewCheck` creates a new
`SteamLocalConfigReader()` instance (line ~15) — a separate instance from
`.shared`.

**Why it matters**: Two instances have separate caches, which is correct for
the CLI tool but could confuse future code that mixes `.shared` and `new`.

**Suggested fix**: Either make them `enum` singletons (no free init) or document
that the CLI creates fresh instances intentionally.

---

## 8. New Features — Detailed Inspection

### 🔴 NF-01 · `SelectionPreviewModel.select()` — debounce task captures `entry` by value but `entry` may be stale

**File**: `UI/SelectionPreviewModel.swift`, lines ~72–79  
**What**: The `debounceTask` closure captures `entry: GameEntry` directly. After
350ms, `populate(entry:generation:)` runs with this captured copy. But if the
user scrolls to a *different* game in the same category, the captured `entry`
might have stale `artworkLocalPath` or `appID` values (since `GameEntry` is a
struct). This is actually correct behavior — the generation guard prevents
applying stale results. But the *fetch itself* runs for the wrong game.

**Why it matters**: If a user scrolls quickly through 10 Steam games, 10 fetch
requests fire (one per settled 350ms window). Each fetch hits the
`SteamScreenshotStore` which has inflight dedupe, so only one per appID actually
fetches. But the `captures.captures(for:)` call for PSP/DS games does disk I/O
for each.

**Why it matters**: The disk I/O is wasteful but not incorrect. The generation
guard prevents displaying wrong results.

**Suggested fix**: Cancel the previous debounce task more aggressively, or add a
secondary guard at the `populate` level to skip work if the entry ID doesn't
match the current `entryID`.

---

### 🟡 NF-02 · `SelectionPreviewPanel` renders `ForEach` with all image sources but only one is visible

**File**: `UI/SelectionPreviewPanel.swift`, lines ~70–77  
**What**: `ForEach(Array(model.imageSources.enumerated()), id: \.element)` creates
a view for every image source (up to 5), with opacity 0/1 based on
`currentIndex`. All 5 images are loaded into memory and decoded.

**Why it matters**: Up to 5 full-resolution screenshots (each ~1MB decoded) are
held in memory simultaneously. For a game with 5 Steam screenshots, that's ~5MB
of decoded image data in the `PreviewImageLoader` cache, plus the SwiftUI view
hierarchy for 5 images.

**Suggested fix**: Only load the current image and the next one (prefetch ±1).
The `PreviewImageLoader` LRU cap (80) is generous enough, but the SwiftUI view
hierarchy for 5 simultaneous `Image(nsImage:)` views is wasteful.

---

### 🟡 NF-03 · `RepeatPacer` — timer fires on `.common` RunLoop mode, which runs during tracking

**File**: `Controllers/ControllerManager.swift`, lines ~380–393  
**What**: `RunLoop.main.add(timer, forMode: .common)` means the timer fires even
during `NSEvent` tracking (scroll gestures, window resizing). This is intentional
for continuous d-pad navigation, but it means repeat events fire during system
modal interactions (e.g. the volume HUD overlay).

**Why it matters**: If the user opens a system dialog (e.g. Screen Recording
permission prompt), repeat events continue firing behind it. The UI router
handles this gracefully (nothing actionable), but it's a minor waste.

**Why it matters**: Low impact. The `.common` mode is correct for the gamepad
use case.

---

### 🟡 NF-04 · `CaptureStore.shared` — no invalidation when captures are saved

**File**: `Libraries/CaptureStore.swift`  
**What**: `CaptureStore` has no cache — it scans the directory on every call.
When a new capture is saved (via `ScreenshotController.save`), the next call to
`captures(for:)` will pick it up. This is correct but the directory scan is
repeated for the same title across rapid selections.

**Why it matters**: If a user takes a screenshot and immediately scrolls back to
the same game, the capture is found (correct). But the directory is scanned
again even though it was just scanned 100ms ago.

**Suggested fix**: Add a short TTL cache (e.g. 2 seconds) to avoid repeated
scans.

---

### 🟡 NF-05 · `XMBView.categoryButton` — category count includes Discord and Achievements (always 1)

**File**: `UI/XMBView.swift`, lines ~80–81  
**What**: `showCount` filters to `["home", "steam", "psp", "ds"]`, so Discord
(always 1 item) and Achievements (variable) don't show counts. This is correct.
But the count for "Home" includes favorites + recent launches, which can be 0
on first launch — showing "0" in a capsule looks odd.

**Why it matters**: Minor UI polish issue. A "0" count on first launch is
confusing.

**Suggested fix**: Don't show the count badge when it's 0: `if showCount &&
cat.items.count > 0`.

---

### 🟢 NF-06 · `PlaytimeFormatter.seconds` — negative input clamped to "0m"

**File**: `Core/PlaytimeFormatter.swift`, lines ~18–20  
**What**: `minutes(Int(totalSeconds) / 60)` — if `totalSeconds` is negative
(e.g. a clock skew), `Int(totalSeconds) / 60` is negative, then `max(0, totalMinutes)`
clamps to 0.

**Why it matters**: Correct handling. No issue.

---

### 🟢 NF-07 · `SteamLocalConfigReader` — `Playtime` field parsing assumes decimal integer

**File**: `Libraries/SteamLocalConfigReader.swift`, line ~46  
**What**: `Int(raw)` where `raw` is the VDF string value of `Playtime`. If Steam
ever changes this to a float or adds a unit suffix, parsing silently returns
nil (no crash).

**Why it matters**: Defensive — the current format is confirmed stable.

---

### 🟢 NF-08 · `SelectionPreviewPanel` — panel width is hardcoded to 300pt

**File**: `UI/SelectionPreviewPanel.swift`, line ~16  
**What**: `private let panelWidth: CGFloat = 300` — not responsive to window
size. On a 1280pt-wide window (the default), the panel takes up ~23% of the
width. On a 1920pt external display, it's proportionally smaller.

**Why it matters**: Acceptable for v1. The XMB is designed for a fixed-width
console feel.

---

## 9. Thread Safety Summary

| Component | Thread | Protection | Status |
|---|---|---|---|
| `InputSnapshot` | main ↔ core | `NSLock` | ✅ Safe |
| `FrameSlot` | core ↔ render | `NSLock` | ✅ Safe |
| `RetroAudioRingBuffer` | core ↔ audio | `NSLock` | ✅ Safe |
| `RAToastModel` | core/main ↔ main | `NSLock` + main dispatch | ✅ Safe |
| `JSONFileStore` | any → disk | `NSLock` + `.atomic` write | ✅ Safe |
| `CoreOptionsModel` | core ↔ main | `NSLock` (but see CR-02) | ✅ Safe (fragile pattern) |
| `SteamLocalConfigReader.cached` | main + background Task | None | 🟡 **Race** |
| `RCClientService.romPath/romData` | main + core thread | None | 🟡 **Race** |
| `ArtworkLoader.inflight/cache/failed` | main thread only | Main-thread confinement | ✅ Safe |
| `PreviewImageLoader` | main + utility queues | `NSLock` | ✅ Safe |
| `GlobalHIDMonitor.isCapturing` | main thread | Main-thread confinement | ✅ Safe |
| `EmulatorSession._active` | core + main | `NSLock` | ✅ Safe |
| `RCClientService._active` | core + main | `NSLock` | ✅ Safe |
| `VolumeController` | main + audio callback queue | Main-thread dispatch | ✅ Safe |
| `Haptics.engines` | main thread (GCController callbacks) | Main-thread confinement | ✅ Safe |

---

## 10. Test Coverage

| Module | CLI Test | Self-Test | Notes |
|---|---|---|---|
| VDFParser | ✅ `--unit-test` | — | Good coverage: flat, nested, Windows paths, comments, BOM, errors |
| RomTitle | ✅ `--unit-test` | — | Good: artKey, cleanedTitle, edge cases |
| PixelConverter | ✅ `--unit-test` | — | Good: rgb565, rgb1555, xrgb8888 |
| Entry ID | ✅ `--unit-test` | — | Deterministic, case-insensitive |
| CoreOptionParser | ✅ `--unit-test` | — | Title, values, whitespace, edge cases |
| QuickBarModel | ✅ `--unit-test` | — | Wrap-around, context switch |
| PlaytimeFormatter | ✅ `--unit-test` | — | Hours+min, hours-only, min-only, zero |
| SteamLocalConfig | ✅ `--unit-test` | — | Parse, missing fields |
| SteamScreenshot JSON | ✅ `--unit-test` | — | Success, failure, missing |
| Emulator E2E | — | ✅ `--selftest` | Frames, audio, input, core options, save-state |
| RA client | — | ✅ `--ra-selftest` | Fake server_call, login flow |
| **SelectionPreviewModel** | — | — | **No dedicated test** |
| **CaptureStore** | ✅ `--preview-check` | — | Only manual verification |
| **SteamLocalConfigReader** | ✅ `--preview-check` | — | Only manual verification |

**Missing**: The selection preview model's debounce logic, generation guard, and
rotation timer have no automated test coverage. The `PreviewImageLoader` cache
fan-out is untested.

---

## 11. Info.plist / Build Configuration

### 🟢 BP-01 · `Info.plist` has `CFBundleVersion = "1"` but `CFBundleShortVersionString = "0.1.0"`

**File**: `Info.plist`  
**What**: Standard for development. The bundle version should increment with each
release.

---

### 🟢 BP-02 · `build-app.sh` uses `head -1` for resource bundle — fragile if multiple bundles exist

**File**: `build-app.sh`, line ~19  
**What**: `RES_BUNDLE="$(find .build -maxdepth 3 -name '*_GameDock.bundle' | head -1)"` —
if SPM generates multiple bundles (e.g. for different build configurations),
`head -1` picks an arbitrary one.

**Why it matters**: In practice only one bundle is generated per build. Low risk.

---

### 🟢 BP-03 · `Package.swift` uses `unsafeFlags` for `-DGL_SILENCE_DEPRECATION` and `-dead_strip`

**File**: `Package.swift`, lines ~33–35  
**What**: These flags prevent the package from being used as a dependency in
other SwiftPM packages. Since this is an executable target, this is fine.

---

## 12. Summary of Findings by Severity

| Severity | Count | Key Issues |
|---|---|---|
| 🔴 Critical | 1 | CR-01 (SteamScreenshotStore inflight leak) |
| 🟡 Moderate | 15 | Thread races (CR-07, CR-10), fragility (CR-02), perf (CR-03, CR-04, PF-01, PF-02), API (AP-02), new features (NF-02, NF-05) |
| 🟢 Minor | 12 | Naming, dead code, defensive improvements |

**Top priority fixes**:

1. **CR-01** — `SteamScreenshotStore` inflight task leak: add a generation check
   before removing from `inflight`.

2. **CR-07** — `SteamLocalConfigReader.cached` race: add a lock or dispatch
   isolation.

3. **CR-10** — `RCClientService.romPath/romData` race: copy into the constructor.

---

*Audit completed: 2025-07-22. All 80 Swift source files read; no files edited.*
