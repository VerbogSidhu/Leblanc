import Foundation
import Darwin

// CLI modes may crash in a core we dlopen — keep stdout unbuffered so
// diagnostics survive a segfault.
setvbuf(stdout, nil, _IONBF, 0)

// Custom entry point: intercept headless CLI modes before SwiftUI starts.
// The GUI path falls through to GameDockApp.main().
let arguments = CommandLine.arguments

// Load API credentials from .env (gitignored) before any network calls.
Secrets.load()

// Unknown --flags must not silently boot the GUI.
let knownModes: Set<String> = ["--probe-core", "--selftest", "--scan-steam", "--diagnose-input",
                               "--watch-hid", "--ra-selftest", "--preview-check", "--unit-test"]
let unknownFlags = arguments.dropFirst().filter { $0.hasPrefix("--") && !knownModes.contains($0) }
if !unknownFlags.isEmpty {
    Log.cliPrint("Unknown option(s): \(unknownFlags.joined(separator: ", "))")
    Log.cliPrint("""
        usage: GameDock [--probe-core <core.dylib> <rom> | --selftest | --scan-steam |
                        --diagnose-input | --watch-hid [seconds] | --ra-selftest |
                        --preview-check <appid> [game-title] | --unit-test]
        """)
    exit(2)
}

if arguments.contains("--probe-core") {
    exit(CLIProbeCore.run(args: arguments) ? 0 : 1)
}
if arguments.contains("--selftest") {
    exit(CLISelfTest.run() ? 0 : 1)
}
if arguments.contains("--scan-steam") {
    exit(CLIScanSteam.run() ? 0 : 1)
}
if arguments.contains("--diagnose-input") {
    exit(CLIDiagnoseInput.run() ? 0 : 1)
}
if arguments.contains("--watch-hid") {
    exit(CLIWatchHID.run(arguments: arguments) ? 0 : 1)
}
if arguments.contains("--ra-selftest") {
    exit(CLIRASelfTest.run() ? 0 : 1)
}
if arguments.contains("--preview-check") {
    exit(CLIPreviewCheck.run(args: arguments) ? 0 : 1)
}
if arguments.contains("--unit-test") {
    exit(CLIUnitTest.run() ? 0 : 1)
}

GameDockApp.main()
