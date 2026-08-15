import Foundation

/// Thread-safe, atomically-persisted JSON document store. Collapses the
/// load/save/lock boilerplate that FavoritesStore and RecentsStore used to
/// hand-roll identically.
///
/// - `read` runs a closure under the lock (never persists).
/// - `mutate` runs a closure under the lock, then persists atomically.
final class JSONFileStore<Value: Codable> {
    private let fileURL: URL
    private let lock = NSLock()
    private var value: Value

    init(fileURL: URL, default defaultValue: Value) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Value.self, from: data) {
            self.value = decoded
        } else {
            self.value = defaultValue
        }
    }

    func read<Result>(_ body: (Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        let snapshot = value
        lock.unlock()
        persist(snapshot)
    }

    private func persist(_ snapshot: Value) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("\(fileURL.lastPathComponent) save failed — \(error.localizedDescription)")
        }
    }
}
