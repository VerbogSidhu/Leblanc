import AppKit
import Foundation

/// Launch orchestration for AppEnvironment: Steam handoff, standalone PPSSPP
/// handoff, the embedded libretro path (DS), keep-awake during emulation, and
/// screenshot capture (emulator frame or ScreenCaptureKit).
extension AppEnvironment {
    // MARK: - Launch

    func launch(_ entry: GameEntry) {
        library.recordLaunch(entry)
        lastLaunchedTitle = entry.title
        switch entry.source {
        case .steam:
            guard let appID = entry.appID else { return }
            steam.launch(appID: appID) { [weak self] in self?.restoreAfterSteam() }
        case .psp:
            launchPPSSPP(entry)
        case .ds:
            startEmulator(entry)
        }
    }

    private func launchPPSSPP(_ entry: GameEntry) {
        guard let romPath = entry.romPath else { return }
        let bundlePath = standalone.resolveBundlePath(for: .ppsspp, settings: settings)
        do {
            try standalone.launch(kind: .ppsspp, romPath: romPath, bundlePath: bundlePath) { [weak self] in
                self?.restoreAfterSteam()
            }
        } catch {
            errorMessage = "Couldn't launch PPSSPP: \(error.localizedDescription)\n\nPoint it at your PPSSPPSDL.app in Settings."
            Log.error("launchPPSSPP failed: \(error)")
        }
    }

    private func restoreAfterSteam() {
        AppDelegate.shared?.restoreFrontend()
        rebuildXMB()
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        let title = emulator?.title ?? lastLaunchedTitle
        if screen == .emulator {
            screenshots.captureEmulator(title: title)
        } else {
            if !CGPreflightScreenCaptureAccess() {
                errorMessage = "Leblanc needs Screen Recording permission to capture Steam gameplay. Approve it in System Settings when prompted."
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    if self?.errorMessage == "Leblanc needs Screen Recording permission to capture Steam gameplay. Approve it in System Settings when prompted." {
                        self?.errorMessage = nil
                    }
                }
            }
            Task { await screenshots.captureScreen(title: title) }
        }
    }

    // MARK: - Emulation (embedded libretro path for DS)

    func startEmulator(_ entry: GameEntry) {
        guard let corePath = CoreLocator.resolveCorePath(for: entry.source, settings: settings) else {
            errorMessage = "No \(entry.source.displayName) core found.\nDrop \(entry.source.defaultCoreFileName) into \(AppPaths.coresDir.path), or set one in Settings."
            return
        }
        let consoleID = RAConsole.id(for: entry.source)
        let session = EmulatorSession(corePath: corePath, romPath: entry.romPath, romData: nil, title: entry.title,
                                      inputSnapshot: controllers.snapshot,
                                      raConsoleID: consoleID, raSettings: settings)
        do {
            try session.load()
        } catch {
            errorMessage = "Failed to start \(entry.title): \(error.localizedDescription)"
            return
        }
        emulator = session
        session.start()
        screen = .emulator
        beginKeepAwake()
    }

    func exitEmulation() {
        emulator?.requestStop()
        emulator?.teardown()
        emulator = nil
        endKeepAwake()
        screen = .xmb
        rebuildXMB()
    }

    private func beginKeepAwake() {
        idleActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Emulation running")
    }

    private func endKeepAwake() {
        if let idleActivity { ProcessInfo.processInfo.endActivity(idleActivity) }
        idleActivity = nil
    }
}
