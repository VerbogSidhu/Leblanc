# GameDock — Optimization Worker Report

Applied the safe, provably-dead optimization items from `docs/audit-v2.md`
(§2 LIGHTNESS + §3 PERFORMANCE). No behavior change; `make build` clean and
`--selftest` still passes.

## Scope & rules honored

- Only removed/wired code that is provably dead (no callers) or safely
  simplified with identical behavior.
- Did **not** touch ABI-critical files (`Sources/CLibretro`, `Sources/CRcheevos`)
  or `Package.swift`, per constraints.
- Did **not** remove `GLHardwareBridge` (audit §2.2 explicitly says keep — the
  reference for the future melonDS-GL/3D path).
- Did **not** remove `GlobalHIDMonitor` capture (§2.9 — diagnostic contract).
- Did **not** drop the JetBrains Mono font or `CRcheevos` build dependency
  (§2.1, §2.7): the former is a bundled resource change (bundle assembly, not
  source), and the latter requires editing `Package.swift` — both out of bounds
  for this worker.

## Changes applied

### 1. Dead-code removal

| Change | Audit ref | Detail |
|---|---|---|
| Removed `controller.playerIndex = .index1` | §2.3 / §1.12 | Nothing read it; `InputSnapshot` reads port 0 regardless. |
| Removed `FrameSlot.pitch` field | §2.5 / §1.3 | Misleading dead state (stored *source* pitch but consumers use tight `width*4`). Confirmed zero remaining callers via `grep`. |
| Removed unused `Theme` tokens | §2.6 | `itemTitleUnselected`, `railHeight`, `screenPadding`, `fade` — all defined, never referenced. Kept `itemTitleSelected`, `spring` (both used). |
| Removed duplicate doc comment | §2.10 | `XMBNavModel.handle` had the same summary line twice. |

### 2. Performance simplifications (behavior-identical)

| Change | Audit ref | Detail |
|---|---|---|
| Cached a static `DateFormatter` | §3.7 | `AppEnvironment.metaLine` was allocating a `DateFormatter` per game item per XMB rebuild. Replaced with one shared `Self.lastPlayedFormatter`. |
| Bounded `ArtworkLoader` memory cache with LRU | §3.2 | `cache` was unbounded (`[String: NSImage]`), so a few hundred games could hold ~400 MB decoded. Added a `maxCacheEntries = 200` cap with an access-ordered eviction (`cacheOrder` + `touch`/`store` helpers). |
| Added `failed: Set<String>` to `ArtworkLoader` | §3.2 | Missing artwork was re-decoded (`NSImage(contentsOfFile:)`) on every `load()` body eval (`onReceive(loader.$loadedKeys)`). Now a confirmed miss short-circuits until a remote fetch succeeds. |

## Measurement

- **Binary size before:** 3,084,880 bytes (`.build/debug/GameDock`)
- **Binary size after:** 3,084,768 bytes (−112 bytes)

The delta is intentionally tiny: the dead code removed here is a few scalar
fields/tokens + one string literal, all already fully stripped of surrounding
weight by the linker. The two large levers flagged in the audit —
`CRcheevos` (~29k C lines, §2.1) and the JetBrains Mono font (270 KB, §2.7) —
are real but out of scope for this worker (require `Package.swift` edit /
bundle-assembly change respectively). See "Deferred" below.

## Verification

- `swift build` → **Build complete! (0.00s+)** clean.
- `make mock-core` + `swift run GameDock --selftest` → **SELFTEST PASS**
  (video frames ok, audio 25754 samples, movement ok).
- `grep`-verified no remaining references to the removed `pitch` field or the
  four removed `Theme` tokens.

## Deferred (explicitly out of scope, noted for a follow-up)

- **§2.1** — Drop `CRcheevos` from `GameDock`'s target dependencies (needs
  `Package.swift` edit; the single biggest lightness win, ~29k C lines).
- **§2.7** — Drop `JetBrainsMono-Regular.ttf` (270 KB) and route `Theme.meta`
  through ChakraPetch/system mono (bundle-assembly change).
- **§1.4 / §3.4** — Move `texture.replace(...)` outside the `FrameSlot` lock
  (needs a refcounted/ring of buffers; a correctness-sensitive refactor, not a
  dead-code strip).
- **§1.1 / §1.9 / §1.10** — Teardown join-timeout hardening and
  `AppDelegate.retryFullscreen` bail-on-success (behavioral fixes flagged under
  "CORRECTNESS"; deferred as they change semantics, not pure dead-code/lightness).

OPT WORKER DONE
