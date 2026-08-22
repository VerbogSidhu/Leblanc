import Foundation

/// Fetches high-quality game artwork from SteamGridDB
/// (`steamgriddb.com/api/v2/`). Capsules, logos, heroes, and wide banners
/// for Steam games — community-curated art that looks much better in a
/// console UI than Steam's own header.jpg.
///
/// Auth: Bearer token (the user's API key). Responses are cached locally
/// with a 1-week TTL (same envelope pattern as `SteamScreenshotStore`);
/// empty results are never persisted — they live only as in-memory
/// tombstones so a transient miss can't go stale for a week.
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
    /// Bumped by `invalidate()`; in-flight fetches capture it and discard
    /// their results instead of writing into memory if it moved meanwhile.
    private var generation = 0
    /// Memoized `syncCachedURL` answers (nil = known miss) so per-row lookups
    /// hit the disk at most once per game.
    private var syncMemo: [String: URL?] = [:]

    /// Guards every dictionary above; callers run on arbitrary tasks/queues.
    private let lock = NSLock()

    struct GridArt: Codable {
        let fetchedAt: Date
        let urls: [String]
    }

    /// Grid art URLs (capsules preferred, then heroes) for a Steam appid,
    /// up to `maxArt`. Empty when the key is invalid or the game has no art.
    func gridArtURLs(for appID: String) async -> [URL] {
        guard Secrets.isSteamGridDBConfigured else { return [] }
        lock.lock()
        if let cached = memory[appID] { lock.unlock(); return cached }
        lock.unlock()
        if let envelope = diskCache(for: appID),
           Date().timeIntervalSince(envelope.fetchedAt) < ttl {
            let urls = envelope.urls.compactMap { URL(string: $0) }
            lock.lock()
            memory[appID] = urls
            lock.unlock()
            return urls
        }
        // Join an in-flight fetch, or start one — deduped under the lock.
        lock.lock()
        if let existing = inflight[appID] {
            lock.unlock()
            return await existing.task.value
        }
        let gen = (inflightGeneration[appID] ?? 0) + 1
        inflightGeneration[appID] = gen
        let task = Task<[URL], Never> { [weak self] in
            await self?.fetch(appID) ?? []
        }
        inflight[appID] = (task: task, generation: gen)
        lock.unlock()

        let urls = await task.value
        lock.lock()
        if inflight[appID]?.generation == gen {
            inflight.removeValue(forKey: appID)
            inflightGeneration.removeValue(forKey: appID)
        }
        lock.unlock()
        return urls
    }

    func invalidate() {
        lock.lock()
        generation += 1
        memory.removeAll()
        inflight.removeAll()
        inflightGeneration.removeAll()
        syncMemo.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.cacheDirectory())
    }

    // MARK: - Fetch

    private func fetch(_ appID: String) async -> [URL] {
        lock.lock()
        let gen = generation
        lock.unlock()
        guard let url = URL(string: "https://www.steamgriddb.com/api/v2/grids/steam/\(appID.filter(\.isNumber))") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(Secrets.steamGridDBKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.debug("SteamGridDB: app \(appID) HTTP \(http.statusCode)")
                return []
            }
            let urls = Self.parseGameArt(data: data)
            lock.lock()
            let stale = gen != generation
            lock.unlock()
            guard !stale else { return urls }
            // Never persist empty results — a transient miss must not pin a
            // 7-day TTL; the memory entry below is the short-lived tombstone.
            if !urls.isEmpty {
                saveDiskCache(GridArt(fetchedAt: Date(), urls: urls.map(\.absoluteString)), for: appID)
            }
            lock.lock()
            memory[appID] = urls
            syncMemo.removeValue(forKey: appID) // re-resolve from memory/disk
            lock.unlock()
            return urls
        } catch {
            Log.debug("SteamGridDB: app \(appID) fetch failed — \(error.localizedDescription)")
            return []
        }
    }

    /// Parse the grids-endpoint response:
    /// `{ "status": 200, "data": [{ "url": "...", "style": "capsule" }, ...] }`
    /// — `data` is an array. Legacy single-game dicts
    /// (`{ "data": { "image": …, "logo": …, "hero": … } }`) are still accepted.
    static func parseGameArt(data: Data) -> [URL] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gameData = json["data"] else { return [] }

        var urls: [URL] = []

        // Grids response: `data` is an array of {url, style} entries.
        if let dataArr = gameData as? [[String: Any]] {
            for item in dataArr.prefix(5) {
                if let path = item["url"] as? String, let url = URL(string: path) {
                    urls.append(url)
                }
            }
            return urls
        }

        // Single-game response: image/logo/hero fields.
        if let fields = gameData as? [String: Any] {
            for key in ["image", "logo", "hero"] {
                if let path = fields[key] as? String, let url = URL(string: path) {
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
    /// Memoized (locked) so per-row rendering reads the disk at most once.
    static func syncCachedURL(for appID: String) -> URL? {
        guard Secrets.isSteamGridDBConfigured else { return nil }
        shared.lock.lock()
        if let memoized = shared.syncMemo[appID] {
            shared.lock.unlock()
            return memoized
        }
        // An async fetch may have populated memory since the last disk read.
        if let first = shared.memory[appID]?.first {
            shared.syncMemo[appID] = first
            shared.lock.unlock()
            return first
        }
        shared.lock.unlock()

        let file = cacheDirectory().appendingPathComponent("\(appID).json")
        var result: URL?
        if let data = try? Data(contentsOf: file),
           let envelope = try? JSONDecoder().decode(GridArt.self, from: data),
           Date().timeIntervalSince(envelope.fetchedAt) < 7 * 24 * 3600,
           let first = envelope.urls.first {
            result = URL(string: first)
        }
        shared.lock.lock()
        shared.syncMemo[appID] = result
        shared.lock.unlock()
        return result
    }

    private static func cacheDirectory() -> URL {
        AppPaths.appSupport.appendingPathComponent("preview-cache/steamgriddb", isDirectory: true)
    }

    private static func cacheFile(for appID: String) -> URL {
        cacheDirectory().appendingPathComponent("\(appID).json")
    }
}
