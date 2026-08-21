# docs/ — Index

18 files: design specs, audits, plans, worker reports, and investigations.
Read this first to find the right doc and avoid stale ones.

## Design

| File | Status | What |
|---|---|---|
| `design-spec.md` | ⚠️ SUPERSEDED | Original design lead's creative direction (amber phosphor, rail+hero+filmstrip, focus reticle). The shipped UI does NOT match this — see `leblanc-ui-layer` skill for actual tokens, and `ui-ux-critique.md` for the gap analysis. Kept for reference. |
| `feature-brainstorm.md` | current | Feature ideas, not yet implemented. |

## Live audits (read these first)

| File | Status | What |
|---|---|---|
| `review-current-tree.md` | ✅ canonical | The current codebase health audit. Start here for a snapshot of the whole tree. |
| `agent-onboarding-audit.md` | ✅ current | How agent-friendly the codebase is. Scores AGENTS.md, skills, docs. Supersedes `audit-agent-onboarding.md`. |
| `ui-ux-critique.md` | ✅ current | Strategic UI/UX weakness analysis + the "should Leblanc use a different UI" question. Spec-vs-implementation gap, paradigm comparison, concrete recommendations. |
| `audit-preview-qol.md` | ✅ current | Correctness audit of the selection preview panel + QoL batch. |
| `audit-codebase-health.md` | ✅ current | General codebase health audit. |

## Historical audits (superseded — read only for context)

| File | Status | What |
|---|---|---|
| `audit-v2.md` | superseded by `review-current-tree.md` | Older codebase audit. RA-credential location is stale (says Keychain; now UserDefaults). |
| `scout-review-report.md` | superseded by `review-current-tree.md` | Earlier scout review. References old `GameDock` executable name (now `Leblanc`). |
| `scout-ui-audit.md` | partially superseded by `ui-ux-critique.md` | Text cutoffs & transition bugs in the XMB. Findings still valid; the broader critique is in `ui-ux-critique.md`. |
| `audit-agent-onboarding.md` | superseded by `agent-onboarding-audit.md` | Prior onboarding audit. Says "5 skills" and "no UI skill" — both now false. |

## Plans

| File | Status | What |
|---|---|---|
| `plan-ui-ux-improvements.md` | partially implemented | 5-phase UI/UX plan (bugs → states → nav → polish → bets). Many Phase 1-2 items shipped. |
| `plan-libretro-metal.md` | ✅ implemented | Libretro Metal render path. See `Launch/MetalRenderer.swift`, `GLHardwareBridge.swift`. |
| `plan-core-options.md` | ✅ implemented | Core options overlay. See `UI/CoreOptionsOverlay.swift`, `Launch/CoreOptionsModel.swift`. |
| `plan-retroachievements.md` | ✅ implemented | RetroAchievements integration. See `Sources/GameDock/RetroAchievements/`, `Sources/CRcheevos/`. |

## Worker reports (implementation logs)

| File | What |
|---|---|
| `worker-report.md` | Libretro frontend implementation report. |
| `opt-worker-report.md` | Core options implementation report. |
| `ra-worker-report.md` | RetroAchievements implementation report. |

## Scout reports

| File | What |
|---|---|
| `scout-steam-report.md` | Steam VDF/ACF parsing recon. |

## Investigations

| File | What |
|---|---|
| `ps-button-report.md` | PS-button global capture investigation (macOS 14/15 unreliability, macOS 27 beta re-enable). |
