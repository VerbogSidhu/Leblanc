import AppKit
import Foundation

/// Launches the user's own standalone emulator apps (PPSSPPSDL.app) with a
/// ROM, hiding the frontend during play (Steam-style handoff). This is the
/// PSP path per project direction: use the user's PPSSPP install, not
/// RetroArch's libretro core (whose macOS GL path is broken).
///
/// The frontend restores when the emulator process exits or when the user
/// presses the global hotkey / PS button.
final class StandaloneEmulatorLauncher {
    /// Known standalone emulators and their executable layout.
    enum AppKind {
        case ppsspp

        var displayName: String { "PPSSPP" }

        /// Settings key for the user's override path.
        var settingsKey: String { "ppsspp" }

        /// Default install location under ~/Downloads/ROMS.
        var defaultBundlePath: String {
            switch self {
            case .ppsspp:
                return (NSHomeDirectory() as NSString)
                    .appendingPathComponent("Downloads/ROMS/PPSSPPSDL.app")
            }
        }

        var executableRelativePath: String {
            switch self {
            case .ppsspp: return "Contents/MacOS/PPSSPPSDL"
            }
        }

        /// Extra command-line arguments when launching a ROM.
        var launchArguments: [String] {
            switch self {
            case .ppsspp: return ["--fullscreen"]
            }
        }
    }

    /// Guarded by `lock`: the termination handler fires on the main queue
    /// while stop() may be called from anywhere — all access is locked.
    private let lock = NSLock()
    private(set) var running: Bool = false
    private var process: Process?
    /// Grace period before escalating SIGTERM → SIGKILL (some emulators
    /// ignore SIGTERM and would hang the handoff forever).
    private static let killGraceSeconds: TimeInterval = 3.0

    private func currentProcess() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return process
    }

    /// Resolves the app bundle for a kind: settings override, then default.
    func resolveBundlePath(for kind: AppKind, settings: SettingsStore) -> String {
        if let override = settings.standaloneAppPath(for: kind.settingsKey), !override.isEmpty {
            return override
        }
        return kind.defaultBundlePath
    }

    /// Launches the emulator with the ROM. `onExit` fires on the main thread
    /// when the emulator quits.
    func launch(kind: AppKind, romPath: String, bundlePath: String, onExit: @escaping () -> Void) throws {
        lock.lock()
        let alreadyRunning = running
        lock.unlock()
        guard !alreadyRunning else {
            throw LauncherError.alreadyRunning
        }

        let bundle = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let binary = bundle.appendingPathComponent(kind.executableRelativePath).path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw LauncherError.executableNotFound(bundlePath)
        }
        guard FileManager.default.fileExists(atPath: romPath) else {
            throw LauncherError.romNotFound(romPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [romPath] + kind.launchArguments
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock()
                if self.process === proc {
                    self.process = nil
                    self.running = false
                }
                self.lock.unlock()
                onExit()
            }
        }
        // Launch the binary directly (the SDL app activates itself). Do NOT
        // NSWorkspace.open the bundle — that would spawn a second instance.
        try p.run()
        lock.lock()
        process = p
        running = true
        lock.unlock()

        AppDelegate.shared?.hideFrontend()
        Log.info("StandaloneEmulatorLauncher: launched \(kind.displayName) with \(romPath)")
    }

    /// Quits the running emulator (termination handler restores the frontend).
    /// SIGTERM first; if the process ignores it past the grace period we
    /// escalate to SIGKILL so the handoff can't hang forever.
    func stop() {
        let p = currentProcess()
        guard let p, p.isRunning else { return }
        p.terminate()
        Log.info("StandaloneEmulatorLauncher: SIGTERM sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGraceSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillOurs = (self.process === p)
            self.lock.unlock()
            guard stillOurs, p.isRunning else { return }
            Log.warn("StandaloneEmulatorLauncher: still running after \(Self.killGraceSeconds)s — sending SIGKILL")
            if p.processIdentifier > 0 {
                kill(p.processIdentifier, SIGKILL)
            }
        }
    }

    enum LauncherError: LocalizedError {
        case alreadyRunning
        case executableNotFound(String)
        case romNotFound(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "The emulator is already running."
            case .executableNotFound(let path): return "Emulator not found at \(path). Set its path in Settings."
            case .romNotFound(let path): return "ROM not found: \(path)"
            }
        }
    }
}
