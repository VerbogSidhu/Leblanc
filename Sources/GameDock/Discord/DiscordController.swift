import AppKit
import ApplicationServices
import Foundation

/// Surfaces the real Discord.app in a small floating window over the frontend
/// (Share button), and dismisses it (Share again / quick bar). We never build
/// a custom chat UI — just drive the real app's window via Accessibility.
///
/// AX window resizing requires the Accessibility permission
/// (AXIsProcessTrusted). Without it we degrade gracefully: launch + activate
/// Discord at its normal size and log a hint.
final class DiscordController {
    static let bundleID = "com.hnc.Discord"
    static let floatingSize = CGSize(width: 560, height: 720)

    private(set) var isFloating = false
    private var axRetries = 0

    /// Share button / quick bar action.
    func toggle() {
        isFloating ? hide() : show()
    }

    // MARK: - Show

    func show() {
        Log.info("DiscordController: showing Discord")
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DiscordController.bundleID) else {
            Log.error("DiscordController: Discord.app not found")
            return
        }
        NSWorkspace.shared.open(appURL)

        // Wait for Discord to be running, then resize its window via AX.
        axRetries = 0
        pollForRunningApp { [weak self] app in
            self?.resizeFloating(app)
        }
    }

    private func pollForRunningApp(completion: @escaping (NSRunningApplication) -> Void) {
        let check: (Int) -> Void = { [weak self] attempt in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: DiscordController.bundleID)
            if let app = apps.first(where: { !$0.isTerminated }) {
                completion(app)
            } else if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.pollForRunningApp(completion: completion)
                }
            } else {
                Log.warn("DiscordController: Discord did not become running")
            }
        }
        check(0)
    }

    private func resizeFloating(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted() else {
            Log.warn("DiscordController: Accessibility permission missing — cannot float window; launching Discord normally")
            app.activate()
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement], let window = windows.first else {
            // Window may not exist yet — retry briefly.
            if axRetries < 10 {
                axRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.resizeFloating(app)
                }
            }
            return
        }

        guard let screen = NSScreen.main else { return }
        let size = DiscordController.floatingSize

        // Position: top-right corner with margin. AX uses a top-left origin.
        let visible = screen.visibleFrame
        let axX = visible.maxX - size.width - 24
        let axY = visible.maxY - size.height - 24

        var sizeValue = CGSize(width: size.width, height: size.height)
        var posValue = CGPoint(x: axX, y: axY)

        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &sizeValue)!)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &posValue)!)

        app.activate()
        isFloating = true
        Log.info("DiscordController: floating at \(Int(axX)),\(Int(axY)) \(Int(size.width))x\(Int(size.height))")
    }

    // MARK: - Hide

    func hide() {
        Log.info("DiscordController: hiding Discord")
        // Minimize Discord's window if we can; always bring the frontend back.
        if AXIsProcessTrusted(),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: DiscordController.bundleID).first {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement], let window = windows.first {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
        isFloating = false
        AppDelegate.shared?.restoreFrontend()
    }
}
