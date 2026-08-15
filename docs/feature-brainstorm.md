# Feature Brainstorm — Leblanc (GameDock)

Sources: detached scout report (sa_3139f5ef, read-only, grounded in code) +
main-agent analysis from the full-tree review (docs/review-current-tree.md).

> The scout's full report was truncated in delivery; the scout re-emitted it
> (follow-up turn). This doc captures the scout's confirmed ground-truth gaps +
> a ranked improvement list. Scout-verified items are marked **[scout]**.

## Confirmed ground-truth gaps (scout-verified in code)

1. **[scout] No save states.** `RetroCore.swift` resolves `retro_reset`,
   `retro_load_game_special`, `retro_get_region`, `retro_get_memory_data/size`
   — but **not** `retro_serialize` / `retro_unserialize` /
   `retro_get_serialize_size`. `AppPaths.savesDir` already exists and is handed
   to cores via the env table, so cores already write `.srm`/`.dsv` there.
2. **[scout] Core options deliberately declined** —
   `RetroEnvironment.swift` returns `false` for `GET_VARIABLE`,
   `SET_VARIABLES`, `GET_VARIABLE_UPDATE`, `SET_VARIABLE` ("v1 has no options
   UI"). The biggest confirmed gap.
3. **[scout] `retro_reset` is resolved but never called** — no reset binding
   anywhere in the UI.
4. **[scout] Single-controller only** — `ControllerManager` keeps one
   `activeController`, the GCInput→libretro-ID map is hardcoded in `hook(pad:)`,
   only port 0 is written, and `RetroEnvironment` answers
   `GET_INPUT_MAX_USERS = 1` (even though `InputSnapshot` already supports 4
   ports). No remapping, no per-game profiles.
5. **[scout] No sleep/wake handling** — zero matches for `willSleep`/`didWake`
   in Sources; a sleep cycle would desync the core thread + `AVAudioEngine`.
   Only `beginActivity(.idleSystemSleepDisabled)` exists (prevents idle sleep,
   not lid-close sleep).

## Ranked improvements (value vs effort)

### Tier 1 — high value, moderate effort

1. **Core options UI (L / M).** Implement `GET_VARIABLE`/`SET_VARIABLES` in
   `RetroEnvironment` (the table is already structured), surface a per-system
   options sheet in Settings, persist in `SettingsStore`. Unlocks melonDS
   accuracy/resolution toggles and every other core's knobs.
2. **Save states + reset (M / M).** Resolve `retro_serialize`/
   `retro_unserialize`/`retro_get_serialize_size` in `RetroCore`; add
   `EmulatorSession.saveState()/loadState()/reset()` writing to `AppPaths.savesDir`
   (`<romID>.state`); bind L3/R3 (or Options/Menu) during emulation, with
   quick-bar entries. `retro_reset` binding comes for free.
3. **Sleep/wake handling (M / M).** Observe `NSWorkspace.willSleepNotification`
   → pause the core run loop + stop the audio engine; `didWakeNotification` →
   resume. Prevents frame/audio desync on lid-close sleep.

### Tier 2 — good value, low effort

4. **Favorites / pinning (M / S).** A `favorites.json` beside `recents.json`
   (same RecentsStore pattern); pinned games render first in the Home category.
5. **Game time tracking (M / S).** Extend `RecentLaunch` with `durationSeconds`;
   `AppEnvironment.startEmulator/launch` records a session start, `exitEmulation`
   (and a periodic timer during Steam/PPSSPP handoffs) accumulates time. Show
   "Xh played" in `metaLine`.
6. **Toast queue (S / S).** `RAToastModel` shows one `current` toast; make it a
   small queue so a burst of unlocks doesn't clobber each other.
7. **Screenshot polish (S / S).** Already timestamped; add a "captured" HUD
   toast and a Pictures subfolder per game.

### Tier 3 — bigger projects

8. **Gamepad remapping UI (M / L).** Extract the hardcoded mapping in
   `ControllerManager.hook` into a `ControllerLayout` (button→libretro-id +
   UI action) persisted in `SettingsStore`; per-game overrides keyed by
   `GameEntry.id`. Enables accessibility-friendly layouts.
9. **Multi-controller (S / L).** `InputSnapshot` already has 4 ports; wire a
   second `GCController` to port 1, raise `GET_INPUT_MAX_USERS`, and let cores
   (e.g. 2P DS games) see both pads.
10. **ROM metadata scraping (S / M).** Genre/year/rating from a local DB or a
    metadata service; needs an offline cache + TTL (RAHubModel pattern exists).
11. **Scan performance (S / M).** `LibraryStore.scanSynchronously` re-crawls
    every folder on each refresh; cache scan results with a folder-mtime stamp
    and only rescan changed trees.
12. **Search / virtual keyboard (S / L).** Gamepad-driven search needs a
    virtual keyboard; big surface area, defer.

## Recommended next picks

The four ideas that best fit the current architecture with least risk:
**save states + reset** (core plumbing is 90% there), **favorites** (clone the
recents pattern), **game time** (tiny), and **core options UI** (largest user
value; needs the env-table work + a settings sheet).

Save states and core options both touch `Sources/CLibretro/include/libretro.h`
(the serialize/option structs must match the canonical ABI) — read
`leblanc-libretro-cores` skill before starting.
