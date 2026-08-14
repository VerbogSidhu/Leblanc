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

        // Make the window fullscreen once it appears (SwiftUI creates it after launch).
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.makeFrontendFullscreen()
        }

        // Belt-and-suspenders retry in case the key-window notification fired early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.makeFrontendFullscreen()
        }

        // Cmd+Shift+Home → restore frontend from anywhere (Steam has focus, etc.)
        GlobalHotkeyManager.shared.start { [weak self] in
            DispatchQueue.main.async {
                self?.restoreFrontend()
            }
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
