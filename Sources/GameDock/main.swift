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
