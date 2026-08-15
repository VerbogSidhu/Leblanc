---
name: leblanc-build-verify
description: Build, test, and verify the Leblanc (GameDock) macOS game launcher before editing code, after changes, and before every commit. Covers Makefile targets, CLI self-test tools, and the environment variables the app honors.
---

# Leblanc — Build & Verify

SwiftPM package (macOS 14+, arm64, Swift 5 mode). **No Xcode required** — this
machine builds with Command Line Tools only, which means **XCTest and
swift-testing do NOT exist here**; unit coverage runs via a CLI harness.

## Build

```bash
cd /Users/verbog/GameDock
make build        # swift build (debug)
make app          # assemble build/Leblanc.app (ad-hoc signed) from .build/debug
make run          # build + open the app
```

`make app` depends on `make build`; it copies the binary, `Info.plist`, and the
SPM resource bundle, then ad-hoc codesigns. Result: `build/Leblanc.app`.

## Verify — run ALL of these before committing

```bash
make test         # pure-logic assertions: VDFParser / RomTitle / PixelConverter / entry ids
make mock-core    # compile Tests/MockCore/mockcore.c → build/mockcore.dylib
GAMEDOCK_CORE_PATH=build/mockcore.dylib swift run Leblanc --selftest   # or: make selftest
```

- `--selftest`: headless E2E — dlopen mock core → callbacks → frames → audio →
  input. Prints `SELFTEST PASS/FAIL`, exits 0/1.
- `--unit-test`: CLI assertion battery (`make test`). Prints `UNIT TESTS PASS/FAIL`.
- Build must be warning-free: `swift build 2>&1 | grep -i warning` → empty.

## CLI tools (run with `swift run Leblanc --<flag>`)

| Flag | Purpose |
|---|---|
| `--selftest` | mock-core E2E emulator round-trip |
| `--unit-test` | pure-logic assertions |
| `--scan-steam` | dump parsed Steam library (validates VDF/ACF parsing) |
| `--diagnose-input` | connected GameController devices + button inventory + raw HID dump |
| `--probe-core <core.dylib> <rom>` | load an arbitrary libretro core + ROM headlessly, report frames/audio + write `/tmp/ppsspp_frame.png` |
| `--ra-selftest` | RetroAchievements rcheevos round-trip |

## Environment variables the app honors

- `GAMEDOCK_CORE_PATH` — core path for `--selftest` (default `build/mockcore.dylib`).
- `GAMEDOCK_WINDOWED=1` — skip forced fullscreen (debug windowed layouts).

## Golden rules

- Never commit a broken build (`make build` must pass first).
- `Sources/CLibretro/` is ABI-critical — see `leblanc-architecture` before touching.
- If the self-test fails after an emulator change, `--probe-core` with a real
  core + ROM isolates frontend vs core problems; a frame PNG lands at
  `/tmp/ppsspp_frame.png`.
