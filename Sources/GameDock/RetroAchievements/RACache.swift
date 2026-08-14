import Foundation

/// Local JSON cache for RA API responses, keyed by endpoint, with a timestamp.
/// Respects RA's rate-limit expectations: callers decide TTL, we just store.
struct RACache {
    private struct Envelope<T: Codable>: Codable {
        let fetchedAt: Date
        let value: T
    }

    private let directory: URL

    init() {
        directory = AppPaths.appSupport.appendingPathComponent("ra-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
