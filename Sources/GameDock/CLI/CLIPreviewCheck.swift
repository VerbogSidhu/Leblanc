import Foundation

/// Headless check for the selection-preview data plumbing:
///   GameDock --preview-check <appid> [game-title-for-captures]
///
/// Prints, for one Steam appid:
///   1. Playtime minutes read from Steam's localconfig.vdf (no network).
///   2. Real screenshot URLs from the storefront endpoint (network + disk
///      cache — run twice to prove the cache path).
/// And, when a title is passed, personal captures for it from
/// ~/Pictures/Leblanc Captures/.
enum CLIPreviewCheck {
    static func run(args: [String]) -> Bool {
        guard args.count >= 3 else {
            Log.cliPrint("usage: GameDock --preview-check <appid> [game-title]")
            return false
        }
        let appID = args[2]

        let reader = SteamLocalConfigReader()
        if let minutes = reader.playtimeMinutes(appID: appID) {
            Log.cliPrint("localconfig playtime: \(PlaytimeFormatter.minutes(minutes)) (\(minutes) min)")
        } else {
            Log.cliPrint("localconfig playtime: none for app \(appID)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var urls: [URL] = []
        Task {
            urls = await SteamScreenshotStore.shared.screenshotURLs(for: appID)
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: .now() + 30) == .timedOut
        Log.cliPrint("screenshots (\(urls.count)):")
        for url in urls.prefix(5) { Log.cliPrint("  \(url.absoluteString)") }

        if args.count >= 4 {
            let title = args[3]
            let captures = CaptureStore.shared.captures(for: title)
            Log.cliPrint("captures for '\(title)' (\(captures.count)):")
            for c in captures { Log.cliPrint("  \(c.lastPathComponent)") }
        }

        if timedOut {
            Log.cliPrint("PREVIEW-CHECK FAIL: screenshot fetch timed out after 30s")
            return false
        }
        guard !urls.isEmpty else {
            Log.cliPrint("PREVIEW-CHECK FAIL: no screenshots fetched for app \(appID)")
            return false
        }
        Log.cliPrint("PREVIEW-CHECK PASS")
        return true
    }
}
