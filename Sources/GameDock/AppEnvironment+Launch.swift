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

        // Non-blocking launch (2.2): switch to the emulator screen immediately
        // and load the core off the main thread so the boot overlay renders
        // and the UI stays responsive during a slow core load. Load + teardown
        // both run on emulatorLoadQueue so they can never overlap (cores
        // dlopen with RTLD_GLOBAL — see the architecture skill).
        emulator = session
        screen = .emulator
        isLaunchingGame = true
        isEmulatorLoadPending = true
        beginKeepAwake()

        emulatorLoadQueue.async { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try session.load()
            } catch {
                DispatchQueue.main.async {
                    guard self.emulator === session else { return }
                    self.isEmulatorLoadPending = false
                    self.isLaunchingGame = false
                    self.emulator = nil
                    self.screen = .xmb
                    self.endKeepAwake()
                    self.endSessionTracking()
                    self.showError("Failed to start \(entry.title): \(error.localizedDescription)")
                }
                session.teardown() // we're already on the serial load queue
                return
            }
            DispatchQueue.main.async {
                guard self.emulator === session else {
                    // Superseded (user backed out during boot) — exitEmulation
                    // queued the teardown; just clear the pending flag.
                    self.isEmulatorLoadPending = false
                    return
                }
                self.isEmulatorLoadPending = false
                session.start()
                self.waitForFirstFrame(session) // clears the boot overlay
                self.rebuildXMB()
            }
        }
    }

    /// Poll for the first rendered frame and clear the boot overlay then,
    /// so the "Loading core…" screen never flashes over visible gameplay.
    private func waitForFirstFrame(_ session: EmulatorSession) {
        Task {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if session.frameSlot.latestSeq > 0 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            isLaunchingGame = false
        }
    }

    func exitEmulation() {
        isLaunching = false
        isLaunchingGame = false
        coreOptionsVisible = false
        pauseMenuVisible = false
        let session = emulator
        emulator = nil
        endKeepAwake()
        endSessionTracking()
        screen = .xmb
        rebuildXMB()

        guard let session else { return }
        // Serialize teardown with any in-flight load so they never overlap.
        emulatorLoadQueue.async { [weak session] in
            session?.requestStop()
            session?.teardown()
        }
    }

    private func beginKeepAwake() {
        idleActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Emulation running")
    }

    private func endKeepAwake() {
        if let idleActivity { ProcessInfo.processInfo.endActivity(idleActivity) }
        idleActivity = nil
    }
}
