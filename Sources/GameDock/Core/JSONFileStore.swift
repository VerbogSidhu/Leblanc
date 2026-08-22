import Foundation

/// Thread-safe, atomically-persisted JSON document store. Collapses the
/// load/save/lock boilerplate that FavoritesStore and RecentsStore used to
/// hand-roll identically.
///
/// - `Value` MUST be a value type (struct/enum): persistence snapshots the
///   stored value under the lock; a reference type would escape and race.
/// - `read` runs a closure under the lock (never persists).
/// - `mutate` runs a closure under the lock, then persists atomically
///   (encode + write happen inside the lock).
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
            // Missing file = first run (quiet). Existing-but-unreadable =
            // corrupt: move it aside instead of silently resetting it.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                Log.error("\(fileURL.lastPathComponent) unreadable/corrupt — moved to \(backup.lastPathComponent); starting from default")
            }
            self.value = defaultValue
        }
    }

    func read<Result>(_ body: (Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }

    func mutate(_ body: (inout Value) -> Void) {
        // Encode+write under the lock so racing mutators can't persist
        // snapshots out of order (writes are small; disk cost acceptable).
        lock.lock()
        defer { lock.unlock() }
        body(&value)
        persist(value)
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
