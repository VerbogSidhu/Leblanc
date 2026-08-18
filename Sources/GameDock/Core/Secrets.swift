import Foundation

/// Reads API credentials from the repo-root `.env` file (gitignored). Call
/// `Secrets.load()` once at app launch (or lazily on first access). Values
/// are also available via environment variables (take precedence over .env).
enum Secrets {
    static var steamGridDBKey: String { values["STEAM_GRID_DB_KEY"] ?? "" }
    static var twitchClientID: String { values["TWITCH_CLIENT_ID"] ?? "" }
    static var twitchClientSecret: String { values["TWITCH_CLIENT_SECRET"] ?? "" }
    static var screenScraperUser: String { values["SCREENSCRAPER_USERNAME"] ?? "" }
    static var screenScraperPass: String { values["SCREENSCRAPER_PASSWORD"] ?? "" }

    static var isSteamGridDBConfigured: Bool { !steamGridDBKey.isEmpty }
    static var isIGDBConfigured: Bool { !twitchClientID.isEmpty && !twitchClientSecret.isEmpty }
    static var isScreenScraperConfigured: Bool { !screenScraperUser.isEmpty }

    private static var values: [String: String] = [:]
    private static let lock = NSLock()
    private static var loaded = false

    /// Loads from the .env file (repo root), with environment variable overrides.
    static func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true

        // 1. Parse .env file (walk up from CWD to find it).
        if let envURL = findEnvFile() {
            parseEnv(at: envURL)
        }

        // 2. Environment variables override .env values.
        for key in ["STEAM_GRID_DB_KEY", "TWITCH_CLIENT_ID", "TWITCH_CLIENT_SECRET",
                     "SCREENSCRAPER_USERNAME", "SCREENSCRAPER_PASSWORD"] {
            if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
                values[key] = val
            }
        }
    }

    private static func findEnvFile() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        return nil
    }

    private static func parseEnv(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
    }
}
