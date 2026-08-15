import Foundation

/// Persists recently-launched games as a small JSON list
/// (~/Library/Application Support/GameDock/recents.json).
final class RecentsStore {
    static let maxRecents = 20

    private let store = JSONFileStore<[RecentLaunch]>(fileURL: AppPaths.recentsFile, default: [])

    var launches: [RecentLaunch] { store.read { $0 } }

    func record(entry: GameEntry) {
        record(entry: entry, duration: 0)
    }

    func record(entry: GameEntry, duration: TimeInterval) {
        let launch = RecentLaunch(
            entryID: entry.id,
            title: entry.title,
            source: entry.source,
            date: Date(),
            durationSeconds: Int(duration)
        )
        store.mutate { launches in
            launches.removeAll { $0.entryID == launch.entryID }
            launches.insert(launch, at: 0)
            if launches.count > Self.maxRecents {
                launches = Array(launches.prefix(Self.maxRecents))
            }
        }
    }

    /// Adds playtime to the most recent launch of the given game (called when
    /// a handoff ends / emulation exits).
    func recordPlaytime(entryID: String, duration: TimeInterval) {
        store.mutate { launches in
            if let idx = launches.firstIndex(where: { $0.entryID == entryID }) {
                let existing = launches[idx].durationSeconds ?? 0
                launches[idx].durationSeconds = existing + Int(duration)
            }
        }
    }

    /// Total tracked playtime across all launches of the given game.
    func totalPlaytime(for entryID: String) -> TimeInterval {
        store.read { launches in
            launches.reduce(TimeInterval(0)) { $0 + TimeInterval($1.durationSeconds ?? 0) }
        }
    }

    func lastPlayedDate(for entryID: String) -> Date? {
        store.read { $0.first(where: { $0.entryID == entryID })?.date }
    }

    /// Maps the persisted list back onto the current library (drops entries
    /// whose game is no longer installed).
    func recentGames(from library: [GameEntry]) -> [GameEntry] {
        var byID: [String: GameEntry] = [:]
        for game in library { byID[game.id] = game }
        let snapshot = store.read { $0 }
        return snapshot.compactMap { launch in
            guard var game = byID[launch.entryID] else { return nil }
            game.lastPlayed = launch.date
            return game
        }
    }
}
