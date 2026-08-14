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
    private func retryFullscreen(attempt: Int = 0) {
        guard attempt < 40 else {
            Log.warn("AppDelegate: could not enter fullscreen")
            return
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.retryFullscreen(attempt: attempt + 1)
            }
            return
        }
        window.collectionBehavior.insert(.fullScreenPrimary)
        if window.styleMask.contains(.fullScreen) {
            return
        }
        // Windowed fallback: fill the screen even before the toggle lands.
        if let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
        }
        window.toggleFullScreen(nil)
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

    /// Bring GameDock back to the front (fullscreen) from anywhere.
    func restoreFrontend() {
        NSApp.activate()
        makeFrontendFullscreen()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Hide the frontend window without quitting (used for Steam handoff).
    func hideFrontend() {
        NSApp.windows.first(where: { $0.canBecomeMain })?.orderOut(nil)
    }
}
