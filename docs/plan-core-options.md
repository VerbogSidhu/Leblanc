# Core Options UI — Implementation Plan

**Goal:** let the user view and change libretro core options (melonDS resolution,
threaded video, etc.) from the controller while a game is running, persisted per
system. Implements the **classic (v1) `retro_variable` interface** — the ABI
surface already exists in the trimmed header.

**UX:** while emulating, PS → quick bar gains **Options**. Selecting it opens a
fullscreen XMB-styled overlay: rows of option title + current value; d-pad
up/down moves the cursor, left/right cycles the value, Confirm applies + closes,
B/PS closes. Changes apply live (cores re-read via `GET_VARIABLE_UPDATE`) and
persist per source (all DS games share melonDS options).

---

## Ground truth (verified in source)

- `Sources/CLibretro/include/libretro.h` already contains (canonical modern
  numbering — do NOT renumber):
  - `RETRO_ENVIRONMENT_GET_VARIABLE = 15`
  - `RETRO_ENVIRONMENT_SET_VARIABLES = 16`
  - `RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE = 17`
  - `RETRO_ENVIRONMENT_SET_VARIABLE = 70`
  - `struct retro_variable { const char *key; const char *value; }` (canonical 2-pointer layout, line ~233)
- `RetroEnvironment.swift` currently **declines all four** (returns `false`).
- No `GET_VARIABLE_UPDATE_VERSION` (75) in the header → classic v1 semantics
  (RetroArch pre-v2 behavior; melonDS-compatible). v2 is future work.
- **No real cores on this machine** (GameDock/RetroArch cores dirs empty) →
  verification via an extended mock core + unit assertions; real-core validation
  later via `--probe-core`.

## Contract being implemented (v1)

- Core → frontend `SET_VARIABLES (16)`: null-terminated `retro_variable[]` where
  `value = "Human Title; opt1|opt2|opt3"`.
- Core → frontend `GET_VARIABLE (15)`: `retro_variable*` with `.key` set; we fill
  `.value` with the **selected token** (stable C buffer). Unknown key → return false.
- Core → frontend `SET_VARIABLE (70)`: core-initiated value change; we record +
  persist.
- Core → frontend `GET_VARIABLE_UPDATE (17)`: `bool*`; true only after a
  frontend-initiated change since the last poll (we clear the flag).
- Frontend changes are applied by updating the stored token + flag; the core
  picks them up by polling `GET_VARIABLE_UPDATE` and re-reading `GET_VARIABLE`.

## Changes by file

### 1. `Sources/GameDock/Launch/RetroEnvironment.swift`
- Add `struct CoreOptionDefinition { key, title, values: [String] }`.
- New state: `coreOptionDefinitions: [String: CoreOptionDefinition]`,
  `coreOptionValues: [String: String]` (key → token), `coreOptionValuesChanged`,
  and a stable `[CChar]` buffer per key for `GET_VARIABLE` answers.
- `handle(cmd:)`:
  - `SET_VARIABLES (16)`: parse the array + `"Title; a|b|c"` strings (extract the
    `"Title; opts"` split into a pure, unit-testable parser); seed values
    (persisted token if valid, else **first** option — RetroArch convention);
    notify `CoreOptionsModel` on main.
  - `GET_VARIABLE (15)`: fill `.value` from the selected token's stable buffer.
  - `SET_VARIABLE (70)`: record + persist.
  - `GET_VARIABLE_UPDATE (17)`: write flag into `bool*`, clear it.
- Threading: env calls run on main during load and on the core thread during
  run; value writes come from the UI (main). Guard value access with a small
  `NSLock`; buffer contents rewritten under the same lock (cores read the
  pointer immediately after the env call returns — standard v1 contract).

### 2. New `Sources/GameDock/Launch/CoreOptionsModel.swift`
- `final class CoreOptionsModel: ObservableObject` — `struct Row { key, title, values, selectedIndex }`,
  `@Published private(set) var rows: [Row]`, cursor index; `select(up/down)`,
  `cycle(delta)`; write-back to `SettingsStore` + `applyCoreOption` on the
  session. All UI mutations on main; value reads lock-guarded.

### 3. `Sources/GameDock/Libraries/SettingsStore.swift`
- `@Published private(set) var coreOptions: [String: [String: String]]`
  (sourceKey → optionKey → token), persisted under `"coreOptions"`; setters
  `setCoreOption(_:key:for:)` / `coreOption(_:for:)`.

### 4. `Sources/GameDock/Launch/EmulatorSession.swift`
- New init param `coreOptionsKey: String?`; create `coreOptions` model; feed
  definitions from `RetroEnvironment` into it at load; expose
  `applyCoreOption(key:token:)` (updates env + flag + persists).

### 5. `Sources/GameDock/AppEnvironment.swift` (+ Launch extension)
- `@Published var coreOptionsVisible = false`; router branch when open
  (up/down/left/right/confirm/back → model, B/PS closes).
- Quick bar: `.coreOptions` item visible while `screen == .emulator`;
  `quickBarSelect(.coreOptions)` opens the overlay.
- `startEmulator` passes `coreOptionsKey: entry.source.rawValue`.

### 6. `Sources/GameDock/UI/EmulatorScreen.swift` (+ small overlay view)
- Overlay rendered above the emulator surface when `coreOptionsVisible`: dark
  panel, rows (title + value, selection in `Theme.signal`), footer hint
  ("▲▼ select · ◀▶ change · B close"), empty state ("This core has no options").

### 7. `Tests/MockCore/mockcore.c` + `CLISelfTest` (verification)
- Mock requests `SET_VARIABLES` with 2 options during load and draws a frame
  element **driven by the option value** (same trick as the moving square).
- Selftest: load → `session.applyCoreOption` → run frames → assert the frame
  reflects the new value → proves the full parse/serve/update/apply round-trip
  headlessly.

### 8. `CLIUnitTest`
- Pure parser tests (`"Title; a|b|c"` splitting, defaults, invalid tokens).
- `SettingsStore` coreOptions round-trip (in-memory suite).

## Order of work

1. `RetroEnvironment` parse/serve/update + stable buffers (no UI).
2. `CoreOptionsModel` + `SettingsStore` persistence.
3. `EmulatorSession` wiring + `applyCoreOption`.
4. Mock core + selftest assertions (pipeline proven headlessly).
5. Quick bar item + overlay UI + router branch.
6. Polish: hints, empty state.
7. `make build` (0 warnings) → `make test` → `make selftest` → `make app`; commit.

## Risks & mitigations

- **ABI**: no struct/enum changes needed (already canonical); re-verify with
  `--probe-core` against a real melonDS when one is available.
- **Buffer lifetime**: per-key stable buffers, never freed before teardown;
  RetroArch uses the same pattern.
- **v1 vs v2 cores**: v1 works with melonDS/PPSSPP; v2 (`GET_VARIABLE_UPDATE_VERSION`)
  is future work (would need the big `retro_core_options_v2` struct).
- **Thread races**: value access lock-guarded; `@Published` mutations on main.
- **Defaults**: first token is default (RetroArch convention) unless persisted.

## Definition of done

- PS → Quick Bar → Options overlay works during DS emulation; changes apply live
  and persist per system.
- `make test` + `make selftest` pass, selftest now asserts an option change
  alters the mock frame.
- 0 build warnings; app rebuilt.
