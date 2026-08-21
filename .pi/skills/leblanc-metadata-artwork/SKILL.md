---
name: leblanc-metadata-artwork
description: The metadata and artwork acquisition pipeline — SteamGridDB community art, IGDB game metadata, Steam CDN art, RetroArch thumbnail CDN, and the .env secrets contract. Use when adding game artwork, enriching ROM metadata, working with external art APIs, or configuring API keys.
---

# Leblanc — Metadata & Artwork Pipeline

Three external services supply artwork + metadata for games across Steam, PSP,
and DS. All require API keys configured in the repo-root `.env` file (see
`Core/Secrets.swift`). Art falls back gracefully: if a service is unconfigured
or fails, the next source is tried; if all fail, `ArtworkView` shows a
platform-tinted initials placeholder (never a broken image).

## File map

| File | Owns |
|---|---|
| `Core/Secrets.swift` | Loads `.env` (repo root, gitignored) + env-var overrides. Thread-safe singleton; call `Secrets.load()` once at launch. |
| `Libraries/ArtworkLoader.swift` | The primary art loader. Memory LRU (200 entries) + disk cache + local RetroArch thumbnails + Steam CDN + SteamGridDB. Two kinds: `.banner` (landscape) + `.cover` (portrait). Uses `CGImageSource` thumbnails (no full-image decode). |
| `Libraries/SteamGridDBStore.swift` | Community art (capsules/logos/heroes) from `steamgriddb.com/api/v2/`. Bearer-token auth. 1-week disk cache. |
| `Libraries/IGDBClient.swift` | Game metadata (genre/release year/developer/summary) from IGDB via Twitch OAuth client-credentials. 1-week disk cache. Works for Steam + ROM games. |
| `Libraries/SteamLibrary.swift` | Resolves local Steam grid art paths (`<appid>p.png` portrait capsule, `<appid>.png` banner). |
| `UI/ArtworkView.swift` | SwiftUI consumer — renders `ArtworkLoader` output or platform-tinted initials placeholder. |
| `.env` / `.env.example` | API keys at repo root (gitignored). See secrets table below. |

## Secrets contract

| `.env` key | Service | Used by | Required for |
|---|---|---|---|
| `STEAM_GRID_DB_KEY` | SteamGridDB API | `SteamGridDBStore` | Community art (capsules, heroes, logos) for Steam games |
| `TWITCH_CLIENT_ID` | Twitch OAuth → IGDB | `IGDBClient` | Game metadata (genre, year, developer) for any game |
| `TWITCH_CLIENT_SECRET` | Twitch OAuth → IGDB | `IGDBClient` | Same as above |
| `SCREENSCRAPER_USERNAME` | ScreenScraper API | (future) | ROM artwork enrichment — not yet wired |
| `SCREENSCRAPER_PASSWORD` | ScreenScraper API | (future) | Same as above |

**Precedence**: environment variables override `.env` file values
(`Secrets.swift:34-39`). The `.env` file is found by walking up from CWD
(max 10 levels). `Secrets.load()` is idempotent (guarded by a lock +
`loaded` flag). Each service exposes an `isXConfigured` bool — use it to
short-circuit before making network calls.

**Never commit `.env`** — it's in `.gitignore`. The `.env.example` template
has placeholder values.

## Artwork resolution chain (`ArtworkLoader.load`)

For a given `GameEntry` + kind (`.banner` or `.cover`):

```
1. Memory cache hit? → return immediately (LRU touch)
2. Recent failure tombstone (< 60s)? → return nil (back off)
3. Disk cache file exists? → thumbnail off main → publish via loadedKeys
4. Local art (Steam grid / RetroArch thumbnails)?
   → thumbnail off main + copy to disk cache → publish
5. Remote (Steam CDN / RetroArch thumbnail CDN)? → fetch + thumbnail → publish
6. Fallback kind (cover → banner)? → retry at step 3
7. All miss → permanent tombstone + placeholder
```

- **Thumbnails** are created via `CGImageSource` at 600px max edge
  (`thumbnailMaxSize`) — ~0.5ms per image vs ~5-20ms for full `NSImage`
  decode. All decode happens on a concurrent background queue
  (`decodeQueue`, QoS `.utility`).
- **Aspect detection** uses `CGImageSourceCopyProperties` (header read, no
  decode) via `isLandscape(at:)` / `isPortrait(at:)` — avoids the old
  main-thread full-decode-just-to-check-aspect bug.
- **LRU eviction**: memory cache capped at 200 entries; oldest evicted on
  insert.
- **Failure tombstones**: dated entries; retried after 60s so transient
  CDN blips don't permanently block art.
- **Publishing**: `ArtworkLoader` is an `ObservableObject`;
  `@Published loadedKeys: Set<String>` fires when any game's art finishes.
  `ArtworkView.onReceive(loader.$loadedKeys)` re-resolves only when *this*
  game's key is in the set (set-membership check, not a full scan).

## Two art kinds — never mismatched

- **`.banner`** — landscape (Steam `header.jpg` 460×215; PSP/DS in-game
  snaps from RetroArch `Named_Snaps`). Used by the selection preview panel
  and as fallback for covers.
- **`.cover`** — portrait (Steam `library_600x900.jpg` capsule; PSP/DS
  box art from RetroArch `Named_Boxarts`). Used by the XMB item bar.

`cover(for:)` falls back to `.banner` (one level only); `banner(for:)`
has no fallback. This prevents a portrait capsule from being stretched
into a landscape frame and vice versa.

## SteamGridDB (`SteamGridDBStore`)

- Endpoint: `steamgriddb.com/api/v2/games/steam/<appid>`
- Auth: `Authorization: Bearer <key>`
- Response: `{ "data": { "image": "...", "logo": "...", "hero": "..." } }`
  or grid array `{ "data": [{ "url": "...", "style": "capsule" }, ...] }`
- Disk cache: `~/Library/Application Support/GameDock/preview-cache/steamgriddb/<appid>.json`
  (envelope: `{ fetchedAt, urls }`, 1-week TTL)
- Inflight dedupe: concurrent calls for the same appid share one `Task`
- `invalidate()` clears memory + disk — call on manual library rescan

## IGDB (`IGDBClient`)

- Auth flow: Twitch OAuth client-credentials → access token (cached in
  memory with expiry, refreshed 60s before expiration)
- Query: POST `api.igdb.com/v4/games` with `Client-ID` +
  `Bearer <token>` headers, body = `fields name,summary,genres.name,...; where <clause>; limit 1;`
- Steam games: `where external_games.uid = "steam_<appid>"`
- ROM games: `where name ~ *"<title>"*` (fuzzy match)
- Disk cache: `~/Library/Application Support/GameDock/preview-cache/igdb/<key>.json`
  (envelope: `{ fetchedAt, meta }`, 1-week TTL)
- Returns `GameMetadata` struct: genre, releaseYear, developer, summary

## 1-week disk cache envelope pattern

Both `SteamGridDBStore` and `IGDBClient` use the same pattern:

```swift
struct CacheEnvelope: Codable {
    let fetchedAt: Date
    let data: DataType
}
// TTL = 7 * 24 * 3600 seconds
// On read: check Date().timeIntervalSince(envelope.fetchedAt) < ttl
// On invalidate(): remove memory + delete disk directory
```

`SteamScreenshotStore` uses the same envelope. If adding a new external
metadata source, follow this pattern for consistency.

## RetroArch thumbnail integration

For PSP/DS games, `ArtworkLoader` reads from the user's existing RetroArch
thumbnail collection:

```
~/Library/Application Support/RetroArch/thumbnails/
  ├── Sony - PlayStation Portable/
  │   ├── Named_Boxarts/<artKey>.png   (cover)
  │   └── Named_Snaps/<artKey>.png     (banner)
  └── Nintendo - Nintendo DS/
      ├── Named_Boxarts/<artKey>.png
      └── Named_Snaps/<artKey>.png
```

`artKey` comes from `GameEntry.artKey` (the ROM filename without
extension, matching RetroArch's convention). If local art is missing, the
`thumbnails.libretro.com` CDN is the remote fallback.

## Adding artwork for a new source

1. Add the source to `GameSource` (`Core/Models.swift`) + `Theme.accent(for:)`.
2. In `ArtworkLoader.localPath(for:kind:)`, add a case for the new source
   pointing to where its local art lives.
3. In `ArtworkLoader.remoteURL(for:kind:)`, add the CDN URL pattern.
4. If the source has its own art API (like SteamGridDB), create a store
   class following the envelope cache pattern, add its key to `Secrets.swift`
   + `.env.example`, and wire it into the resolution chain.
5. Verify: `make build && make test`. For a visual check, run the app
   with `GAMEDOCK_WINDOWED=1` and scroll the category for the new source.

## Rules for the agent

- **Never decode images on the main thread.** All `CGImageSource`
  operations go through `decodeQueue`. The `thumbnailMaxSize` cap keeps
  memory bounded.
- **Never remove the fallback chain.** `cover → banner → placeholder` is
  what guarantees the UI never shows a broken image.
- **Call `invalidate()` on manual rescan.** `SteamGridDBStore.invalidate()`
  and (if added) similar stores must clear on Settings → Rescan to honor
  the "refetch on refresh" contract.
- **`.env` keys are secrets.** Don't log them. Don't commit `.env`. The
  `Secrets.is*Configured` bools exist so you can skip network calls
  gracefully when keys are absent.
- **IGDB cache key for titles uses `title.lowercased().hash`** — be aware
  this is `String.hash` (non-deterministic across launches on some Swift
  versions). If you see cache misses for the same title across launches,
  this is why. Consider switching to a stable hash (e.g. SHA256) if it
  becomes a problem.
