import Foundation

/// Fetches high-quality game artwork from SteamGridDB
/// (`steamgriddb.com/api/v2/`). Capsules, logos, heroes, and wide banners
/// for Steam games — community-curated art that looks much better in a
/// console UI than Steam's own header.jpg.
///
/// Auth: Bearer token (the user's API key). Responses are cached locally
/// with a 1-week TTL (same envelope pattern as `SteamScreenshotStore`).
final class SteamGridDBStore {
    static let shared = SteamGridDBStore()

    private let ttl: TimeInterval = 7 * 24 * 3600
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private var memory: [String: [URL]] = [:]
    private var inflight: [String: (task: Task<[URL], Never>, generation: Int)] = [:]
    private var inflightGeneration: [String: Int] = [:]

    struct GridArt: Codable {
        let fetchedAt: Date
        let urls: [String]
    }

    /// Grid art URLs (capsules preferred, then heroes) for a Steam appid,
    /// up to `maxArt`. Empty when the key is invalid or the game has no art.
    func gridArtURLs(for appID: String) async -> [URL] {
        guard Secrets.isSteamGridDBConfigured else { return [] }
        if let cached = memory[appID] { return cached }
        if let envelope = diskCache(for: appID),
           Date().timeIntervalSince(envelope.fetchedAt) < ttl {
            let urls = envelope.urls.compactMap { URL(string: $0) }
            memory[appID] = urls
            return urls
        }
        let gen = (inflightGeneration[appID] ?? 0) + 1
        inflightGeneration[appID] = gen
        if let existing = inflight[appID] { return await existing.task.value }

        let task = Task<[URL], Never> { [weak self] in
            await self?.fetch(appID) ?? []
        }
        inflight[appID] = (task: task, generation: gen)
        let urls = await task.value
        if inflight[appID]?.generation == gen {
            inflight.removeValue(forKey: appID)
            inflightGeneration.removeValue(forKey: appID)
        }
        return urls
    }

    func invalidate() {
        memory.removeAll()
        inflight.removeAll()
        inflightGeneration.removeAll()
        try? FileManager.default.removeItem(at: Self.cacheDirectory())
    }

    // MARK: - Fetch

    private func fetch(_ appID: String) async -> [URL] {
        guard let url = URL(string: "https://www.steamgriddb.com/api/v2/games/steam/\(appID.filter(\.isNumber))") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Secrets.steamGridDBKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.debug("SteamGridDB: app \(appID) HTTP \(http.statusCode)")
                return []
            }
            let urls = Self.parseGameArt(data: data)
            saveDiskCache(GridArt(fetchedAt: Date(), urls: urls.map(\.absoluteString)), for: appID)
            memory[appID] = urls
            return urls
        } catch {
            Log.debug("SteamGridDB: app \(appID) fetch failed — \(error.localizedDescription)")
            return []
        }
    }

    /// Parse the game response: `{ "data": { "image": "...", "logo": "...", "hero": "..." } }`
    /// or grid list: `{ "data": [{ "url": "...", "style": "capsule" }, ...] }`.
    static func parseGameArt(data: Data) -> [URL] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gameData = json["data"] as? [String: Any] else { return [] }

        var urls: [URL] = []

        // Single-game response: image/logo/hero fields.
        for key in ["image", "logo", "hero"] {
            if let path = gameData[key] as? String, let url = URL(string: path) {
                urls.append(url)
            }
        }

        // If no direct fields, try the grids endpoint response (array).
        if urls.isEmpty, let dataArr = json["data"] as? [[String: Any]] {
            for item in dataArr.prefix(5) {
                if let path = item["url"] as? String, let url = URL(string: path) {
                    urls.append(url)
                }
            }
        }

        return urls
    }

    // MARK: - Disk cache

    private func diskCache(for appID: String) -> GridArt? {
        guard let data = try? Data(contentsOf: Self.cacheFile(for: appID)),
              let envelope = try? JSONDecoder().decode(GridArt.self, from: data) else { return nil }
        return envelope
    }

    private func saveDiskCache(_ envelope: GridArt, for appID: String) {
        try? FileManager.default.createDirectory(at: Self.cacheDirectory(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: Self.cacheFile(for: appID), options: .atomic)
        }
    }

    /// Synchronous disk-cache hit for ArtworkLoader's fast path (no async).
    /// Returns the first cached GridDB URL if present and not expired.
    static func syncCachedURL(for appID: String) -> URL? {
        guard Secrets.isSteamGridDBConfigured else { return nil }
        let file = cacheDirectory().appendingPathComponent("\(appID).json")
        guard let data = try? Data(contentsOf: file),
              let envelope = try? JSONDecoder().decode(GridArt.self, from: data),
              Date().timeIntervalSince(envelope.fetchedAt) < 7 * 24 * 3600,
              let first = envelope.urls.first,
              let url = URL(string: first) else { return nil }
        return url
    }

    private static func cacheDirectory() -> URL {
        AppPaths.appSupport.appendingPathComponent("preview-cache/steamgriddb", isDirectory: true)
    }

    private static func cacheFile(for appID: String) -> URL {
        cacheDirectory().appendingPathComponent("\(appID).json")
    }
}
