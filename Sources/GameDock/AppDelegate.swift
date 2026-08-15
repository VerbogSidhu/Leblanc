import AppKit

/// App lifecycle: fullscreen window setup, activation policy, and the
/// global "return to GameDock" hotkey (Cmd+Shift+Home) used to restore the
/// frontend while Steam (or anything else) has focus.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by SwiftUI's NSApplicationDelegateAdaptor; lets helper objects
    /// (SteamLauncher, DiscordController) reach the frontend window.
    static private(set) weak var shared: AppDelegate?

    private var windowObserver: NSObjectProtocol?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // GlobalHIDMonitor reads input via IOHIDManager, which macOS can gate
        // behind the Input Monitoring permission. Request it once at launch
        // (macOS 15+ has a proper API); without it the capture simply stays
        // silent and the Cmd+Shift+Home hotkey still works.
        if #available(macOS 15.0, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }

        // Make the window fullscreen reliably: retry until it exists and the
        // toggle lands (the window can appear late on slow launches).
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.makeFrontendFullscreen()
        }
        retryFullscreen()

        // Cmd+Shift+Home → restore frontend from anywhere (Steam has focus, etc.)
        GlobalHotkeyManager.shared.start { [weak self] in
            DispatchQueue.main.async {
                self?.restoreFrontend()
            }
        }
    }

    /// Retries fullscreen until the window exists and the toggle succeeds.
    /// Skipped when GAMEDOCK_WINDOWED=1 (debug: test windowed layouts).
    private var fullscreenRequested = false

    private func retryFullscreen(attempt: Int = 0) {
        if ProcessInfo.processInfo.environment["GAMEDOCK_WINDOWED"] == "1" { return }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.retryFullscreen(attempt: attempt + 1) }
            }
            return
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        if window.styleMask.contains(.fullScreen) {
            return // done
        }
        if !fullscreenRequested {
            fullscreenRequested = true
            window.toggleFullScreen(nil)
        }
        if attempt >= 40 {
            // Fullscreen genuinely failed — fill the screen windowed instead.
            Log.warn("AppDelegate: fullscreen failed — falling back to windowed fill")
            if let screen = NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.retryFullscreen(attempt: attempt + 1)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Frontend window management

    func makeFrontendFullscreen() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 1100, height: 700)
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
    }

    /// Bring GameDock back to the front (fullscreen) from anywhere — both the
    /// automatic restore path (launched game quit) and the manual path
    /// (Cmd+Shift+Home / PS while the game still runs) funnel through here.
    func restoreFrontend() {
        NSApp.unhide(nil)
        NSApp.activate()
        makeFrontendFullscreen()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Hide the frontend without quitting (Steam/PPSSPP handoff).
    ///
    /// Two-part fix for "Leblanc disappears when a game launches":
    ///   1. Never orderOut a fullscreen window: ordering a window out while it
    ///      occupies its own fullscreen Space can close it on current macOS,
    ///      and applicationShouldTerminateAfterLastWindowClosed then kills the
    ///      whole process. Exit fullscreen first so the window returns to the
    ///      normal Space.
    ///   2. Use NSApp.hide (app-level) instead of orderOut — the process stays
    ///      alive and hidden, and restoreFrontend() unhides + re-enters
    ///      fullscreen reliably.
    func hideFrontend() {
        exitFullscreenIfNeeded()
        NSApp.hide(nil)
    }

    private func exitFullscreenIfNeeded() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }),
              window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
}
