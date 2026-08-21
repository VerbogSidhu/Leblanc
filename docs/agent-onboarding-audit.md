# Leblanc (GameDock) — Agent Onboarding Audit

> **Scope:** how agent-friendly is this codebase for a future AI agent landing cold
> in `/Users/verbog/GameDock`? Audited against `AGENTS.md`, all 6 `.pi/skills/`,
> the 18 `docs/` files, the build/test surface, and a source spot-check of every
> directory under `Sources/` to verify the documented module maps against reality.
>
> **Method:** full read of AGENTS.md, every SKILL.md, `Package.swift`, `Makefile`,
> `orchestrate.mjs`, `.env.example`; directory listings of every `Sources/` subdir;
> source spot-checks of `CLI.swift`, `Secrets.swift`, `SteamGridDBStore.swift`,
> `IGDBClient.swift`, `FavoritesStore.swift`, `JSONFileStore.swift`,
> `StatusMonitor.swift`; header reads of the key `docs/` reports. Build/test was
> not re-run (read-only audit); build-cleanliness is cross-referenced against
> `docs/review-current-tree.md`, which records "`swift build` is clean;
> `make app` succeeds."
>
> **This audit supersedes** `docs/audit-agent-onboarding.md`, which is now stale
> (it predates the `leblanc-ui-layer` skill and several subsystems — see §1.5).

---

## Executive summary

The codebase has **strong agent infrastructure** that is **partially stale**.
The skills are genuinely excellent — tightly scoped, file-accurate, and
invariant-focused. AGENTS.md is a good orientation doc that has fallen behind
the code in three concrete ways. The `docs/` directory has no index and one
dangerously misleading file. The biggest *undocumented* surface is the
**metadata/artwork pipeline** (SteamGridDB + IGDB + `.env` secrets), which spans
two directories and has no skill and no AGENTS.md row.

| Area | Score | Verdict |
|---|---|---|
| AGENTS.md | **7.5 / 10** | Strong structure, stale module map (§1.2) |
| Skills (6) | **9 / 10** | Excellent and current; one coverage gap (§2.5) |
| `docs/` directory | **5 / 10** | No index; one dangerously stale spec (§3.2) |
| Overall onboarding | **7 / 10** | A cold-start agent can orient, but will miss 2 subsystems |

A new agent that **reads AGENTS.md + loads the relevant skill** can avoid the
ABI and threading landmines and be productive. It will, however, miss the
metadata/artwork pipeline entirely, and may be misled by `design-spec.md` unless
it also reads the `leblanc-ui-layer` skill.

---

## 1. AGENTS.md Audit

### Rubric (10 points)

| Criterion | Max | Score | Notes |
|---|---|---|---|
| Accuracy vs. actual tree | 3 | 1.5 | Architecture tree omits 3 subsystems + entry point (§1.2) |
| Completeness for a cold start | 2 | 1.5 | Missing metadata pipeline, secrets contract, CRcheevos (§1.3) |
| Navigability (find the right file fast) | 2 | 2 | Module map + status table + section anchors work well |
| Failure-mode coverage | 2 | 1.5 | ABI/threading/build covered; artwork/persistence gaps (§1.4) |
| Best-practice alignment | 1 | 1 | Good structure; would benefit from a troubleshooting section |
| **Total** | **10** | **7.5** | |

### 1.1 What works well

- **Strong entry point.** Opens with a one-paragraph brief, the hard constraints
  that shape every decision, and a status line. An agent that reads only this
  file orients in ~5 minutes.
- **The module-status table (§3) is the right idea** — owner-role + path + status
  (✅/⚠️/🔲) is scannable and signals trust level.
- **§4 Build & Test is accurate** — `make build/test/selftest/mock-core/app`
  match the actual `Makefile`. The CLT-only constraint (no XCTest) is stated.
- **§5 landmines are load-bearing and correct** — the ABI-critical shim, the
  one-core-at-a-time rule, `@convention(c)` no-capture, the `NSApp.hide`
  handoff rule, and the PS-button macOS-version reality are all real traps an
  agent would hit, and they are documented precisely.
- **The skills list (line 13-15) is now complete** — it lists all 6 skills,
  including `leblanc-ui-layer`. (The prior audit flagged this as broken; it has
  since been fixed.)

### 1.2 🔴 The §2 architecture tree is stale — the biggest accuracy gap

AGENTS.md §2's directory tree does not match the actual `Sources/` tree. It
omits entire subsystems that an agent would need to know about:

| Present in `Sources/` | In AGENTS.md §2 tree? | Documented elsewhere? |
|---|---|---|
| `Sources/CRcheevos/` (vendored RetroAchievements C lib, ~29k lines) | ❌ No | `Package.swift`, `leblanc-libretro-cores` skill |
| `Sources/GameDock/RetroAchievements/` (8 Swift files) | ❌ No | `leblanc-architecture` skill module map |
| `Sources/GameDock/CLI/` (5 files) | ❌ No | `leblanc-architecture` + `leblanc-build-verify` skills |
| `Sources/GameDock/main.swift` (entry point — routes CLI flags) | ❌ No | `leblanc-architecture` skill |
| `AppEnvironment+Launch.swift`, `AppEnvironment+Settings.swift` | ❌ No | `leblanc-architecture` skill |
| `Sources/GameDock/Core/Secrets.swift` + `.env` contract | ❌ No | nowhere |
| `Libraries/SteamGridDBStore.swift`, `IGDBClient.swift`, `FavoritesStore.swift` | ❌ No | nowhere |

An agent reading AGENTS.md alone would not know:
- The app entry point is `main.swift` (which routes `--selftest` etc. before
  falling through to `GameDockApp.main()`), **not** `GameDockApp.swift`'s `@main`.
  AGENTS.md line 48 says `GameDockApp.swift` is the "@main entry" — misleading.
- RetroAchievements is a full subsystem with its own vendored C target
  (`CRcheevos`), not a stub. The `ra-worker-report.md` confirms it is wired end
  to end.
- There is a CLI directory with 5 tools, not the 2 implied by the tree.

The `leblanc-architecture` skill has the **correct, current** module map
(including RetroAchievements, the AppEnvironment splits, `main.swift`, all UI
overlays). **AGENTS.md §2 should be reconciled to match the architecture skill.**

### 1.3 Completeness gaps for a cold-start agent

Three subsystems a new agent would need to discover by reading source:

1. **The metadata/artwork pipeline (undocumented anywhere).** `SteamGridDBStore`
   (community art for Steam games), `IGDBClient` (Twitch-OAuth → IGDB genre/year/
   summary), and `Secrets.swift` (`.env` loader for `STEAM_GRID_DB_KEY`,
   `TWITCH_CLIENT_ID/SECRET`, `SCREENSCRAPER_*`). `.env.example` exists but is
   never referenced by AGENTS.md or any skill. An agent asked to "add artwork for
   ROMs" would not know this pipeline exists or that it requires `.env` keys.

2. **The secrets/configuration contract.** `.env` at repo root is gitignored and
   holds live API keys; `.env.example` is the template. Neither AGENTS.md nor any
   skill mentions this. An agent that runs the app and wonders why IGDB/SteamGridDB
   return empty has no documented pointer to `.env`.

3. **`CRcheevos` build settings.** `Package.swift` shows it is compiled with
   `-fno-modules -fno-objc-arc` and 4 header search paths — an agent touching the
   RetroAchievements C target could break the build without knowing these are
   load-bearing. Not in AGENTS.md.

### 1.4 Failure-mode coverage

AGENTS.md covers the *emulator/libretro* failure modes thoroughly (ABI, threading,
`@convention(c)`, `NSApp.hide`). It is thinner on:

- **Persistence layer:** recents/settings live in `~/Library/Application
  Support/GameDock/` (mentioned), but the `JSONFileStore` abstraction
  (`Core/JSONFileStore.swift`) and which stores use it (`FavoritesStore`,
  `RecentsStore`) is not documented. An agent adding a new persisted collection
  would reinvent the locking boilerplate.
- **Artwork caching TTLs:** the 1-week disk-cache envelope pattern (shared by
  `SteamScreenshotStore`, `SteamGridDBStore`) is not surfaced as a convention.
- **No troubleshooting section.** Best-practice AGENTS.md files include a
  "common mistakes" or "if X fails, check Y" section. This one has landmines but
  no symptom→cause map (e.g., "if `--selftest` fails with `dlopen` error →
  `make mock-core` first"; "if UI is blank → check `reduceMotion` branch").

### 1.5 The prior onboarding audit is itself stale

`docs/audit-agent-onboarding.md` (the file this audit effectively replaces)
states "5 `.pi/skills/`" and lists "No skill covers the UI layer" as its top
gap. Both are now false — `leblanc-ui-layer` exists and is high quality. This
is a good sign (the gap was closed) but means a new agent reading the old audit
gets wrong information.

---

## 2. Skills Audit (`.pi/skills/`)

There are **6 skill directories** (AGENTS.md now correctly lists all 6):

`leblanc-architecture`, `leblanc-build-verify`, `leblanc-controller-input`,
`leblanc-libretro-cores`, `leblanc-preview-panel`, `leblanc-ui-layer`.

### Rubric (10 points)

| Criterion | Max | Score | Notes |
|---|---|---|---|
| Accuracy to current code | 3 | 3 | All 6 match source; file paths verified |
| Right topic coverage | 2 | 1.5 | One real gap: metadata/artwork pipeline (§2.5) |
| Frontmatter consistency & usefulness | 2 | 2 | All have `name`+`description`; descriptions are load-bearing |
| Length / signal density | 2 | 1.5 | Mostly tight; architecture skill has a duplicated Core row |
| Cite real paths | 1 | 1 | Every skill cites concrete paths; line-number refs where relevant |
| **Total** | **10** | **9** | |

### 2.1 Frontmatter format — consistent and well-formed

All 6 files use identical frontmatter:
```yaml
---
name: <skill-name>
description: <one-paragraph, includes "Use when...">
---
```
The descriptions are genuinely useful for skill *selection* (not just
description) — each states the trigger condition ("Use when adding, debugging,
or remapping controller features"). This is best practice and done correctly
across all 6. No inconsistency.

### 2.2 Per-skill assessment

**`leblanc-architecture` — ✅ reference doc.** The most current and complete
map in the repo: includes RetroAchievements, the AppEnvironment splits, all UI
overlays, `main.swift` entry point, and the RA-credential-migration rationale
(lines 76-81) that exists nowhere else. Hard invariants are precise. This is the
document AGENTS.md should be reconciled *toward*.
- **Minor defect:** the module table has a duplicated `Core/` row (lines 22 and
  30 list overlapping contents — line 22 omits `PlaytimeFormatter`, line 30 adds
  it but also repeats Models/Logger/etc.). Should be merged into one row.

**`leblanc-build-verify` — ✅ accurate and concise.** Makefile targets, CLI tool
table (all 7 flags), env vars, golden rules. Correctly documents the CLT-only
constraint.
- **Minor:** the command block doesn't mention `make watch-hid` or
  `make app-release`, both present in the `Makefile`. Low impact.

**`leblanc-controller-input` — ✅ excellent.** Mapping table, PS/Share probing,
stick hysteresis, hold-to-repeat, keyboard fallback, haptics, thread-safety, and
an actionable "add a new button mapping" recipe. No issues.

**`leblanc-libretro-cores` — ✅ excellent.** Lifecycle contract, full
`retro_environment` table (including the core-options family), GL bridge
landmines (deferred `context_reset` segfault, `GET_CAN_DUPE` bool-size write),
audio/input, and RA integration. The landmine callouts are exactly what an agent
needs to avoid corrupting memory or crashing cores.

**`leblanc-preview-panel` — ✅ focused and accurate.** Data-flow diagram, debounce
contract, image-source priority, rotation, playtime sources, CLI verification.
The "purely additive" rule is correctly emphasized.

**`leblanc-ui-layer` — ✅ excellent (the newest skill).** View hierarchy tree,
full Theme token table with hexes, the custom-font-weight trap, the
`reduceMotion` convention, all nav models, the input-router priority chain,
WaveField internals, and a "design spec vs. implementation gap" section that
explicitly warns the spec is stale. This skill does the work that AGENTS.md §2
should do for the UI. Its existence closes the prior audit's #1 gap.

### 2.3 Length assessment

All skills are appropriately sized (60-120 lines each). None are too short to be
useful; none are so long they bury the invariants. The architecture skill is the
densest and could split the "Rules for the agent" tail into a separate
troubleshooting section, but it is not bloated.

### 2.4 Do they cite real paths and line numbers?

Every skill cites concrete file paths (verified present). Line-number references
are used sparingly but accurately (e.g., the architecture skill cites
`EmulatorSession` lifecycle stages by method name rather than line, which is more
robust to drift than line numbers — a good choice). The `leblanc-ui-layer` skill
cites `zIndex` values and overlay flags by name. Good practice throughout.

### 2.5 Coverage gap — the metadata/artwork pipeline

No skill covers the **metadata and artwork acquisition pipeline**:

- `Libraries/SteamGridDBStore.swift` — community art (capsules/logos/heroes) for
  Steam games via `steamgriddb.com/api/v2/`, Bearer-token auth, 1-week disk cache.
- `Libraries/IGDBClient.swift` — Twitch OAuth client-credentials → IGDB
  (genre/release year/developer/publisher/summary) for *any* game.
- `Core/Secrets.swift` — `.env` loader (gitignored) + env-var overrides for
  `STEAM_GRID_DB_KEY`, `TWITCH_CLIENT_ID/SECRET`, `SCREENSCRAPER_*`.
- `Libraries/ArtworkLoader.swift` — the existing Steam header-art loader.

This is a real work surface (an agent is likely to be asked "add ROM artwork" or
"show game metadata") and it crosses two directories + a secrets contract that
are documented nowhere. A dedicated `leblanc-metadata-artwork` skill would close
this. See §4.1.

### 2.6 Lower-priority skill gaps

| Gap | Severity | Rationale |
|---|---|---|
| RetroAchievements (dedicated skill) | 🟡 medium | Partially covered by `leblanc-libretro-cores` §RA integration + the architecture skill. A dedicated skill would help if RA feature work increases; the `CRcheevos` build settings and `RCClientService` trampoline pattern warrant it. |
| Discord layer | 🟢 low | `DiscordController` is simple (read-only WKWebView) and adequately covered by AGENTS.md §5 + the architecture skill. |
| Persistence layer (`JSONFileStore`) | 🟢 low | Small, self-documenting; a one-line mention in the architecture skill would suffice. |

---

## 3. `docs/` Directory Audit

`docs/` holds 18 files (the prior audit counted 16; two have been added). There is
no `docs/README.md` index.

### Rubric (10 points)

| Criterion | Max | Score | Notes |
|---|---|---|---|
| Organization / navigability | 3 | 1 | No index, no grouping, no status markers (§3.1) |
| Currency (no doc rot) | 3 | 1.5 | `design-spec.md` dangerously stale (§3.2); scattered minor rot (§3.3) |
| Workflow doc for using docs/ | 2 | 1 | Only `review-current-tree.md` notes supersession; no global guide |
| Quality of individual reports | 2 | 1.5 | Reports themselves are strong; discoverability is the problem |
| **Total** | **10** | **5** | |

### 3.1 🔴 No index — the core docs problem

18 files with no `README.md`, no grouping, no status field. They are a mix of:

- **Design spec:** `design-spec.md`
- **Live audits:** `review-current-tree.md` (the canonical current one),
  `audit-agent-onboarding.md` (stale — see §1.5)
- **Historical audits:** `audit-v2.md`, `scout-review-report.md`, `scout-ui-audit.md`,
  `audit-codebase-health.md`, `audit-preview-qol.md`
- **Plans:** `plan-ui-ux-improvements.md`, `plan-libretro-metal.md`,
  `plan-core-options.md`, `plan-retroachievements.md`
- **Worker reports:** `worker-report.md`, `opt-worker-report.md`,
  `ra-worker-report.md`
- **Scout reports:** `scout-steam-report.md`
- **Feature brainstorm:** `feature-brainstorm.md`
- **Investigation:** `ps-button-report.md`

An agent cannot tell which are current reference vs. historical. The most
valuable current audit (`review-current-tree.md`) is not distinguishable from
superseded ones (`audit-v2.md`, `scout-review-report.md`) by filename alone.

**Recommendation:** add a `docs/README.md` index grouping by type with a
one-line status per file (current / superseded / historical). Mark
`review-current-tree.md` as the canonical live audit and `audit-v2.md` +
`scout-review-report.md` as superseded-by it.

### 3.2 🔴 `design-spec.md` is dangerously stale — the most damaging doc

`docs/design-spec.md` describes a design that does **not** match the shipped
code. This is the single biggest onboarding trap in the repo:

| Aspect | `design-spec.md` says | Actual code (`Theme.swift`, `GameDockFonts.swift`) |
|---|---|---|
| Accent | amber `#F2A93B` ("the one accent") | cyan `signal #4FD3FF` (primary); `ember #FF9F4A` secondary |
| Background | `void #0B0C10` | `void #0A0D16` |
| Panel | `panel #141418` | `ink #12172A` |
| Text | `ivory #E9E6DE` (warm) | `paper #EDEFF5` (cool) |
| Dim | `ash #6E6B63` (warm) | `mist #8B93A7` (cool) |
| Chrome font | SF Mono | Chakra Petch (bundled) |
| Data font | SF Mono | JetBrains Mono (bundled) |
| Layout | left vertical rail (220pt) + hero + horizontal filmstrip | horizontal category rail + vertical item bar (horizontal XMB) |
| Signature | "focus reticle" (amber L-brackets) | `WaveField` (ambient sines + ripples) — which the spec explicitly forbids |
| Motion | "no ambient drift" | `WaveField` is ambient drift |

An agent that reads `design-spec.md` and then implements "to spec" will produce
UI that clashes with everything else. The `leblanc-ui-layer` skill documents the
*actual* tokens and has a "design spec vs. implementation gap" section, but an
agent must know to load that skill *first*. The spec should either be updated to
match shipped code or clearly marked `> **STATUS: SUPERSEDED**` at the top.

### 3.3 Other doc rot (minor)

- **`audit-v2.md` lines 333-334** state the RA API token "never lands in
  UserDefaults" (i.e., it's in Keychain). The `leblanc-architecture` skill
  (lines 76-81) states the opposite — RA credentials were *moved out* of Keychain
  into UserDefaults (`raAPIToken`) because ad-hoc-signed builds prompted for the
  login password on every launch. The architecture skill is more recent and
  detailed; `audit-v2.md` is stale on this point.
- **`scout-review-report.md` line 7** references `swift run GameDock --selftest`
  (old executable name). The product is now `Leblanc`
  (`Package.swift` line 18). Minor, but an agent copy-pasting the command gets a
  "no such target" error.
- **`audit-agent-onboarding.md`** (the prior version of this very audit) is stale:
  it says "5 skills" and "No skill covers the UI layer." Both are now false.

### 3.4 Scout/plan/worker reports — well-structured individually, not navigable as a set

The subagent pipeline (`scout → planner → worker`, via
`Scripts/subagents/orchestrate.mjs`) produces high-quality, well-scoped reports.
`plan-retroachievements.md` → `ra-worker-report.md` is a clean plan→impl pair with
explicit "plan corrections confirmed at build time." This is good practice.

But there is no manifest linking a plan to its worker report, and no marker that
a plan is "implemented" vs. "pending." An agent seeing `plan-libretro-metal.md`
cannot tell at a glance whether it shipped (it did — see the `GLHardwareBridge`
in `Launch/`) without reading the whole plan and cross-referencing source.

**Recommendation:** each plan should end with a `> **Status: IMPLEMENTED**` (or
`PENDING` / `SUPERSEDED`) line, and `docs/README.md` should link plan→worker pairs.

### 3.5 The orchestrator has machine-absolute imports

`Scripts/subagents/orchestrate.mjs` lines 15-16 import the pi agent from
`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/...` and hardcode
`PROJECT = "/Users/verbog/GameDock"`. The file comments this
("absolute paths to THIS machine"). This is fine for the current single-machine
setup but means the subagent pipeline is not portable to another agent/host
without edits. Worth a note in AGENTS.md §9 so an agent doesn't assume the
orchestrator "just works" elsewhere.

---

## 4. Gap Analysis

### 4.1 Missing skills

| Proposed skill | Severity | Why |
|---|---|---|
| **`leblanc-metadata-artwork`** | 🔴 high | The artwork/metadata pipeline (SteamGridDB + IGDB + `Secrets`/`.env` + `ArtworkLoader`) is entirely undocumented, crosses 2 directories, and has a secrets contract. An agent will be asked to work on this surface. |
| `leblanc-retroachievements` | 🟡 medium | A full subsystem now (8 Swift files + `CRcheevos` C target + trampolines). Partially covered by `leblanc-libretro-cores`; a dedicated skill would document the `CRcheevos` build settings, the `RCClientService.active` trampoline pattern, and the `RAToastModel` thread-safety contract. |

### 4.2 Missing AGENTS.md sections

- **Troubleshooting / common-mistakes section.** Symptom→cause map (e.g.,
  "blank UI → check `reduceMotion` branch"; "`--selftest` dlopen error →
  `make mock-core` first"; "IGDB returns empty → check `.env` keys").
- **Secrets/configuration contract.** One paragraph: `.env` at repo root
  (gitignored), `.env.example` template, which keys each subsystem needs, env-var
  override precedence. Currently discoverable only by reading `Secrets.swift`.
- **Reconciled §2 architecture tree** matching `leblanc-architecture`'s module map
  (the single highest-impact fix — see §5).
- **Persistence conventions.** One line on `JSONFileStore` and which stores use
  it, so agents don't reinvent the locking boilerplate.

### 4.3 Missing docs

- **`docs/README.md` index** — the highest-impact docs fix. Groups by type,
  one-line status per file, links plan→worker pairs.
- **Architecture/data-flow diagram.** No visual of the screen-state machine
  (`AppScreen.xmb ↔ .emulator` + overlay priority chain) or the input-router
  flow. The `leblanc-ui-layer` skill has the router priority chain as text; a
  diagram in `docs/` would help agents who think visually. (The text version is
  sufficient; this is a "nice to have," not a blocker.)
- **State-machine doc for screen transitions.** The `AppEnvironment.gamepad(_:)`
  priority chain is documented in the UI skill but not as a standalone reference.

### 4.4 File organization

Files are where an agent would expect them, with one exception: **`Secrets.swift`
lives in `Core/`** but is consumed exclusively by `Libraries/` clients
(`SteamGridDBStore`, `IGDBClient`). This is defensible (it's a generic loader)
but an agent grepping `Libraries/` for "where do API keys come from" won't find
it without also reading `Core/`. A cross-reference in a metadata skill would
resolve this without moving the file.

No other organization issues found. The `Launch/`, `Controllers/`, `UI/`,
`RetroAchievements/`, `Discord/` boundaries are clean and match the skills.

---

## 5. Prioritized Action List

Ranked by impact on a cold-start agent. Each is specific enough to implement
directly.

### P0 — High impact, low effort

1. **Reconcile AGENTS.md §2 architecture tree** to match the
   `leblanc-architecture` skill's module map. Add `Sources/CRcheevos/`,
   `Sources/GameDock/RetroAchievements/`, `Sources/GameDock/CLI/`,
   `main.swift`, `AppEnvironment+Launch.swift`, `AppEnvironment+Settings.swift`,
   and the missing `Libraries/` files (`SteamGridDBStore`, `IGDBClient`,
   `FavoritesStore`). Fix the `GameDockApp.swift` "main entry" line to note
   `main.swift` routes CLI flags first. *(Closes §1.2 — the biggest accuracy gap.)*

2. **Mark `docs/design-spec.md` as SUPERSEDED** at the top (one blockquote line),
   or update it to match shipped tokens. Until then it actively misleads. The
   `leblanc-ui-layer` skill already documents the real tokens. *(Closes §3.2.)*

3. **Add `docs/README.md` index** grouping the 18 docs by type (design / live
   audit / historical audit / plan / worker / scout / investigation) with a
   one-line status per file. Mark `review-current-tree.md` canonical;
   mark `audit-v2.md` + `scout-review-report.md` superseded-by it; mark the prior
   `audit-agent-onboarding.md` superseded by this file. *(Closes §3.1.)*

### P1 — High impact, medium effort

4. **Add a `leblanc-metadata-artwork` skill** covering `SteamGridDBStore`,
   `IGDBClient`, `ArtworkLoader`, `Secrets`/`.env`, the 1-week disk-cache
   envelope pattern, and which `.env` keys each subsystem needs. Include the
   "add artwork for a new source" recipe. *(Closes §2.5 + §4.1.)*

5. **Add a "Secrets & configuration" section to AGENTS.md** (§5.5 or new §6):
   `.env` at repo root (gitignored), `.env.example` template, env-var override
   precedence, and the key→subsystem map. One paragraph. *(Closes §1.3 #2.)*

6. **Add a troubleshooting section to AGENTS.md** (new §5.6 or §9): a
   symptom→cause table for the ~6 most likely agent failures (dlopen error,
   blank UI, empty metadata, hung core, RA inert, PS button unresponsive).
   *(Closes §1.4.)*

### P2 — Medium impact, low effort

7. **Fix the duplicated `Core/` row** in the `leblanc-architecture` skill
   (lines 22 and 30 overlap). Merge into one row listing all Core files.
   *(Closes §2.2.)*

8. **Add `make watch-hid` and `make app-release`** to the
   `leblanc-build-verify` command block (both are in the `Makefile`).
   *(Closes §2.2.)*

9. **Add a "Status: IMPLEMENTED" footer** to each `plan-*.md` (or a status field
   in the `docs/README.md` index) so an agent can tell at a glance whether a plan
   shipped. *(Closes §3.4.)*

10. **Fix the stale executable name** in `scout-review-report.md` line 7
    (`GameDock` → `Leblanc`) and any other docs that reference the old name.
    *(Closes §3.3.)*

### P3 — Low impact / nice-to-have

11. **Add a `leblanc-retroachievements` skill** if RA feature work is expected to
    increase. Document the `CRcheevos` build settings (`-fno-modules`,
    `-fno-objc-arc`, header search paths), the `RCClientService.active`
    trampoline pattern, and `RAToastModel` thread safety. *(Closes §4.1.)*

12. **Note the orchestrator's machine-absolute imports** in AGENTS.md §9 so a
    future agent doesn't assume `orchestrate.mjs` is portable. *(Closes §3.5.)*

13. **Delete or archive `docs/audit-agent-onboarding.md`** (the stale prior
    audit) now that this file supersedes it, to prevent an agent reading the
    wrong one. *(Closes §1.5.)*

---

## Verification state

- **Read directly:** `AGENTS.md` (full), all 6 `SKILL.md` (full), `Package.swift`,
  `Makefile`, `.env.example`, `Scripts/subagents/orchestrate.mjs`,
  `CLI.swift`, `Secrets.swift`, `SteamGridDBStore.swift`, `IGDBClient.swift`,
  `FavoritesStore.swift`, `JSONFileStore.swift`, `StatusMonitor.swift`, and the
  first 20-60 lines of 7 `docs/` reports.
- **Directory listings verified:** every subdir under `Sources/`
  (`CLibretro/`, `CRcheevos/`, `GameDock/{Core,Libraries,Launch,UI,Controllers,
  CLI,RetroAchievements,Discord}/`).
- **Not re-run:** `make build` / `make selftest` (read-only audit). Build status
  cross-referenced from `docs/review-current-tree.md` ("`swift build` is clean;
  `make app` succeeds").
- **Unverified claims to spot-check before acting:** the RA-credential location
  (`audit-v2.md` says Keychain; architecture skill says UserDefaults — verify
  `SettingsStore.swift` directly before acting on either).
