import Foundation

/// Reads API credentials from the repo-root `.env` file (gitignored). Call
/// `Secrets.load()` once at app launch (or lazily on first access); load-once
/// semantics — a second `load()` is a no-op, so values are fixed for the
/// process lifetime. Values are also available via environment variables
/// (take precedence over .env). Only key NAMES are ever logged, never values.
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

    /// Loads from the .env file, with environment variable overrides.
    /// Idempotent: the first call wins; later calls are no-ops (load-once).
    static func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true

        // 1. Parse .env file. CWD-walk covers CLI launches; GUI launches run
        // with CWD=/ so fall back to the bundle directory and the home folder.
        if let (envURL, source) = findEnvFile() {
            parseEnv(at: envURL)
            warnIfWorldReadable(envURL)
            Log.info("Secrets: .env (\(source)) provided keys [\(values.keys.sorted().joined(separator: ", "))]")
        } else {
            Log.info("Secrets: no .env file found")
        }

        // 2. Environment variables override .env values.
        var overridden: [String] = []
        for key in ["STEAM_GRID_DB_KEY", "TWITCH_CLIENT_ID", "TWITCH_CLIENT_SECRET",
                     "SCREENSCRAPER_USERNAME", "SCREENSCRAPER_PASSWORD"] {
            if let val = ProcessInfo.processInfo.environment[key], !val.isEmpty {
                values[key] = val
                overridden.append(key)
            }
        }
        if !overridden.isEmpty {
            Log.info("Secrets: environment overrode keys [\(overridden.joined(separator: ", "))]")
        }
    }

    private static func findEnvFile() -> (url: URL, source: String)? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate.path) { return (candidate, "cwd") }
            let parent = dir.deletingLastPathComponent()
            guard parent.path != dir.path else { break }
            dir = parent
        }
        let fallbacks: [(url: URL, source: String)] = [
            (Bundle.main.bundleURL.deletingLastPathComponent(), "bundle-dir"),
            (FileManager.default.homeDirectoryForCurrentUser, "home"),
        ]
        for candidate in fallbacks {
            let envURL = candidate.url.appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: envURL.path) { return (envURL, candidate.source) }
        }
        return nil
    }

    private static func warnIfWorldReadable(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = attrs[.posixPermissions] as? NSNumber,
              mode.uint32Value & 0o077 != 0 else { return }
        Log.warn("Secrets: .env is group/world-readable — chmod 600 recommended")
    }

    private static func parseEnv(at url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in text.components(separatedBy: .newlines) {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if trimmed.hasPrefix("export ") {
                trimmed = trimmed.dropFirst("export ".count).trimmingCharacters(in: .whitespaces)
            }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            // Strip one pair of symmetric surrounding double quotes.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
    }
}
