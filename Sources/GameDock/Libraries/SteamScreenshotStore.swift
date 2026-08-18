import Foundation

/// Fetches Steam storefront screenshot URLs for the selection preview panel.
///
/// Uses the public, keyless storefront endpoint
/// `https://store.steampowered.com/api/appdetails?appids=<appid>`, whose
/// response carries `data.screenshots[].path_full` / `.path_thumbnail`.
/// Results are cached locally (JSON keyed by appid, RACache-style envelope) so
/// a selection re-visit never refetches — only a manual library rescan
/// (`invalidate()`) or a week of age forces a new fetch.
final class SteamScreenshotStore {
    static let shared = SteamScreenshotStore()

    /// Freshness window for the disk cache (~1 week).
    private let ttl: TimeInterval = 7 * 24 * 3600
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Memory cache + in-flight dedupe (rapid scroll back and forth must not
    /// issue duplicate fetches for the same appid). All access on the caller's
    /// queue; the store is only used from the preview model's task.
    private var memory: [String: [URL]] = [:]
    private var inflight: [String: (task: Task<[URL], Never>, generation: Int)] = [:]
    private var inflightGeneration: [String: Int] = [:]

    struct CacheEnvelope: Codable {
        let fetchedAt: Date
        let urls: [String]
    }

    /// Screenshot URLs (full-res) for an app, newest first, max 5.
    func screenshotURLs(for appID: String) async -> [URL] {
        if let cached = memory[appID] { return cached }
        if let envelope = diskCache(for: appID),
           Date().timeIntervalSince(envelope.fetchedAt) < ttl {
            let urls = envelope.urls.compactMap { URL(string: $0) }
            memory[appID] = urls
            return urls
        }
        // Bump generation so stale in-flight tasks are discarded.
        let gen = (inflightGeneration[appID] ?? 0) + 1
        inflightGeneration[appID] = gen
        if let existing = inflight[appID] {
            return await existing.task.value
        }

        let task = Task<[URL], Never> { [weak self] in
            await self?.fetch(appID) ?? []
        }
        inflight[appID] = (task: task, generation: gen)
        let urls = await task.value
        // Only clear if this is still the latest in-flight for this appID.
        if inflight[appID]?.generation == gen {
            inflight.removeValue(forKey: appID)
            inflightGeneration.removeValue(forKey: appID)
        }
        return urls
    }

    /// Drops memory + disk caches (Settings → Rescan libraries).
    func invalidate() {
        memory.removeAll()
        inflight.removeAll()
        inflightGeneration.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory())
    }

    // MARK: - Fetch

    private func fetch(_ appID: String) async -> [URL] {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID.filter(\.isNumber))") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.debug("SteamScreenshotStore: app \(appID) HTTP \(http.statusCode)")
                return []
            }
            let urls = Self.parseScreenshotURLs(data: data, appID: appID)
            saveDiskCache(CacheEnvelope(fetchedAt: Date(), urls: urls.map(\.absoluteString)), for: appID)
            memory[appID] = urls
            return urls
        } catch {
            Log.debug("SteamScreenshotStore: app \(appID) fetch failed — \(error.localizedDescription)")
            return []
        }
    }

    /// Pure parse (unit-tested): `{ "<appid>": { "success": true, "data":
    /// { "screenshots": [ { "path_full": … } ] } } }` → screenshot URLs.
    static func parseScreenshotURLs(data: Data, appID: String) -> [URL] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json[appID] as? [String: Any],
              let success = app["success"] as? Bool, success,
              let info = app["data"] as? [String: Any],
              let screenshots = info["screenshots"] as? [[String: Any]] else { return [] }
        var urls: [URL] = []
        for shot in screenshots {
            if let path = shot["path_full"] as? String, let url = URL(string: path) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Disk cache

    private func diskCache(for appID: String) -> CacheEnvelope? {
        guard let data = try? Data(contentsOf: Self.cacheFile(for: appID)),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data) else { return nil }
        return envelope
    }

    private func saveDiskCache(_ envelope: CacheEnvelope, for appID: String) {
        try? FileManager.default.createDirectory(at: Self.cacheDirectory(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: Self.cacheFile(for: appID), options: .atomic)
        }
    }

    private static func cacheDirectory() -> URL {
        AppPaths.appSupport.appendingPathComponent("preview-cache/steam-screenshots", isDirectory: true)
    }

    private static func cacheFile(for appID: String) -> URL {
        cacheDirectory().appendingPathComponent("\(appID).json")
    }
}
