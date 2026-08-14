import Foundation

// Custom entry point: intercept headless CLI modes before SwiftUI starts.
// The GUI path falls through to GameDockApp.main().
let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    exit(CLISelfTest.run() ? 0 : 1)
}
if arguments.contains("--scan-steam") {
    exit(CLIScanSteam.run() ? 0 : 1)
}
if arguments.contains("--diagnose-input") {
    exit(CLIDiagnoseInput.run() ? 0 : 1)
}

GameDockApp.main()
