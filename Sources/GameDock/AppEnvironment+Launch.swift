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
        beginSessionTracking(entry)
        switch entry.source {
        case .steam:
            guard let appID = entry.appID,
                  steam.launch(appID: appID, onSteamQuit: { [weak self] in self?.restoreAfterSteam() }) else {
                // Dead handoff: no hide, no restore callback will fire — undo
                // the session bookkeeping so playtime/keep-awake don't leak.
                endSessionTracking()
                showError("Couldn't launch \(entry.title) via Steam.")
                return
            }
            showLaunching()
            // Keep the Mac awake during the whole handoff (ProcessInfo
            // beginActivity works even while another app is foreground).
            beginKeepAwake()
        case .psp:
            beginKeepAwake()
            launchPPSSPP(entry)
        case .ds:
            startEmulator(entry) // beginKeepAwake handled inside startEmulator
        }
    }

    private func launchPPSSPP(_ entry: GameEntry) {
        guard let romPath = entry.romPath else {
            endKeepAwake()
            endSessionTracking()
            showError("Couldn't launch \(entry.title): no ROM path.")
            return
        }
        let bundlePath = standalone.resolveBundlePath(for: .ppsspp, settings: settings)
        do {
            try standalone.launch(kind: .ppsspp, romPath: romPath, bundlePath: bundlePath) { [weak self] in
                self?.restoreAfterSteam()
            }
        } catch {
            endKeepAwake()
            endSessionTracking()
            showError("Couldn't launch PPSSPP: \(error.localizedDescription)\n\nPoint it at your PPSSPPSDL.app in Settings.")
            Log.error("launchPPSSPP failed: \(error)")
        }
    }

    private func restoreAfterSteam() {
        isLaunching = false
        AppDelegate.shared?.restoreFrontend()
        endKeepAwake()
        endSessionTracking()
        rebuildXMB()
    }

    /// Marks a handoff launch in progress (drives the "Starting…" overlay).
    /// Steam/PPSSPP hide the window via their launchers; the flag is cleared
    /// on restore. The overlay gives the DS embedded path a brief boot cue
    /// too.
    private func showLaunching() {
        isLaunching = true
    }

    // MARK: - Playtime session tracking

    /// Marks the start of a play session (called at launch). The duration is
    /// recorded when the session ends — restore after a Steam/PPSSPP handoff,
    /// or exitEmulation for the embedded path.
    private func beginSessionTracking(_ entry: GameEntry) {
        sessionStart = Date()
        sessionEntryID = entry.id
    }

    private func endSessionTracking() {
        guard let start = sessionStart, let entryID = sessionEntryID else { return }
        sessionStart = nil
        sessionEntryID = nil
        library.recents.recordPlaytime(entryID: entryID, duration: Date().timeIntervalSince(start))
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        let title = emulator?.title ?? lastLaunchedTitle
        if screen == .emulator {
            screenshots.captureEmulator(title: title)
        } else {
            if !CGPreflightScreenCaptureAccess() {
                showError("Leblanc needs Screen Recording permission to capture Steam gameplay. Approve it in System Settings when prompted.",
                          autoDismissAfter: 6)
            }
            Task { await screenshots.captureScreen(title: title) }
        }
    }

    // MARK: - Emulation (embedded libretro path for DS)

    func startEmulator(_ entry: GameEntry) {
        guard let corePath = CoreLocator.resolveCorePath(for: entry.source, settings: settings) else {
            showError("No \(entry.source.displayName) core found.\nDrop \(entry.source.defaultCoreFileName) into \(AppPaths.coresDir.path), or set one in Settings.")
            return
        }
        let consoleID = RAConsole.id(for: entry.source)
        let session = EmulatorSession(corePath: corePath, romPath: entry.romPath, romData: nil, title: entry.title,
                                      inputSnapshot: controllers.snapshot,
                                      coreOptionsCoreID: entry.source.rawValue,
                                      coreOptionsGameID: entry.id,
                                      raConsoleID: consoleID, raSettings: settings)
        do {
            try session.load()
        } catch {
            showError("Failed to start \(entry.title): \(error.localizedDescription)")
            return
        }
        emulator = session
        session.start()
        screen = .emulator
        beginKeepAwake()
    }

    func exitEmulation() {
        isLaunching = false
        coreOptionsVisible = false
        pauseMenuVisible = false
        emulator?.requestStop()
        emulator?.teardown()
        emulator = nil
        endKeepAwake()
        endSessionTracking()
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
