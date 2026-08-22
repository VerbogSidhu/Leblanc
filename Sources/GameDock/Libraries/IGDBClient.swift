import Foundation

/// Game metadata from IGDB (via Twitch's API). Provides genre, release year,
/// developer, publisher, and summary for any game — Steam or ROM-based.
///
/// Auth flow: Twitch OAuth client-credentials grant → access token → IGDB
/// queries. The token is cached in memory with its expiry; refreshed
/// automatically when expired. No user interaction required.
final class IGDBClient {
    static let shared = IGDBClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Token management

    private nonisolated(unsafe) var accessToken: String?
    private nonisolated(unsafe) var tokenExpiry: Date?
    /// True while a refresh request is on the wire — concurrent callers wait
    /// for it instead of stampeding the token endpoint (single-flight).
    private nonisolated(unsafe) var tokenRefreshInFlight = false
    private let tokenLock = NSLock()

    /// Ensures a valid Twitch access token exists. Returns nil only if
    /// credentials are missing or the token endpoint fails. Single-flight:
    /// N concurrent callers share one refresh.
    private func ensureToken() async -> String? {
        tokenLock.lock()
        if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
            tokenLock.unlock()
            return token
        }
        if tokenRefreshInFlight {
            tokenLock.unlock()
            return await awaitInFlightRefresh()
        }
        tokenRefreshInFlight = true
        tokenLock.unlock()
        defer {
            tokenLock.lock()
            tokenRefreshInFlight = false
            tokenLock.unlock()
        }
        return await refreshToken()
    }

    /// Waits out a refresh started by another caller. Returns the fresh token,
    /// or nil if that refresh finished without producing one.
    private func awaitInFlightRefresh() async -> String? {
        while true {
            try? await Task.sleep(nanoseconds: 40_000_000)
            tokenLock.lock()
            var fresh: String?
            if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
                fresh = token
            }
            let stillRefreshing = tokenRefreshInFlight
            tokenLock.unlock()
            if let fresh { return fresh }
            if !stillRefreshing { return nil }
        }
    }

    /// Performs the client-credentials grant against Twitch and caches the
    /// resulting token. Only called while `tokenRefreshInFlight` is set.
    private func refreshToken() async -> String? {
        guard Secrets.isIGDBConfigured else { return nil }
        guard let url = URL(string: "https://id.twitch.tv/oauth2/token") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Credentials travel in the form body — never the URL query, where
        // they would leak into logs and proxies.
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.twitchClientID),
            URLQueryItem(name: "client_secret", value: Secrets.twitchClientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.warn("IGDB: Twitch token request failed HTTP \(http.statusCode)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? TimeInterval else {
                Log.warn("IGDB: bad token response")
                return nil
            }
            tokenLock.lock()
            accessToken = token
            tokenExpiry = Date().addingTimeInterval(expiresIn - 60) // refresh 1 min early
            tokenLock.unlock()
            Log.info("IGDB: Twitch token acquired, expires in \(Int(expiresIn))s")
            return token
        } catch {
            Log.warn("IGDB: token request failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Drops the cached token so the next `ensureToken()` refreshes (used when
    /// IGDB rejects a token with 401).
    private func invalidateToken() {
        tokenLock.lock()
        accessToken = nil
        tokenExpiry = nil
        tokenLock.unlock()
    }

    // MARK: - Game metadata

    struct GameMetadata: Codable {
        var genre: String?
        var releaseYear: Int?
        var developer: String?
        var summary: String?
    }

    private static let cacheDir: URL = {
        let base = AppPaths.appSupport.appendingPathComponent("preview-cache/igdb", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    struct CacheEnvelope: Codable {
        let fetchedAt: Date
        let meta: GameMetadata?
    }

    private static let cacheTTL: TimeInterval = 7 * 24 * 3600 // 1 week

    /// One-shot background sweep deleting cache files older than 14 days
    /// (2× TTL): expired entries stop being read anyway, so this only bounds
    /// disk growth. Runs once, on the first metadata query.
    private static let pruneOldFilesOnce: Void = {
        DispatchQueue.global(qos: .utility).async {
            let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            let fm = FileManager.default
            guard let files = fm.enumerator(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for case let url as URL in files {
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if date ?? .distantFuture < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }()

    /// Distinguishes a definitive answer (cacheable — including "no match")
    /// from transient failures (auth/rate-limit/network — never cached).
    private enum QueryResult {
        case found(GameMetadata)
        /// HTTP 200 with an empty result list — IGDB definitively has no match.
        case empty
        /// 401 — the cached token was rejected; refresh once and retry.
        case unauthorized
        /// 429 rate-limit, other HTTP errors, and network failures.
        case transientFailure
    }

    /// Fetches metadata for a game by Steam app ID or ROM title.
    /// Returns nil if IGDB has no match or credentials are missing.
    func metadata(for steamAppID: String?) async -> GameMetadata? {
        guard let appID = steamAppID else { return nil }
        _ = Self.pruneOldFilesOnce
        let cacheKey = "steam-\(appID)"
        if let envelope = readCache(cacheKey) { return envelope.meta }
        let result = await queryWithAuthRetry(whereClause: "external_games.uid = \"steam_\(appID)\"")
        return finish(result, cacheKey: cacheKey)
    }

    func metadata(forTitle title: String) async -> GameMetadata? {
        // Deterministic FNV-1a digest — `Hasher` is randomly seeded per
        // process, so `.hash` keys would never match across launches.
        _ = Self.pruneOldFilesOnce
        let cacheKey = "title-\(Self.fnv1aHex(title.lowercased()))"
        if let envelope = readCache(cacheKey) { return envelope.meta }
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        let result = await queryWithAuthRetry(whereClause: "name ~ *\"\(escaped)\"*")
        return finish(result, cacheKey: cacheKey)
    }

    /// Persists definitive outcomes only; transient failures stay uncached so
    /// the next selection retries instead of reading a poisoned tombstone.
    private func finish(_ result: QueryResult, cacheKey: String) -> GameMetadata? {
        switch result {
        case .found(let meta):
            writeCache(meta, key: cacheKey)
            return meta
        case .empty:
            writeCache(nil, key: cacheKey)
            return nil
        case .unauthorized, .transientFailure:
            return nil
        }
    }

    /// Runs the query once; on 401 forces exactly one token refresh + retry.
    private func queryWithAuthRetry(whereClause: String) async -> QueryResult {
        guard let token = await ensureToken() else { return .transientFailure }
        var result = await queryIGDB(token: token, whereClause: whereClause)
        if case .unauthorized = result {
            Log.info("IGDB: token rejected — refreshing once")
            invalidateToken()
            guard let fresh = await ensureToken() else { return .transientFailure }
            result = await queryIGDB(token: fresh, whereClause: whereClause)
        }
        return result
    }

    /// Deterministic FNV-1a 64-bit digest as 16 hex chars. Used for disk cache
    /// keys because `Hasher` is seeded per process (keys wouldn't survive a
    /// relaunch).
    private static func fnv1aHex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func readCache(_ key: String) -> CacheEnvelope? {
        let url = Self.cacheDir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              Date().timeIntervalSince(envelope.fetchedAt) < Self.cacheTTL else { return nil }
        return envelope
    }

    private func writeCache(_ meta: GameMetadata?, key: String) {
        let url = Self.cacheDir.appendingPathComponent("\(key).json")
        let envelope = CacheEnvelope(fetchedAt: Date(), meta: meta)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func queryIGDB(token: String, whereClause: String) async -> QueryResult {
        guard let url = URL(string: "https://api.igdb.com/v4/games") else { return .transientFailure }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Secrets.twitchClientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "fields name,summary,genres.name,release_dates.y,involved_companies.company.name,involved_companies.developer,rating; where \(whereClause); limit 1;".data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transientFailure }
            switch http.statusCode {
            case 200:
                guard let game = Self.parseFirstGame(data: data) else { return .empty }
                return .found(Self.parseMetadata(game: game))
            case 401:
                return .unauthorized
            case 429:
                Log.debug("IGDB: rate-limited (429) — miss not cached")
                return .transientFailure
            default:
                Log.debug("IGDB: query HTTP \(http.statusCode)")
                return .transientFailure
            }
        } catch {
            Log.debug("IGDB: query failed — \(error.localizedDescription)")
            return .transientFailure
        }
    }

    /// Extracts the first game object from an IGDB list response, or nil when
    /// the list is empty/malformed (the definitive "no match" signal).
    static func parseFirstGame(data: Data) -> [String: Any]? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.first
    }

    /// Parses IGDB game response: `[{ name, summary, genres: [{name}],
    /// release_dates: [{y}], involved_companies: [{company:{name}, developer}] }]`.
    static func parseMetadata(data: Data) -> GameMetadata? {
        guard let game = parseFirstGame(data: data) else { return nil }
        return parseMetadata(game: game)
    }

    private static func parseMetadata(game: [String: Any]) -> GameMetadata {
        var meta = GameMetadata()

        // Genre (take the first one).
        if let genres = game["genres"] as? [[String: Any]], let first = genres.first?["name"] as? String {
            meta.genre = first
        }

        // Release year.
        if let dates = game["release_dates"] as? [[String: Any]] {
            meta.releaseYear = dates.compactMap { $0["y"] as? Int }.first
        }

        // Developer (first company where developer == true).
        if let companies = game["involved_companies"] as? [[String: Any]] {
            for entry in companies {
                if (entry["developer"] as? Bool) == true,
                   let company = entry["company"] as? [String: Any],
                   let name = company["name"] as? String {
                    meta.developer = name
                    break
                }
            }
        }

        // Summary (truncate to ~200 chars for panel display).
        if let summary = game["summary"] as? String, !summary.isEmpty {
            meta.summary = summary.count > 200 ? String(summary.prefix(197)) + "…" : summary
        }

        return meta
    }
}
