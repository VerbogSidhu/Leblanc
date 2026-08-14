#!/usr/bin/env node
/**
 * GameDock subagent orchestrator — runs role-specific pi agent sessions
 * (scout → planner → worker) against the project, using the user's
 * configured models (see ~/.pi/agent/settings.json).
 *
 * Usage:
 *   node Scripts/subagents/orchestrate.mjs scout      # Steam VDF recon report
 *   node Scripts/subagents/orchestrate.mjs planner    # libretro Metal plan
 *   node Scripts/subagents/orchestrate.mjs worker     # implement the plan
 *
 * Each role writes its deliverable to docs/ and MUST NOT touch source code
 * outside its scope (guardrails in the role prompts below).
 */
import { createAgentSession, SessionManager, ModelRuntime, DefaultResourceLoader, SettingsManager } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js";
import { getModel } from "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/compat.js";
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const PROJECT = "/Users/verbog/GameDock";
const AGENT_DIR = path.join(homedir(), ".pi/agent");

// ---------------------------------------------------------------------------
// Project primer shared by all roles
// ---------------------------------------------------------------------------
const PRIMER = `
You are working inside **GameDock**, a macOS-only (Apple Silicon), controller-first
gaming frontend in /Users/verbog/GameDock. Stack: Swift (SwiftUI shell + AppKit +
Metal), libretro cores embedded via dlopen (RetroArch-style), GameController for
DualSense input. It builds as a SwiftPM package (\`swift build\`; CLI tools via
\`swift run GameDock --<flag>\`). Language mode is Swift 5.

Layout:
  Sources/CLibretro/            C shim target — ABI-critical, DO NOT MODIFY.
    include/libretro.h          trimmed ABI-correct libretro API (structs/enums)
    include/shim.h, shim.c      @convention(c) trampolines; Swift registers
                                callbacks via shim_set_callbacks(); cores resolve
                                retro_set_* via dlsym(RTLD_DEFAULT).
  Sources/GameDock/
    Core/                       Models, Logger (Log.*), AppPaths, PixelConverter,
                                GlobalHotkeyManager
    Libraries/                  VDFParser, SteamLibrary, RomLibrary, RecentsStore,
                                SettingsStore, LibraryStore, CoreLocator
    Controllers/                GamepadInput.swift (GamepadUIAction, InputSnapshot),
                                ControllerManager.swift, GlobalHIDMonitor.swift
    UI/                         Theme.swift, RootView.swift (placeholder home)
    CLI/CLI.swift               --scan-steam / --diagnose-input / --selftest stubs
    AppEnvironment.swift        root ObservableObject (screen, settings, library)
  Tests/MockCore/               mock libretro core (built via \`make mock-core\`)
  docs/                         reports & plans land here
  AGENTS.md                     project brief + architecture + status
`;

// ---------------------------------------------------------------------------
// Role definitions
// ---------------------------------------------------------------------------
const ROLES = {
  scout: {
    label: "SCOUT",
    model: "deepseek-v4-flash",
    tools: ["read", "bash"],
    deliverable: "docs/scout-steam-report.md",
    systemPrompt: () => `${PRIMER}

# Role: RESEARCH SCOUT (read-only)

Task: map out exactly how GameDock's Steam library scanner should read
\`libraryfolders.vdf\` and \`appmanifest_*.acf\`, grounded in the REAL files on
this machine at ~/Library/Application Support/Steam/steamapps/ and the existing
implementation (Sources/GameDock/Libraries/VDFParser.swift,
Sources/GameDock/Libraries/SteamLibrary.swift).

Investigate and report:
1. Exact structure of libraryfolders.vdf (root key, "0".."N" mount entries, the
   "apps" block, "path" values, contentid/label semantics). Note that paths can
   contain backslashes (Windows-style) or be relative — what must the parser
   normalize?
2. Exact structure of appmanifest_*.acf (AppState block): which fields matter for
   a frontend (name, installdir, LastPlayed, SizeOnDisk, StateFlags), which are
   noise, and how installdir maps to the common/ folder.
3. Multiple library folders: how the "apps" block differs from the per-folder
   appmanifest_*.acf files; which is the authoritative source of installed games;
   how to detect duplicate games across folders.
4. Robustness gaps in the current VDFParser.swift + SteamLibrary.swift (quote
   escapes, comments, BOM, tabs, trailing whitespace, missing files, corrupt
   manifests) and concrete fixes.
5. Grid artwork discovery (userdata/<id>/config/grid/<appid>*.png) — verify
   against this machine and report what actually exists.

Constraints: READ-ONLY. Do NOT edit any source file. Do NOT run git commands
that change state (git status/log are fine).

Deliverable: write a thorough markdown report to docs/scout-steam-report.md
(file paths, field tables, edge cases, and a prioritized list of concrete
recommended changes to VDFParser.swift/SteamLibrary.swift). End your final
message with "SCOUT DONE".`,
  },

  planner: {
    label: "PLANNER",
    model: "deepseek-v4-pro",
    tools: ["read", "bash"],
    deliverable: "docs/plan-libretro-metal.md",
    systemPrompt: () => `${PRIMER}

# Role: PLANNING ENGINEER (read-only)

Task: produce a precise, file-by-file implementation plan for GameDock's
**embedded libretro core + Metal render path** (the emulator proof of concept).
This is the hardest subsystem; the plan will be executed by a separate worker.

Read first: AGENTS.md, Sources/CLibretro/include/libretro.h,
Sources/CLibretro/shim.c, Sources/GameDock/Core/PixelConverter.swift,
Sources/GameDock/Controllers/GamepadInput.swift, and docs/scout-steam-report.md
(for context only).

Design and specify (concretely — signatures, struct names, pitfalls):
1. RetroCore: dlopen(RTLD_GLOBAL|RTLD_NOW) + dlsym wrapper. Swift typealiases for
   every core function pointer we need (init/deinit/run/load_game/...). How
   unsafeBitCast is used safely; which symbols are mandatory.
2. Callback registration: how Swift non-capturing @convention(c) global
   functions read EmulatorSession.active; how shim_set_callbacks + shim_install
   are sequenced BEFORE retro_init; load-game data/path handling for
   need_fullpath cores.
3. Environment handler: full command table — which commands MUST return true
   (SET_PIXEL_FORMAT, GET_CAN_DUPE, GET_LOG_INTERFACE, GET_SYSTEM_DIRECTORY,
   GET_SAVE_DIRECTORY, GET_INPUT_BITMASKS, GET_AUDIO_VIDEO_ENABLE,
   GET_INPUT_MAX_USERS, GET_MESSAGE_INTERFACE_VERSION, ...), which must return
   false gracefully (HW_RENDER, VFS, VARIABLE, RUMBLE, MEMORY_MAPS), and the
   exact data layouts for the ones that return data. NOTE: SET_HW_RENDER must
   return false → software-render cores only (melonDS path).
4. Frame path: libretro video callback (data,width,height,pitch) → thread-safe
   latest-frame slot (lock + realloc-on-grow) → PixelConverter to BGRA8 →
   MTLTexture replaceRegion → MTKView draw with aspect-fit letterbox quad. Pixel
   format variants (0RGB1555/XRGB8888/RGB565) and pitch handling. Dupe frames
   (data == nil).
5. Run loop: pacing from retro_system_av_info.timing.fps on a dedicated thread;
   stop semantics (requestStop flag + semaphore join, unload BEFORE deinit,
   dlclose last). Order-of-teardown that won't deadlock with the audio engine.
6. Audio: AVAudioEngine + AVAudioSourceNode pulling from a lock-protected
   Int16 stereo ring buffer fed by retro_audio_sample_batch; underflow silence,
   overflow drop-oldest; sample-rate handling.
7. Mock core (Tests/MockCore/mockcore.c): standalone C file exporting the core
   API; renders a 320x240 RGB565 test pattern with a moving square driven by
   input_state (dpad right/down), emits audio (440 Hz square), queries
   GET_LOG_INTERFACE/GET_SYSTEM_DIRECTORY. Must build with
   \`clang -O2 -fPIC -shared -o build/mockcore.dylib\`.
8. --selftest harness: how EmulatorSession + mock core verify the whole path
   headlessly (assert video frames received, audio frames received, input moves
   the square) and print SELFTEST PASS/FAIL. Note CLI entry: Sources/GameDock/main.swift
   already dispatches --selftest to CLISelfTest.run() in CLI/CLI.swift (currently a stub).
9. EmulatorView: SwiftUI wrapper hosting MTKView via NSViewRepresentable +
   EmulatorMetalView; overlay hints (PS/Share/B hints); how AppEnvironment will
   own the EmulatorSession later (do NOT wire AppEnvironment — out of scope).
10. Ordering of work for the worker, file-by-file, with the exact set of new
    files under Sources/GameDock/Launch/ and which existing files to touch
    (CLI.swift for selftest; Package.swift should NOT need changes).

Constraints: READ-ONLY. Do NOT edit source files. Deliverable: docs/plan-libretro-metal.md,
thorough but actionable. End with "PLANNER DONE".`,
  },

  worker: {
    label: "WORKER",
    model: "deepseek-v4-pro",
    tools: ["read", "bash", "edit", "write"],
    deliverable: "docs/worker-report.md",
    systemPrompt: () => {
      const plan = safeRead("docs/plan-libretro-metal.md");
      return `${PRIMER}

# Role: IMPLEMENTATION WORKER

Your task: implement GameDock's embedded libretro core + Metal render path per
the plan below. The plan was produced by a planning engineer — follow it, but
use your judgment where it is underspecified, and prefer simple correct code
over clever code. THE PLAN:

${plan}

## Hard constraints
- You may create/edit files ONLY under: Sources/GameDock/Launch/,
  Sources/GameDock/UI/EmulatorView.swift (new file), Sources/GameDock/CLI/CLI.swift
  (selftest wiring), Tests/MockCore/mockcore.c, docs/worker-report.md.
- Do NOT modify Sources/CLibretro/** (ABI-critical). Do NOT modify
  Package.swift, AppEnvironment.swift, RootView.swift, or main.swift.
- Do NOT run \`git\` commands. Do NOT commit. Do NOT modify AGENTS.md.
- Thread safety: libretro callbacks arrive on the core thread; SwiftUI on main.
  Use locks; never call retro_* concurrently.

## Definition of done (verify all three)
1. \`swift build\` compiles with zero errors (warnings allowed but fix cheap ones).
2. \`make mock-core\` builds build/mockcore.dylib from Tests/MockCore/mockcore.c.
3. \`GAMEDOCK_CORE_PATH=build/mockcore.dylib swift run GameDock --selftest\`
   prints SELFTEST PASS and exits 0. The selftest must assert: core loaded via
   dlopen (api version + system info sane), N video frames received with sane
   geometry, audio frames received, and input-driven movement (square in the
   mock frame moves when dpad right is held).

## Deliverable
Implement everything, run the three verification commands yourself until they
pass, then write docs/worker-report.md: files created, design decisions,
anything deferred, and the exact verification output. End with "WORKER DONE".`;
    },
  },
};

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------
function safeRead(rel) {
  const p = path.join(PROJECT, rel);
  try {
    return readFileSync(p, "utf8");
  } catch {
    return `(no ${rel} yet — generate it)`;
  }
}

function printEvent(event) {
  switch (event.type) {
    case "agent_start":
    case "turn_start":
    case "session_start":
      console.log(`\n── ${event.type.toUpperCase()} ──`);
      break;
    case "message_update":
      if (event.assistantMessageEvent?.type === "text_delta") {
        process.stdout.write(event.assistantMessageEvent.delta);
      }
      break;
    case "tool_execution_start":
      console.log(`\n▶ tool: ${event.toolName ?? event.name ?? "?"}`);
      break;
    case "tool_execution_update":
      if (event.state === "running" && event.toolName === "bash" && event.command) {
        console.log(`  $ ${String(event.command).slice(0, 140)}`);
      }
      break;
    case "bash_execution_update":
      if (event.state === "completed" || event.state === "failed") {
        const code = event.exitCode ?? "?";
        console.log(`  → bash exit ${code}${code === 0 ? "" : " (FAILED)"}`);
      }
      break;
    default:
      break;
  }
}

const role = process.argv[2];
if (!ROLES[role]) {
  console.error(`Unknown role '${role}'. Use: scout | planner | worker`);
  process.exit(2);
}
const cfg = ROLES[role];

// ---------------------------------------------------------------------------
// Boot the model runtime + session
// ---------------------------------------------------------------------------
const modelRuntime = await ModelRuntime.create({
  authPath: path.join(AGENT_DIR, "auth.json"),
  modelsPath: path.join(AGENT_DIR, "models-store.json"),
});

const model = getModel("opencode-go", cfg.model);
if (!model) {
  console.error(`Model opencode-go/${cfg.model} not found in models store`);
  process.exit(2);
}

const loader = new DefaultResourceLoader({
  cwd: PROJECT,
  agentDir: AGENT_DIR,
  systemPromptOverride: () => cfg.systemPrompt(),
  appendSystemPromptOverride: () => [],
});
await loader.reload();

const { session } = await createAgentSession({
  cwd: PROJECT,
  agentDir: AGENT_DIR,
  model,
  modelRuntime,
  resourceLoader: loader,
  tools: cfg.tools,
  thinkingLevel: "off",
  sessionManager: SessionManager.inMemory(PROJECT),
  settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }),
});

session.subscribe(printEvent);

console.log(`\n========== ${cfg.label} (opencode-go/${cfg.model}) ==========\n`);
const task = {
  scout: "Map the Steam library VDF/ACF reading strategy and write docs/scout-steam-report.md. Investigate the real Steam install at ~/Library/Application Support/Steam, inspect the existing VDFParser.swift and SteamLibrary.swift, and deliver the report as specified in your role instructions.",
  planner: "Produce docs/plan-libretro-metal.md: the file-by-file implementation plan for the embedded libretro core + Metal render path, per your role instructions. Read docs/scout-steam-report.md for context first.",
  worker: "Implement the plan in docs/plan-libretro-metal.md now. Create the emulator module under Sources/GameDock/Launch/, the mock core at Tests/MockCore/mockcore.c, wire CLISelfTest in Sources/GameDock/CLI/CLI.swift, then run the three verification commands until they pass, and write docs/worker-report.md.",
}[role];

try {
  await session.prompt(task);
} finally {
  session.dispose();
}

// ---------------------------------------------------------------------------
// Verify deliverable
// ---------------------------------------------------------------------------
const delivered = path.join(PROJECT, cfg.deliverable);
if (!existsSync(delivered)) {
  console.error(`\n✗ ${cfg.label} finished but deliverable missing: ${cfg.deliverable}`);
  process.exit(1);
}
console.log(`\n✓ ${cfg.label} deliverable written: ${cfg.deliverable}`);
console.log(`========== ${cfg.label} COMPLETE ==========\n`);
process.exit(0);
