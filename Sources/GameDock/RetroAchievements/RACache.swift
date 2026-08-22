import Foundation

/// Local JSON cache for RA API responses, keyed by endpoint, with a timestamp.
/// Respects RA's rate-limit expectations: callers decide TTL, we just store.
struct RACache {
    private struct Envelope<T: Codable>: Codable {
        let fetchedAt: Date
        let value: T
    }

    private let directory: URL

    /// Cache root, optionally scoped to an account so switching usernames
    /// never serves another profile's cached envelopes.
    init(username: String? = nil) {
        var dir = AppPaths.appSupport.appendingPathComponent("ra-cache", isDirectory: true)
        if let username, !username.isEmpty {
            dir.appendPathComponent(Self.sanitizedUsername(username), isDirectory: true)
        }
        directory = dir
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// File-safe scope tag for a username.
    private static func sanitizedUsername(_ username: String) -> String {
        let safe = username.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        return safe.isEmpty ? "default" : String(safe.prefix(64))
    }

    struct Entry<T: Codable> {
        let value: T
        let fetchedAt: Date
    }

    func load<T: Codable>(_ key: String, as: T.Type) -> Entry<T>? {
        let url = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { return nil }
        return Entry(value: envelope.value, fetchedAt: envelope.fetchedAt)
    }

    func save<T: Codable>(_ value: T, key: String) {
        let envelope = Envelope(fetchedAt: Date(), value: value)
        if let data = try? JSONEncoder().encode(envelope) {
            let url = directory.appendingPathComponent("\(key).json")
            try? data.write(to: url, options: .atomic)
        }
    }
}
