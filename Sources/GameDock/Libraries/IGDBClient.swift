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
    private nonisolated(unsafe) let tokenLock = NSLock()

    /// Ensures a valid Twitch access token exists. Returns nil only if
    /// credentials are missing or the token endpoint fails.
    private func ensureToken() async -> String? {
        tokenLock.lock()
        if let token = accessToken, let expiry = tokenExpiry, Date() < expiry {
            tokenLock.unlock()
            return token
        }
        tokenLock.unlock()

        guard Secrets.isIGDBConfigured else { return nil }
        guard let url = URL(string: "https://id.twitch.tv/oauth2/token") else { return nil }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Secrets.twitchClientID),
            URLQueryItem(name: "client_secret", value: Secrets.twitchClientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        guard let requestURL = components.url else { return nil }

        do {
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
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

    /// Fetches metadata for a game by Steam app ID or ROM title.
    /// Returns nil if IGDB has no match or credentials are missing.
    func metadata(for steamAppID: String?) async -> GameMetadata? {
        guard let appID = steamAppID else { return nil }
        let cacheKey = "steam-\(appID)"
        if let cached = readCache(cacheKey) { return cached }
        guard let token = await ensureToken() else { return nil }
        let meta = await queryIGDB(token: token, whereClause: "external_games.uid = \"steam_\(appID)\"")
        writeCache(meta, key: cacheKey)
        return meta
    }

    func metadata(forTitle title: String) async -> GameMetadata? {
        let cacheKey = "title-\(title.lowercased().hash)"
        if let cached = readCache(cacheKey) { return cached }
        guard let token = await ensureToken() else { return nil }
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        let meta = await queryIGDB(token: token, whereClause: "name ~ *\"\(escaped)\"*")
        writeCache(meta, key: cacheKey)
        return meta
    }

    private func readCache(_ key: String) -> GameMetadata? {
        let url = Self.cacheDir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(CacheEnvelope.self, from: data),
              Date().timeIntervalSince(envelope.fetchedAt) < Self.cacheTTL else { return nil }
        return envelope.meta
    }

    private func writeCache(_ meta: GameMetadata?, key: String) {
        let url = Self.cacheDir.appendingPathComponent("\(key).json")
        let envelope = CacheEnvelope(fetchedAt: Date(), meta: meta)
        if let data = try? JSONEncoder().encode(envelope) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func queryIGDB(token: String, whereClause: String) async -> GameMetadata? {
        guard let url = URL(string: "https://api.igdb.com/v4/games") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Secrets.twitchClientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "fields name,summary,genres.name,release_dates.y,involved_companies.company.name,involved_companies.developer,rating; where \(whereClause); limit 1;".data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.debug("IGDB: query HTTP \(http.statusCode)")
                return nil
            }
            return Self.parseMetadata(data: data)
        } catch {
            Log.debug("IGDB: query failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Parses IGDB game response: `[{ name, summary, genres: [{name}],
    /// release_dates: [{y}], involved_companies: [{company:{name}, developer}] }]`.
    static func parseMetadata(data: Data) -> GameMetadata? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let game = arr.first else { return nil }

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
