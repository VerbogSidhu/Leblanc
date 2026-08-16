import Foundation

/// Reads per-app playtime from Steam's own `localconfig.vdf`
/// (`~/Library/Application Support/Steam/userdata/<userid>/config/localconfig.vdf`)
/// — the same file Steam's client reads, no network call and no API key.
///
/// Structure (verified against a real install):
///   "UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" {
///       "<appid>" { "LastPlayed" "…"  "Playtime" "<minutes>" }
///   } } } } }
///
/// `Playtime` is stored in **minutes**. When multiple Steam accounts exist on
/// this machine, the largest per-app value wins (the account that actually
/// played it — summing would double-count shared installs).
final class SteamLocalConfigReader {
    static let shared = SteamLocalConfigReader()

    private var cached: [String: Int]?

    /// Playtime in minutes per appid, merged across all local Steam accounts.
    /// Cached for the session; `invalidate()` clears the cache (Settings →
    /// Rescan libraries).
    func playtimeMinutesByAppID() -> [String: Int] {
        if let cached { return cached }
        var merged: [String: Int] = [:]
        for file in localConfigFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let parsed = VDFParser.parse(text) else { continue }
            let map = Self.parsePlaytimeMinutes(from: parsed)
            for (appID, minutes) in map {
                merged[appID] = max(merged[appID] ?? 0, minutes)
            }
        }
        cached = merged
        return merged
    }

    func playtimeMinutes(appID: String) -> Int? {
        playtimeMinutesByAppID()[appID]
    }

    func invalidate() {
        cached = nil
    }

    /// Pure parse (unit-tested): extracts `apps/<appid>/Playtime` (minutes).
    static func parsePlaytimeMinutes(from root: VDFValue) -> [String: Int] {
        guard let apps = root["UserLocalConfigStore"]?["Software"]?["Valve"]?["Steam"]?["apps"]?.dict else {
            return [:]
        }
        var out: [String: Int] = [:]
        for (appID, value) in apps {
            if let raw = value["Playtime"]?.string, let minutes = Int(raw) {
                out[appID] = minutes
            }
        }
        return out
    }

    private func localConfigFiles() -> [URL] {
        let userData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/userdata", isDirectory: true)
        guard let users = try? FileManager.default.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil) else {
            return []
        }
        return users.compactMap { user in
            let file = user.appendingPathComponent("config/localconfig.vdf", isDirectory: false)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }
    }
}
