import Foundation

/// Persists user-favorited games as an ordered JSON list
/// (~/Library/Application Support/GameDock/favorites.json). Favorites render
/// first in the Home category (see AppEnvironment.homeItems).
final class FavoritesStore {
    private let store = JSONFileStore<[String]>(fileURL: AppPaths.favoritesFile, default: [])

    /// Favorite game ids in most-recently-favorited order.
    var ids: [String] { store.read { $0 } }

    func isFavorite(_ id: String) -> Bool {
        store.read { $0.contains(id) }
    }

    func toggle(_ id: String) {
        store.mutate { ids in
            if let idx = ids.firstIndex(of: id) {
                ids.remove(at: idx)
            } else {
                ids.insert(id, at: 0)
            }
        }
    }
}
