# Steam Library Scanner — Reconnaissance Report

**Scope:** Map exactly how GameDock should read `libraryfolders.vdf` and
`appmanifest_*.acf`, grounded in the real Steam install at
`~/Library/Application Support/Steam/` and the existing implementation in
`Sources/GameDock/Libraries/VDFParser.swift` + `SteamLibrary.swift`.

**Date:** 2025-02-13 · **Role:** RESEARCH SCOUT (read-only — no source files modified)
**Author method:** live `--scan-steam` run + manual inspection of every file +
standalone edge-case parser probes.

---

## 1. File inventory on this machine

```
~/Library/Application Support/Steam/
├── config/
│   ├── libraryfolders.vdf          ← mount-point registry (authoritative for extra libs)
│   └── config.vdf, DialogConfig.vdf, ...
├── steamapps/
│   ├── libraryfolders.vdf          ← default library's own apps-block mirror
│   ├── appmanifest_*.acf           ← 16 files (the installed games)
│   ├── common/                     ← 44 dirs (NOT authoritative — see §4.2)
│   ├── downloading/1281930/        ← in-flight update state
│   ├── temp/{960090,306020,1794680,1671210,1281930}/
│   ├── workshop/  sourcemods/  dls/  steamclean
├── registry.vdf                    ← global Steam registry (not used for library scan)
└── userdata/
    ├── 1095012383/                 ← account A (principal auto-login "milkmanyee")
    │   └── config/grid/3003013029_hero.jpg  ← only grid file (stale, orphaned)
    └── 396538539/                  ← account B (secondary)
        └── config/grid/            ← empty
```

- **16** `appmanifest_*.acf` = **16** games reported by `--scan-steam`.
- **1** library mount point (`"0"`), path = the default Steam root.
- **1** orphaned grid image that matches **no** installed game.

---

## 2. Exact structure of `libraryfolders.vdf`

### 2.1 ASCII layout (verbatim from this machine)

```
"libraryfolders"                          ← root key
{
  "0"                                     ← mount index ("0" is ALWAYS the default library)
  {
    "path"        "/Users/verbog/.../Steam"     ← canonical path (single backslash never used here)
    "label"       ""                          ← optional user-set name (usually "")
    "contentid"   "9054832360179762215"        ← 19-digit content identifier (opaque)
    "totalsize"   "0"                         ← 0 on macOS (not maintained)
    "update_clean_bytes_tally" "2322734176"    ← accounting (noise for us)
    "time_last_update_verified" "1786499538"   ← epoch (noise)
    "apps"
    {
      "105600"    "854269622"                 ← appid → SizeOnDisk (mirror, see §4)
      "233450"    "565083957"
      ... (17 entries)
    }
  }
}
```

### 2.2 Semantics / field table

| Key            | Used by frontend? | Notes |
|---|---|---|
| `<N>` index    | ✅ YES — mount key to enumerate libraries | "0" = default; "1".."N" = extra mounts |
| `path`         | ✅ YES — base dir of that library | May be **Windows-style backslash** on cross-imported configs (see §6) |
| `label`        | ⚠️ optional — display name | Usually empty; fall back to folder name |
| `contentid`    | ❌ no | opaque Steam identifier |
| `totalsize`    | ❌ no | not truthfully maintained on macOS |
| `update_clean_bytes_tally` | ❌ no | accounting noise |
| `time_last_update_verified` | ❌ no | accounting noise |
| `apps` block   | ⚠️ partial — see §4 | stale; NOT the source of truth for "installed" |

### 2.3 Normalization required

- `path` value is **always quoted and may contain backslashes**:
  - **Relative path:** interpreted **relative to the Steam installation root**. Steam never writes relative `path` values on macOS, but hand-edited or migrated configs can. Rule: if not `/`-prefixed and no volume, resolve against `steamRoot`.
  - **Windows-style `D:\Games\SteamLibrary`:** Steam itself never writes this on macOS, but the format is shared with Windows. A robust parser must convert `\` → `/` before building a `URL`.
  - On macOS the only real value seen: `/Users/verbog/Library/Application Support/Steam` (space in "Application Support" — a reminder that path components must be URL-quoted via `appendingPathComponent`, not naive string concat).

---

## 3. Exact structure of `appmanifest_*.acf`

### 3.1 Ground-truth verification (Terraria = `appmanifest_105600.acf`)

```
"AppState"                        ← root block (allegedly a dict whose single key is "AppState")
{
  "appid"            "105600"         ← ✅ MUST HAVE
  "universe"         "1"
  "name"             "Terraria"       ← ✅ MUST HAVE
  "StateFlags"       "4"              ← ✅ IMPORTANT: bitfield, see §3.3
  "installdir"       "Terraria"       ← ✅ MUST HAVE → maps to common/<installdir>
  "LastUpdated"      "1773605272"     ← ⚠️ epoch (update time, not play time)
  "LastPlayed"       "1786501596"     ← ✅ epoch; 0/absent = never played
  "SizeOnDisk"       "854269622"      ← ✅ bytes (mirrors apps-block int)
  "StagingSize"      "0"
  "buildid"          "22266454"
  "LastOwner"        "76561199055278111"   ← SteamID64 of owning account
  "DownloadType"     "1"
  "UpdateResult"     "0"
  "BytesToDownload"  / "BytesDownloaded"
  "BytesToStage"     / "BytesStaged"
  "TargetBuildID"    ...
  "AutoUpdateBehavior"  ...
  "ScheduledAutoUpdate" ...
  "InstalledDepots"              ← nested dict of depots; noise for us:
    "105603" { "manifest" "387313944418126565"; "size" "854269622" }
    ...
  "UserConfig" / "MountedConfig"   ← language, beta, DisabledDLC; noise
  "FullValidateAfterNextUpdate"  ...
}
```

### 3.2 Field importance for the frontend

| Field | Use | Notes |
|---|---|---|
| `appid` | **Core identity** | Launch URL is `steam://run/<appid>` |
| `name` | **Card title** | Direct display string; sort key |
| `installdir` | **Resolve game folder** | Maps to `<library>/steamapps/common/<installdir>` |
| `StateFlags` | **Filter installable games** | See bitfield §3.3 |
| `LastPlayed` | **Recents ordering** | Epoch seconds; missing/`0` ⇒ "never" |
| `SizeOnDisk` | **Disk-space detail + dedup** | Bytes; doubles as apps-block mirror value |
| `LastUpdated` | ⚠️ minor | Update time — could drive a "last updated" sort; not otherwise used |
| `LastOwner` | ⚠️ informational | SteamID64; could filter to the auto-login account |
| `InstalledDepots`, `UserConfig`, `MountedConfig`, `Bytes*`, `buildid`, `TargetBuildID` | ❌ noise | Not needed to present/launch a game |

### 3.3 `StateFlags` bitfield (observed values on this machine)

Observed values: `4` and `6`. Decomposed:

| Flag value | Meaning | Frontend action |
|---|---|---|
| `4` (0b100) | **State is fully installed + update required** — the normal "ready to play" state | **Show as launchable** |
| `6` (0b110) | `2|4` = **INSTALLED + UPDATE_REQUIRED** simultaneously (Steam's pre-update state) | Show as launchable (maybe a "needs update" badge) |
| `2` (0b010) | **NEEDS_UPDATE** (uninstalled/pending) | **Exclude** from "installed" list **or** mark `needsUpdate` |

Other bits (not seen here, but documented by SteamDB):
`1` invalid · `2` uninstalled/needs update · `4` update required · `8` update started · `16` uninstalling · `32` backup · `64` running · `128` update complete · `256` downloading · `512` download started · `1024` download stopped · `2048` download complete · `4096` paused · `8192` preloading · `0x100000` corrupt.

**Robust filter:** treat a manifest as *installed and launchable* only when
`(StateFlags & 0b110) != 0` — i.e. at least one of bit `2` or bit `4` is set.
Games with `StateFlags` containing a "corrupt/working/backed-up" bit should be
flagged. **Never** treat the mere *presence* of an `.acf` as "fully installed":
Steam keeps `.acf` files for partially-downloaded or uninstalling games.

### 3.4 `installdir` → `common/` mapping

`installdir` is the exact folder name under that library's `steamapps/common/`.
The full game path is:

```
<library>/steamapps/common/<installdir>
```

Checked on this machine: `appmanifest_250900.acf` => `installdir "The Binding of Isaac Rebirth"` (no colon), matches `common/The Binding of Isaac Rebirth/`. `appmanifest_960090.acf` => `"BloonsTD6"` matches `common/BloonsTD6/`. Names contain spaces — must be handled as URL path components, never manually rebuilding strings.

---

## 4. Multiple library folders & authoritative-installed-source

### 4.1 The two VDF locations and their roles

Two files exist with the same name:

| File | Role |
|---|---|
| `config/libraryfolders.vdf` | **Mount-point registry** listing every library (extra mount points live ONLY here). |
| `steamapps/libraryfolders.vdf` | The **default library's own mirror** of the registry (present only in the *default* library). |

On this machine they are **byte-identical** (only 1 library). **Recommendation:** read `steamapps/libraryfolders.vdf` (already the current approach) — but if Steam ever renames/metadata-moves the default library, the parse of `mount-path + apps-block` in the default file is the correct primary source. The `config/libraryfolders.vdf` is a good **fallback** for enumerating extra mounts if the `steamapps/` mirror is missing (seen on some installs).

### 4.2 `common/` folder is NOT authoritative

44 folders in `common/` but only **16** manifests. **28** folders have **no**
manifest. Some (e.g. `Steam Controller Configs`, `Blender`, `Godot Engine`)
are non-game or tool content; the rest are leftover dirs from *previously
installed* games whose `.acf` was removed (or removed games' data Steam never
cleaned). **Never** enumerate `common/` directly as a source of installed games —
that yields false positives. Use `.acf` + `StateFlags` as ground truth.

### 4.3 The `apps` block is STALE — not the source of truth

The `apps` block lists appids → `SizeOnDisk`. On this machine:

- 17 entries in the block, **16** manifests.
- The one extra (`698780` = **Doki Doki Literature Club!**) has **no manifest** and **no `common/` folder** — it is uninstalled but still listed.
- All 16 `apps`-block sizes exactly equal each own `SizeOnDisk` — the block is a **mirror** of install data *at last write*, not live state.

**Bottom line:** the authoritative source of *currently installed and launchable* games is **`appmanifest_*.acf` files** (one per installed game) whose `StateFlags` indicate a usable install. Use `libraryfolders.vdf` only for:
1. Enumerating which folders to scan for `.acf` files (mount `path`s), and
2. (Optionally) informing `SizeOnDisk` / stale games.

### 4.4 Duplicate detection across libraries

- Steam normally **enforces one copy of an appid per library**, so a given `appid` appears in exactly one `.acf` across all libraries. In practice duplicates don't occur.
- **Current `SteamLibrary` has NO dedup by appID** — `installedGames()` concatenates manifests from every folder and sorts by name. If a user manually copies manifests or has a second library mirror, the same game would appear twice.
- **Fix (recommended):** dedup by `appID` with **first-intact-wins** preference: prefer the manifest whose folder exists on disk with `StateFlags` bit(s) set; otherwise prefer the one with the largest `SizeOnDisk`; last-resort keep the lexicographically-first library path. Also merge `LastPlayed` (max), `SizeOnDisk` (max).

---

## 5. Grid artwork discovery — verified on this machine

### 5.1 What actually exists

```
userdata/1095012383/config/grid/3003013029_hero.jpg   (286 KB, Dec 21 2025)
```
- `config/grid/` exists only under account `1095012383`, and holds **one** file.
- It is a `_hero` style image for appid `3003013029`, which is **(a)** not installed and **(b)** the only grid asset present.
- Account `396538539` has a `config/grid/` dir but it is **empty**.

So: **zero** matches for any of the 16 installed games. Confirms the current
scanner falls back to remote CDN (`header.jpg`) for every title — which we
verified resolves (HTTP 200, ~62 KB for `105600/header.jpg`).

### 5.2 The standard grid-art naming scheme (for documentation / future-proofing)

Steam's library grid art files live in `userdata/<accountID>/config/grid/`:

| File pattern | Purpose | Size |
|---|---|---|
| `<appid>.png` | **Library grid / capsule** (most common user custom art) | 460×215 |
| `<appid>p.png` | **Portrait / tall** art | 300×450 |
| `<appid>_Hero.png` | **Hero banner** (top-of-library) | 1920×622 |
| `<appid>_header.jpg` | Header (less common user-set) | 460×215 |
| `<appid>c.png` | Capsule (very rare) | … |

**Current `gridArtPath` candidates:** `[<appid>.png, <appid>.jpg, <appid>p.png]`.
**Gap:** missing `_hero` and `_header` and `p` variants that Steam actually
names on disk. Our probe shows none of the installed games have custom art, so
this is a **low-priority** robustness improvement, but worth aligning the
candidate suffix list with reality (`p`, `_Hero`, `_header`, `c`, and `.jpg`).

---

## 6. Robustness gaps in the current implementation

### 6.1 `VDFParser.swift` — probe results

I mirrored the parser into a standalone script and probed edge cases (no source modified). Results:

| Case | Current behavior | Verdict |
|---|---|---|
| UTF-8 BOM prefix | handled (strips `\u{FEFF}`) | ✅ |
| Tabs as separators / trailing whitespace | handled (`isWhitespace`) | ✅ |
| `//` and `/* */` comments | handled | ✅ |
| `\n`, `\r\n` line endings | handled (`isWhitespace` covers `\r`) | ✅ |
| CR-only line endings | **not** explicitly handled (though rare on macOS) | ⚠️ low |
| Escaped quote `\"` / backslash `\\` / `\n` / `\t` | handled | ✅ |
| **Solo backslash in value** (`D:\Games`) | treated as escape of next char → `D:Games` — **corrupts Windows paths** | 🔴 **BUG** |
| Unterminated string | returns nil (whole parse fails) | ✅ (fail-closed) |
| Unbalanced `{}` | returns nil | ✅ |
| Numeric unquoted value (`"key" 105600`) | **returns nil** → whole file lost | 🔴 gap |
| Single-quoted keys/values | nil | ⚠️ nonstandard, acceptable |
| Colon separator `"key": "v"` | nil | ⚠️ nonstandard, acceptable |

**Critical:** the **solo-backslash** corruption is the one real correctness bug
for the intended use (parsing `libraryfolders.vdf` `path` values, which on
imported/Windows configs contain `\`). Fix: only treat `\X` as an escape when
`X ∈ {", \\, n, t, r, b, f, 0}`; otherwise keep the backslash literally.

### 6.2 `SteamLibrary.swift` — gaps vs. robustness ambitions

1. **No StateFlags gating** — `parseManifest` accepts any `.acf` regardless of
   download state. An uninstalling/pending manifest would surface as launchable.
   Fix: check `StateFlags & 0b110 != 0`; optionally surface `needsUpdate`.

2. **Windows/relative path normalization absent** in `steamAppsFolders()`.
   A `path` value of `D:\Games` would build an **invalid macOS URL**. Fix:
   normalize `\`→`/`, resolve relative against steam root, strip trailing `/`.

3. **Loop `for key in 0...64`** is a magic number and iterates every index
   build; correct in current config but brittle. Prefer iterating the parsed
   dict keys as integers. Also note the Set-dedup on URLs is O(n·sort); fine.

4. **No duplicate-by-appID dedup** (see §4.4).

5. **`installedGames()` swallows read/parse errors** silently (returns `nil`
   from `parseManifest` with a `warn` only). A fully corrupt library renders
   **zero** games with no surfaced error to the user. Recommend surfacing a
   count of "skipped unreadable manifests" via a scan-result struct.

6. **`steamRoot()` hardcodes `~/Library/Application Support/Steam`** with no
   env override / Steam's own `config.vdf` discovery. For a controller-first
   app this is acceptable (single-machine), but an app-support env var or
   `Steam ConfigPath` read would be a nice-to-have.

7. **`gridArtPath` iterates every userdata dir** for every game on every scan
   (multiple `contentsOfDirectory` calls per appid). With many users/accounts
   this is redundant work; memoize per-scan.

8. **Sorting is name-only**; for "recent-first" the caller (LibraryStore
   `recentGames`) uses RecentsStore. Consider returning `installedGames` sorted
   by `LastPlayed` desc by default and letting the UI re-sort.

9. **`SizeOnDisk` as `Int64`** — Steam values can exceed `2^31`, fine here —
   but watch `SizeOnDisk` for values from the apps block which are the same.

10. **Locale & case**: `name` sort uses `localizedStandardCompare`; this is
    correct for a human list and already in place.

---

## 7. Prioritized recommendations

### Must-fix (correctness)
- **P1. Fix solo-backslash corruption in `VDFParser.readQuotedString()`** — only
  treat `\` escapes for `"`, `\`, `n`, `t`, `r` (and optionally `b/f/0/`);
  otherwise emit the backslash literally. This directly protects `path` parsing.

### High-value robustness
- **P1. Gate `installedGames()` on `StateFlags & 0b110 != 0`** (skip or flag
  non-installed states). Add `needsUpdate`/`installing` metadata to
  `SteamAppInfo` for future badges.
- **P1. Normalize library `path`** in `steamAppsFolders()`: `\`→`/`, resolve
  relative against `steamRoot`, guard invalid URLs, log and skip unmapped
  mounts.
- **P2. Dedup by appID** across libraries with first-intact-wins + merge
  `LastPlayed`/`SizeOnDisk`.

### Polish / resilience
- **P2. Replace `0...64` magic loop** with iterating the parsed dict's integer
  keys.
- **P3. Expose scan diagnostics** — return a struct from `installedGames()`
  (games + count of skipped/unreadable manifests + folders scanned) so CLI and
  UI can surface "library partially read".
- **P3. Memoize userdata scanning in `gridArtPath`** per scan run.
- **P3. Align grid-art suffixes** with Steam's real names (`_hero`, `_header`,
  `c`, `p`, `.jpg`).
- **P4. Support `config/libraryfolders.vdf`** as a fallback mount source when
  the `steamapps/` mirror is missing.
- **P4. Optional `StateFlags=2`** "uninstalled" games could still be shown
  (greyed, "not installed") rather than fully hidden — nice-to-have for the
  gamepad UI.

---

## 8. Ground-truth data snapshot (for regression tests)

| appid | name | StateFlags | installdir (common/) | SizeOnDisk |
|---|---|---|---|---|
| 105600 | Terraria | 4 | Terraria | 854269622 |
| 1127500 | Mini Motorways | 4 | Mini Motorways | 296565112 |
| 1281930 | tModLoader | 4 | tModLoader | 173418893 |
| 1671210 | DELTARUNE | 6 | DELTARUNE | 903958440 |
| 1794680 | Vampire Survivors | 6 | Vampire Survivors | 1118282083 |
| 233450 | Prison Architect | 4 | Prison Architect | 565083957 |
| 2379780 | Balatro | 4 | Balatro | 85164047 |
| 239820 | Game Dev Tycoon | 4 | Game Dev Tycoon | 451538406 |
| 250900 | The Binding of Isaac: Rebirth | 4 | The Binding of Isaac Rebirth | 678342290 |
| 306020 | Bloons TD5 | 6 | BloonsTD5 | 282015398 |
| 322170 | Geometry Dash | 4 | Geometry Dash | 334510594 |
| 391540 | Undertale | 4 | Undertale | 178123538 |
| 413150 | Stardew Valley | 4 | Stardew Valley | 711467377 |
| 444640 | Bloons TD Battles | 4 | Bloons TD Battles | 95571246 |
| 589590 | Kindergarten | 4 | Kindergarten | 142017923 |
| 960090 | Bloons TD 6 | 6 | BloonsTD6 | 2933581502 |

Legacy / non-manifest items to ignore: `698780` (apps-block stale, DDLC), 28
orphan `common/` dirs.

---

*End of report — SCOUT DONE*
