# Leblanc (GameDock) — Agent Onboarding Audit

> **Scope:** how easy is it for a new AI agent (or human developer) to start
> working on this project effectively? Audited against AGENTS.md, all 5
> `.pi/skills/`, the 16 `docs/` files, the build/test surface, and a spot-check
> of source files an agent would encounter on day one.
>
> **Method:** full read of every onboarding surface + source spot-checks
> (`AppEnvironment.swift`, `EmulatorSession.swift`, `LibraryStore.swift`,
> `ArtworkLoader.swift`, all `UI/*.swift`, `Theme.swift`, `GameDockFonts.swift`,
> `CLI.swift`, `CLIUnitTest.swift`, `Makefile`, `Package.swift`,
> `build-app.sh`, `orchestrate.mjs`). Build verification was not re-run
> (terminal execution was blocked in this session); build-cleanliness is
> cross-referenced against `docs/review-current-tree.md`, which records
> "`swift build` is clean; `make app` succeeds."

---

## 1. Onboarding Journey Map

A new agent lands in `/Users/verbog/GameDock` with no prior context. Here is
the path it would take and where it succeeds or stalls.

### What works well

- **AGENTS.md is a strong entry point.** It opens with a one-paragraph project
  brief, the hard constraints that shape every decision, an architecture tree,
  a module-status table with ✅/⚠️ markers, build commands, and landmines. An
  agent that reads only this file can orient in ~5 minutes.
- **The skills are the real onboarding gold.** Each is tightly scoped, names
  exact files, and documents invariants an agent must not break. They are
  materially better than AGENTS.md alone — an agent that loads the relevant
  skill before touching code will avoid the ABI landmines, the threading
  rules, and the input-router pattern.
- **The build/test surface is genuinely CLI-only and genuinely works** (per
  `review-current-tree.md`). `make build` / `make test` / `make selftest` are
  real, documented, and headless. An agent can verify its work without a GUI.

### Where the path gets lost

1. **The skills list in AGENTS.md is incomplete.** Line 13-14 names only four
   skills (`leblanc-build-verify, leblanc-architecture, leblanc-controller-input,
   leblanc-libretro-cores`) — it omits `leblanc-preview-panel`, which exists
   and is referenced later in the same file (line 144: "See
   `leblanc-preview-panel` skill"). An agent following the header instruction
   to "load before feature work" would miss one.

2. **`docs/design-spec.md` actively misleads.** This is the single biggest
   onboarding trap (detailed in §4 below). The spec describes amber-phosphor
   accents, SF Mono chrome, a horizontal filmstrip, and a "focus reticle" —
   none of which exist in the code. The actual UI is cyan-accented,
   Chakra-Petch/Horizontal XMB with a wave-field background. An agent that
   reads the design spec before the code will build the wrong thing.

3. **`docs/` has no index.** 16 files, no `docs/README.md`, no grouping. An
   agent cannot tell which docs are current reference vs. historical audit
   vs. completed plans without opening each one. The most valuable current
   audit (`review-current-tree.md`) is not distinguishable from superseded
   ones (`audit-v2.md`, `scout-review-report.md`) by filename alone.

4. **The architecture tree in AGENTS.md §2 is stale** — it omits the
   `RetroAchievements/` directory, `main.swift`, `AppEnvironment+Launch.swift`,
   and `AppEnvironment+Settings.swift` (all of which exist and are documented
   in the `leblanc-architecture` skill). An agent reading AGENTS.md alone
   would not know the app entry point is `main.swift` (not
   `GameDockApp.swift`'s `@main`), or that RetroAchievements is a full
   subsystem.

5. **No skill covers the UI layer.** Five skills exist: architecture,
   build-verify, controller-input, libretro-cores, preview-panel. None
   covers the view hierarchy, Theme tokens, overlay wiring, navigation
   models, the input→UI flow, or the `reduceMotion` convention. An agent
   doing UI work must reverse-engineer all of this from source. (Deliverable
   2 of this audit fills this gap.)

### The ideal reading order (what an agent *should* do)

1. `AGENTS.md` — orient (project brief, constraints, module map).
2. `.pi/skills/leblanc-architecture/SKILL.md` — the *current* module map +
   hard invariants (more accurate than AGENTS.md's tree).
3. `.pi/skills/leblanc-build-verify/SKILL.md` — how to verify before
   touching anything.
4. The domain skill matching the task (controller / libretro / preview / UI).
5. `docs/review-current-tree.md` — the freshest code audit (bugs + status).
6. **Skip `docs/design-spec.md`** until it is reconciled with the code (or
   read it only as historical context, clearly labeled stale).

---

## 2. AGENTS.md Assessment

### Completeness: good, with stale patches

| Section | Accurate? | Notes |
|---|---|---|
| §1 Project Brief | ✅ | Condensed, faithful. |
| §2 Architecture tree | ⚠️ stale | Omits `RetroAchievements/`, `main.swift`, `AppEnvironment+Launch.swift`, `AppEnvironment+Settings.swift`, `Core/GameDockFonts.swift`. The `leblanc-architecture` skill has the correct, current tree — AGENTS.md should match it. |
| §3 Module Map | ⚠️ incomplete | No RetroAchievements row at all (the skill documents it: `RAClient`, `RAHash`, `RACache`, `RAHubModel`, `RCClientService`). No rows for `CoreOptionsOverlay`, `PauseMenuOverlay`, `ConfirmationOverlay`, `EmulatorScreen`, `WaveField`, `GameDockFonts`. The skill's UI line is fuller. |
| §4 Build & Test | ✅ | Accurate, matches Makefile. |
| §5 Key technical notes | ✅ | Current and valuable — the `NSApp.hide` landmine, the GL bridge quirks, the PS-button macOS 27 experiment. |
| §6 Known limitations | ✅ | Honest and current. |
| §7 Git workflow | ✅ | Fine. |
| §8 Definition of Done | ✅ | All checked; matches what the skills describe as shipped. |
| §9 Sub-agent workflow | ✅ | Accurate (see §5 of this audit for the script's machine-specific caveat). |

### Specific confusions a new agent would hit

- **"Agent skills" header (line 13-14) lists 4 of 5.** The preview-panel skill
  is referenced by name at line 144 but not in the load-before-work list. Fix:
  add `leblanc-preview-panel` to the parenthetical.
- **The tree shows `GameDockApp.swift` as `@main entry`** (line 47). It is
  not — `main.swift` is the entry point and routes CLI flags before falling
  through to `GameDockApp.main()`. The `leblanc-architecture` skill states
  this correctly (line 32-33). An agent looking for the `@main` attribute
  will be confused.
- **The tree shows `UI/` as "XMBView, QuickBarView, SettingsNavModel,
  EmulatorView, Theme"** (line 56). The actual `UI/` directory has 16 files
  including `CoreOptionsOverlay.swift`, `PauseMenuOverlay.swift`,
  `ConfirmationOverlay.swift`, `EmulatorScreen.swift`, `WaveField.swift`,
  `RootView.swift`, `RemoteImage.swift`, `SelectionPreviewPanel.swift`.

### What's missing

- RetroAchievements in the module map (it's a whole subsystem with 7+ files).
- The `AppEnvironment` split files (`+Launch`, `+Settings`) — an agent editing
  launch or settings logic needs to know these exist.
- A one-line pointer to `docs/review-current-tree.md` as "the freshest audit."
- A correction note on `docs/design-spec.md` (see §4).

---

## 3. Skills Assessment

All five skills share a consistent format (YAML frontmatter `name` +
`description`, then markdown) and are well-written: file-accurate,
invariant-focused, and scoped. This is the strongest part of the onboarding
surface.

### leblanc-architecture — ✅ excellent, the most current doc in the repo

- Accurate module map (includes RetroAchievements, the AppEnvironment splits,
  all UI overlays, `main.swift` entry point).
- Hard invariants are precise and load-bearing (ABI shim, one-core-at-a-time,
  `@convention(c)` no-capture, `NSApp.hide` handoff rule, RA-credentials-in-
  UserDefaults rationale).
- The only skill that documents the RA credential migration rationale (lines
  76-81) — valuable context an agent would otherwise lose.
- **No issues found.** This is the reference doc; AGENTS.md should be
  reconciled to match it.

### leblanc-build-verify — ✅ accurate and concise

- Makefile targets match the actual `Makefile` (including `app-release`,
  `watch-hid`, which AGENTS.md/README don't all mention).
- CLI tool table is complete (`--selftest`, `--unit-test`, `--scan-steam`,
  `--diagnose-input`, `--probe-core`, `--ra-selftest`, `--preview-check`).
- Correctly documents the CLT-only constraint (no XCTest/swift-testing).
- **Minor:** doesn't mention `make watch-hid` or `make app-release` in the
  command block (they are in the Makefile and README). Not a blocker.

### leblanc-controller-input — ✅ accurate and detailed

- Mapping table, PS/Share probing, stick hysteresis, hold-to-repeat, keyboard
  fallback, haptics — all match source.
- The "adding a new button mapping" recipe is immediately actionable.
- **No issues found.**

### leblanc-libretro-cores — ✅ accurate and detailed

- Lifecycle contract, env table (including the core-options family now
  shipped), GL bridge landmines, audio/input, RA integration.
- Documents the deferred-`context_reset` segfault and the `GET_CAN_DUPE`
  bool-size write — both are real traps an agent would hit.
- **No issues found.**

### leblanc-preview-panel — ✅ accurate and focused

- Data flow diagram, debounce contract, image-source priority, rotation,
  playtime sources, CLI verification — all match source.
- The "purely additive" rule is correctly emphasized.
- **No issues found.**

### Missing skills

| Gap | Severity | Rationale |
|---|---|---|
| **UI layer** | 🔴 high | The biggest gap. No skill covers the view hierarchy, Theme tokens, overlay wiring, navigation models, input→UI flow, `reduceMotion` convention, or WaveField. UI is a primary work surface and an agent currently must read 8+ source files to understand it. **Filled by Deliverable 2.** |
| Discord layer | 🟡 medium | `DiscordController` is simple (read-only WKWebView) and covered adequately by AGENTS.md §5 + the architecture skill. A dedicated skill is lower value. |
| CLI/test harness | 🟢 low | `leblanc-build-verify` already covers the CLI flags. The harness internals (`CLIUnitTest.swift` assertion pattern) are self-documenting. |
| RetroAchievements | 🟡 medium | Partially covered by `leblanc-libretro-cores` (§RetroAchievements integration). A dedicated skill would help if RA feature work increases, but the current coverage is sufficient for v1. |

---

## 4. Docs Assessment

### Organization: no index, no grouping

`docs/` holds 16 files with no `README.md` or index. They are a mix of:

- **Design specs:** `design-spec.md`
- **Audits (code review):** `audit-v2.md`, `scout-review-report.md`,
  `review-current-tree.md`, `scout-ui-audit.md`, `audit-preview-qol.md`
- **Plans:** `plan-ui-ux-improvements.md`, `plan-libretro-metal.md`,
  `plan-core-options.md`, `plan-retroachievements.md`
- **Worker reports:** `worker-report.md`, `opt-worker-report.md`,
  `ra-worker-report.md`
- **Scout reports:** `scout-steam-report.md`
- **Feature brainstorm:** `feature-brainstorm.md`
- **Investigation:** `ps-button-report.md`

An agent cannot tell which are current vs. historical. There is no "this
supersedes that" marker except inside `review-current-tree.md` (line 22-25),
which notes that prior audits were cross-checked and some findings are
already fixed.

**Recommendation:** add a `docs/README.md` index that groups docs by type and
marks each with a one-line status (current / superseded / historical). Mark
`review-current-tree.md` as the canonical live audit.

### Staleness: `design-spec.md` is dangerously stale

`docs/design-spec.md` describes a design that does **not** match the shipped
code. This is the most damaging doc discrepancy in the repo:

| Aspect | `design-spec.md` says | Actual code (`Theme.swift`, `GameDockFonts.swift`, `XMBView.swift`) |
|---|---|---|
| Accent color | amber `#F2A93B` ("CRT phosphor, the one accent") | cyan `signal #4FD3FF` (primary accent); `ember #FF9F4A` is secondary ("recently played marker, sparingly") |
| Background | `void #0B0C10` | `void #0A0D16` (different hex) |
| Panel color | `panel #141418` | `ink #12172A` (renamed + different hex) |
| Text color | `ivory #E9E6DE` (warm off-white) | `paper #EDEFF5` (cool off-white) |
| Dim labels | `ash #6E6B63` | `mist #8B93A7` (cool gray, not warm) |
| Chrome font | SF Mono | Chakra Petch (custom bundled font, `GameDockFonts.display`) |
| Data font | SF Mono | JetBrains Mono (`GameDockFonts.data`) |
| Layout | left vertical rail (220pt) + hero (58%) + horizontal filmstrip | horizontal category rail + vertical item bar (selected large, neighbors peek above/below) — a horizontal XMB, not a vertical-rail + filmstrip |
| Signature element | "focus reticle" (4 amber L-brackets) | does not exist; replaced by `WaveField` (ambient sine layers + selection ripples) |
| Motion | "no ambient drift, no parallax" | `WaveField` is explicitly ambient drift (5 sine layers, 30fps `TimelineView`) |

An agent that reads `design-spec.md` and then implements a feature "to spec"
will produce UI that clashes with everything else. **The spec should either
be updated to match the shipped design or be clearly marked as a
superseded historical artifact.** The `leblanc-architecture` skill's UI line
and the new `leblanc-ui-layer` skill (Deliverable 2) document the *actual*
design tokens.

### Other doc staleness

- **`audit-v2.md` line 333-334** states the RA API token "never lands in
  UserDefaults/plist/logs" (i.e., it's in Keychain). The
  `leblanc-architecture` skill (lines 76-81) states the opposite: RA
  credentials were *moved out* of Keychain into UserDefaults (`raAPIToken`)
  because ad-hoc-signed builds prompted for the login password on every
  launch. These contradict. The architecture skill is more recent and more
  detailed (it describes the one-time migration rationale), so `audit-v2.md`
  is likely stale on this point — but an agent should verify
  `SettingsStore.swift` directly before acting on either claim.
- `audit-v2.md` and `scout-review-report.md` overlap heavily (both audit the
  same tree). `review-current-tree.md` supersedes both and notes which prior
  findings are fixed. An agent should read `review-current-tree.md` first and
  treat the other two as historical.

---

## 5. Verification Surface

### Can an agent actually build and test? Yes (per cross-reference).

The Makefile is clean, well-commented, and the targets match documentation:

```
make build        # swift build (debug)           ✅ documented + matches
make test         # --unit-test pure-logic        ✅ documented + matches
make selftest     # mock-core E2E                 ✅ documented + matches
make mock-core    # compile mockcore.dylib        ✅ documented + matches
make app          # assemble Leblanc.app (debug)  ✅ documented + matches
make app-release  # release build + strip         ✅ in Makefile (README-only)
make run          # build + open                  ✅ documented + matches
make scan-steam   # dump parsed Steam library    ✅ documented + matches
make diagnose     # controller inventory          ✅ documented + matches
make watch-hid    # headless HID watch (15s)      ✅ in Makefile (README-only)
make clean        # swift package clean + rm build ✅ documented + matches
```

The CLI harness (`CLIUnitTest.swift`) is a genuine regression battery:
VDFParser (escaping, comments, BOM, nested dicts, malformed input), RomTitle
(region/rev/tag stripping), PixelConverter, entry-id derivation,
PlaytimeFormatter, SteamLocalConfigReader, SteamScreenshotStore. It prints
`ok`/`FAIL` per check and exits non-zero on any failure. This is real
coverage for the pure-logic modules, documented honestly as a CLI harness
because the CLT-only machine has no XCTest.

### The gap between documented and actually works

- **Build cleanliness:** `review-current-tree.md` §5 flagged two spurious
  build warnings (`Package.swift` `CRcheevos` excludes for nonexistent
  `rc_libretro.c`/`.h`). The `leblanc-build-verify` skill says "Build must be
  warning-free." These two statements conflict; an agent should check whether
  the excludes were cleaned up. (I could not run `swift build` in this session
  to confirm — terminal execution was blocked.)
- **No automated UI test:** there is no headless verification for the SwiftUI
  view layer. `--selftest` covers the emulator plumbing; `--unit-test` covers
  pure logic; nothing covers view rendering, overlay wiring, or Theme token
  usage. An agent changing UI must verify by eye (`make run`) or by reading.
  This is an inherent limitation of a CLT-only, GUI app — but it should be
  stated so an agent doesn't assume `make test` covers UI.
- **`make app` vs `make app-release`:** `build-app.sh` handles both (`debug`
  default, `release` strips). Documented in README, not in AGENTS.md §4.

---

## 6. Friction Points

Specific things that slow an agent down, with file paths.

### 6.1 `design-spec.md` vs. reality (highest friction)

Covered in §4. An agent reading the spec first builds the wrong UI. Until
reconciled, every UI task starts with an un-learning step.

### 6.2 No UI skill — the input→UI flow is non-obvious

The single most important UI invariant — that all input funnels through
`AppEnvironment.gamepad(_:)` which checks modal overlays in a strict priority
chain (`pendingConfirmation` → `pauseMenuVisible` → `coreOptionsVisible` →
`discord.isFloating` → `quickBarVisible` → screenshot → screen-specific) — is
not documented anywhere. An agent adding a new overlay would not know to
insert it into this chain, and an agent debugging "why doesn't my button
work" would not know the priority order. (Filled by Deliverable 2.)

### 6.3 `reduceMotion` convention is unwritten

Every overlay and animated view reads `@Environment(\.accessibilityReduceMotion)`
and branches (`reduceMotion ? nil : Theme.spring`, `reduceMotion ? .opacity :
.move(edge:).combined(with: .opacity)`, `reduceMotion ? 0 : t` in WaveField).
This is a consistent convention across 8+ files but is documented nowhere.
An agent adding a new animated view would not know to follow it. (Documented
in Deliverable 2.)

### 6.4 Custom-font weight gotcha is undocumented

`GameDockFonts.swift` line 24-25: "do NOT chain `.weight()` on a custom font —
that makes SwiftUI fall back to the system font. The weight is baked into the
chosen file." This is a real trap (an agent writing `Theme.itemTitleSelected`
might try to add `.weight(.bold)` and silently break the font). It's in a code
comment but not in any skill or doc.

### 6.5 Overlays are split across two files, not documented

`RootView.swift` hosts the XMB/emulator screen switch + the global overlays
(QuickBar, error banner, StartingOverlay, ConfirmationOverlay,
CaptureToast). `EmulatorScreen.swift` hosts the emulator-specific overlays
(CoreOptionsOverlay, PauseMenuOverlay, boot overlay). An agent looking for
"where is the pause menu wired" must check both. Neither AGENTS.md nor the
skills state this split. (Documented in Deliverable 2.)

### 6.6 AGENTS.md architecture tree omits `main.swift`

An agent searching for the `@main` attribute will not find it on
`GameDockApp.swift` (the tree says it's the entry point). The real entry is
`main.swift`, which routes CLI flags. The `leblanc-architecture` skill states
this; AGENTS.md does not.

### 6.7 `Scripts/subagents/orchestrate.mjs` is machine-locked

The orchestrator hardcodes absolute imports
(`/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/...`) and
`PROJECT = "/Users/verbog/GameDock"`. The code itself acknowledges this
(lines 22-23). An agent on a different machine (or a fresh checkout) cannot
run the subagent pipeline without editing the script. Low impact for
single-machine use, but worth noting for portability.

### 6.8 Docs have no "current vs. superseded" markers

`review-current-tree.md` is the live audit but is not flagged as such. An
agent might read `audit-v2.md` (older, partially stale) first and act on
findings already fixed. A one-line header in each doc, or an index, would
fix this.

---

## Summary of recommended fixes (priority order)

1. **Reconcile `docs/design-spec.md`** with the shipped Theme/UI, or mark it
   superseded. (Highest impact — it actively misleads.)
2. **Add the `leblanc-ui-layer` skill** (Deliverable 2) and add it to the
   AGENTS.md skills list.
3. **Fix the AGENTS.md skills header** (line 13-14) to list all 5 (soon 6)
   skills.
4. **Update AGENTS.md §2 architecture tree** to match the
   `leblanc-architecture` skill (add `RetroAchievements/`, `main.swift`,
   the `AppEnvironment` splits, the missing `UI/` files).
5. **Add a `docs/README.md` index** grouping docs by type with status
   markers; flag `review-current-tree.md` as the canonical live audit.
6. **Resolve the RA-credentials contradiction** between `audit-v2.md`
   (Keychain) and `leblanc-architecture` (UserDefaults) — verify
   `SettingsStore.swift` and correct the stale one.
7. **Note the "no headless UI test" gap** in `leblanc-build-verify` so an
   agent doesn't assume `make test` covers views.

AUDIT DONE
