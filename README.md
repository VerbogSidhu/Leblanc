# Leblanc

A native macOS (Apple Silicon) **controller-first gaming frontend** — Steam,
libretro emulators, and Discord in one fullscreen, gamepad-navigable console
dashboard. Built with SwiftUI + AppKit + Metal + GameController.

> **This repo is a Swift Package, not an Xcode project.** It builds entirely
> with the Command Line Tools (`swift build`), which is why it works in any
> environment. To use Xcode, just `open Package.swift` — Xcode treats SPM
> packages natively and can run the `GameDock` scheme.

```
make build      # swift build
make app        # assemble build/Leblanc.app (ad-hoc signed)
make run        # build + open the app
make test       # pure-logic unit assertions (VDFParser / RomTitle / PixelConverter / ids)
make selftest   # headless E2E: mock libretro core → dlopen → callbacks → frames → audio → input
make scan-steam # dump the parsed Steam library
make diagnose   # connected controllers + HID inventory
make mock-core  # build the fake libretro core used by --selftest
make watch-hid  # headless HID watch (15s) — PS-capture test for the macOS 27 beta experiment
```

## The two hard rules of this codebase

1. **Steam is a closed client.** We read its library metadata
   (`libraryfolders.vdf` + `appmanifest_*.acf`), launch via `steam://run/<appid>`,
   and hand off the window — we never render Steam games inside our views.
2. **`Sources/CLibretro/` is ABI-critical.** libretro struct layouts and enum
   values match the canonical header exactly; cores are compiled against them.
   Do not "modernize" that directory.

Full architecture, module map, and status: **[AGENTS.md](AGENTS.md)**.

## Sub-agents

Role-specific agent runs (scout → planner → worker) are orchestrated with the
pi SDK:

```
node Scripts/subagents/orchestrate.mjs scout     # Steam VDF recon → docs/scout-steam-report.md
node Scripts/subagents/orchestrate.mjs planner   # libretro Metal plan → docs/plan-libretro-metal.md
node Scripts/subagents/orchestrate.mjs worker    # implement the plan → docs/worker-report.md
```
