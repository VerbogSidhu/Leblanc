import Foundation

/// A hand-rolled async client for the RetroAchievements Web API
/// (https://api-docs.retroachievements.org). Plain REST/JSON over HTTP GET;
/// auth is `u` (username) + `y` (Web API key) query params.
struct RAClient {
    let username: String
    let apiKey: String

    private let base = URL(string: "https://retroachievements.org/API")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    enum RAClientError: LocalizedError {
        case badURL
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid RetroAchievements URL."
            case .http(let code): return "RetroAchievements returned HTTP \(code)."
            case .empty: return "RetroAchievements returned no data."
            }
        }
    }

    func profile() async throws -> RAProfile {
        try await get("API_GetUserProfile.php", as: RAProfile.self)
    }

    func recentAchievements(minutes: Int = 10080) async throws -> [RARecentAchievement] {
        try await get("API_GetUserRecentAchievements.php",
                      params: ["m": String(minutes)],
                      as: [RARecentAchievement].self)
    }

    func completionProgress() async throws -> [RACompletionProgressEntry] {
        let envelope = try await get("API_GetUserCompletionProgress.php", as: RACompletionProgress.self)
        return envelope.results
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ endpoint: String, params: [String: String] = [:], as: T.Type) async throws -> T {
        var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "y", value: apiKey),
                     URLQueryItem(name: "u", value: username)]
        for (k, v) in params {
            items.append(URLQueryItem(name: k, value: v))
        }
        components.queryItems = items

        guard let url = components.url else { throw RAClientError.badURL }

        var request = URLRequest(url: url)
        request.setValue("GameDock/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RAClientError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw RAClientError.empty }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
}
