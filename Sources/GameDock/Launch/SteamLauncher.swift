import AppKit
import Foundation

/// Launches Steam games via the `steam://run/<appid>` URL scheme and manages
/// the handoff: hide the frontend, let Steam take over, restore the frontend
/// when Steam quits or the user presses the global hotkey.
///
/// Steam is a closed client — we can never render its games inside our own
/// views. This handoff is the correct boundary (see AGENTS.md).
final class SteamLauncher {
    static let steamURLScheme = "steam"

    /// Hides the frontend and launches the game. `onSteamQuit` is invoked
    /// (on the main thread) when Steam terminates while we are handed off.
    func launch(appID: String, onSteamQuit: @escaping () -> Void) {
        guard let url = URL(string: "steam://run/\(appID)") else {
            Log.error("SteamLauncher: bad steam URL for appid \(appID)")
            return
        }

        Log.info("SteamLauncher: launching \(appID) — hiding frontend")
        AppDelegate.shared?.hideFrontend()
        SteamHandoffMonitor.shared.begin(onSteamQuit: onSteamQuit)

        NSWorkspace.shared.open(url)
    }
}

/// Watches for Steam quitting during a handoff and restores the frontend.
final class SteamHandoffMonitor {
    static let shared = SteamHandoffMonitor()

    private var isHandedOff = false
    private var onSteamQuit: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() {}

    func begin(onSteamQuit: @escaping () -> Void) {
        // Avoid duplicate observation.
        if observers.isEmpty {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.bundleIdentifier == SteamLibrary.steamBundleID {
                    self.handleSteamQuit()
                }
            })
        }
        isHandedOff = true
        self.onSteamQuit = onSteamQuit
        Log.info("SteamHandoffMonitor: handed off to Steam")
    }

    private func handleSteamQuit() {
        guard isHandedOff else { return }
        isHandedOff = false
        Log.info("SteamHandoffMonitor: Steam quit — restoring frontend")
        onSteamQuit?()
        onSteamQuit = nil
    }
}
