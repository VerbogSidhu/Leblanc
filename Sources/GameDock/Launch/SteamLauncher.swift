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
    /// Returns false if the appid/URL is malformed or the steam:// URL goes
    /// unhandled (no Steam) — in the unhandled case the frontend is restored
    /// immediately; callers must not keep keep-awake/session tracking armed.
    @discardableResult
    func launch(appID: String, onSteamQuit: @escaping () -> Void) -> Bool {
        // Validate before interpolating into the steam:// URL (item: digits only).
        guard !appID.isEmpty, appID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            Log.error("SteamLauncher: refusing malformed appid '\(appID)'")
            return false
        }
        guard let url = URL(string: "steam://run/\(appID)") else {
            Log.error("SteamLauncher: bad steam URL for appid \(appID)")
            return false
        }

        Log.info("SteamLauncher: launching \(appID) — hiding frontend")
        AppDelegate.shared?.hideFrontend()
        SteamHandoffMonitor.shared.begin(onSteamQuit: onSteamQuit)

        // open(_:) returns whether the URL was handled. If Steam is missing
        // we must restore immediately instead of hiding the frontend forever,
        // and disarm the handoff monitor so no dead callback lingers.
        if NSWorkspace.shared.open(url) {
            return true
        }
        Log.error("SteamLauncher: steam:// URL not handled (is Steam installed?) — restoring frontend")
        SteamHandoffMonitor.shared.cancel()
        AppDelegate.shared?.restoreFrontend()
        return false
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
        // A handoff is already armed. Overwriting would orphan the first
        // caller's restore path — keep the original, drop the duplicate.
        if isHandedOff {
            Log.warn("SteamHandoffMonitor: begin() while already handed off — ignoring duplicate")
            return
        }
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

    /// Disarms the monitor WITHOUT firing the restore callback (used when a
    /// launch failed after arming — e.g. the steam:// URL went unhandled).
    func cancel() {
        guard isHandedOff else { return }
        isHandedOff = false
        onSteamQuit = nil
        Log.info("SteamHandoffMonitor: cancelled (launch failed)")
    }

    private func handleSteamQuit() {
        guard isHandedOff else { return }
        isHandedOff = false
        Log.info("SteamHandoffMonitor: Steam quit — restoring frontend")
        onSteamQuit?()
        onSteamQuit = nil
    }
}
