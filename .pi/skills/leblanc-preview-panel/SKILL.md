---
name: leblanc-preview-panel
description: The selection preview panel — rotating screenshots, personal captures, playtime, and debounce logic for the XMB's selected item. Read before modifying panel data sources, image loading, or the debounce timing.
---

# Leblanc — Selection Preview Panel

Additive panel to the right of the XMB's selected item card. Driven by the
same selection-change event that updates the big cover art — no separate
interaction or control-scheme bindings.

## Architecture

| File | Owns |
|---|---|
| `UI/SelectionPreviewModel.swift` | Debounced selection → populates images + playtime; 3 s rotation timer; generation guard for stale fetches |
| `UI/SelectionPreviewPanel.swift` | The ink panel view (300 pt wide, 16:9 image area, playtime line) + `PreviewImage` + `PreviewImageLoader` (LRU-capped image cache) |
| `Libraries/SteamScreenshotStore.swift` | Fetches `store.steampowered.com/api/appdetails` screenshot URLs; disk cache (RACache envelope, 1-week TTL) + memory cache + inflight dedupe |
| `Libraries/SteamLocalConfigReader.swift` | Reads `localconfig.vdf` playtime (minutes) from `~/Library/Application Support/Steam/userdata/*/config/localconfig.vdf` |
| `Libraries/CaptureStore.swift` | Matches `~/Pictures/Leblanc Captures/<sanitizedTitle> *.png` for emulator game captures |
| `Core/PlaytimeFormatter.swift` | Shared "14h 32m" formatting (Steam minutes + emulator seconds) |
| `CLI/CLIPreviewCheck.swift` | `--preview-check <appid> [title]` headless diagnostic |

## Data flow

```
XMBView.onChange(of: nav.selectedItem)
  → env.preview.select(item?.entry)     // debounced 350 ms
    → Steam: screenshots.screenshotURLs(for: appID)  // network + disk cache
           steamPlaytime.playtimeMinutes(appID:)      // localconfig.vdf
    → Emulator: captures.captures(for: title)         // ~/Pictures/Leblanc Captures/
              recents.totalPlaytime(for: entry.id)    // RecentsStore (seconds)
  → model publishes imageSources + playtimeText
  → SelectionPreviewPanel renders
```

## Debounce contract

- 350 ms settle delay before any work starts (avoids network/cache lookups per
  item scrolled past; prevents panel flicker mid-scroll).
- `generation` counter: each `select()` bumps it; stale async work checks
  before applying. No cancellation races.
- During debounce: panel shows a quiet ink box (no art fetch triggered for
  items passed over).

## Image sources (priority order)

**Steam:**
1. Real screenshots from storefront API (`path_full` URLs), cached locally.
2. Fallback: `ArtworkView(entry:style:.banner)` — header art from the
   library's existing artwork pipeline.

**PSP/DS (emulator):**
1. Personal captures from `~/Pictures/Leblanc Captures/` (matched by
   `ScreenshotController.sanitizedTitle`).
2. Fallback: `ArtworkView(entry:style:.banner)`.
3. If neither exists: `ArtworkView` shows the platform-tinted title placeholder
   (never a broken image).

## Rotation

- Up to 5 images rotate with a 3 s interval.
- Crossfade: 0.5 s ease-in-out (respects `accessibilityReduceMotion`).
- Single image: static (no rotation timer started).

## Playtime sources

| Source | File | Unit | Network? |
|---|---|---|---|
| Steam | `localconfig.vdf` (`Software\Valve\Steam\apps\<appid>\Playtime`) | minutes | No |
| Emulator | `RecentsStore.totalPlaytime(for:)` | seconds | No |

Merged across Steam user accounts (max per appid). Cached per session;
`invalidate()` on manual library rescan.

## CLI verification

```bash
# Real endpoint + localconfig + captures (one-shot):
swift run Leblanc --preview-check 413150 "Stardew Valley"
```

## Rules for the agent

- Never remove the debounce — it's the core UX contract.
- `PreviewImageLoader` is a separate singleton from `ArtworkLoader` — the
  panel has its own image cache (different lifecycle, smaller working set).
- `SteamScreenshotStore.invalidate()` must be called on manual library rescan
  (Settings → Rescan) to honor the "refetch on refresh" contract.
- The panel is purely additive — never modify `XMBNavModel`, input routing,
  or the existing vertical item bar layout to accommodate it.
