import Foundation

/// Persists user-favorited games as an ordered JSON list
/// (~/Library/Application Support/GameDock/favorites.json). Favorites render
/// first in the Home category (see AppEnvironment.homeItems).
final class FavoritesStore {
    private let fileURL = AppPaths.favoritesFile
    private let lock = NSLock()
    private var _ids: [String] = []

    /// Favorite game ids in most-recently-favorited order.
    var ids: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _ids
    }

    init() {
        load()
    }

    func isFavorite(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _ids.contains(id)
    }

    func toggle(_ id: String) {
        lock.lock()
        if let idx = _ids.firstIndex(of: id) {
            _ids.remove(at: idx)
        } else {
            _ids.insert(id, at: 0)
        }
        lock.unlock()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return }
        lock.lock()
        _ids = ids
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let copy = _ids
        lock.unlock()
        do {
            try FileManager.default.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(copy)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("FavoritesStore: save failed — \(error.localizedDescription)")
        }
    }
}
