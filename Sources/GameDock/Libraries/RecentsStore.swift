import Foundation

/// Persists recently-launched games as a small JSON list
/// (~/Library/Application Support/GameDock/recents.json).
final class RecentsStore {
    static let maxRecents = 20

    private let fileURL = AppPaths.recentsFile
    private let lock = NSLock()
    private var _launches: [RecentLaunch] = []

    var launches: [RecentLaunch] {
        lock.lock()
        defer { lock.unlock() }
        return _launches
    }

    init() {
        load()
    }

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
        lock.lock()
        _launches.removeAll { $0.entryID == launch.entryID }
        _launches.insert(launch, at: 0)
        if _launches.count > Self.maxRecents {
            _launches = Array(_launches.prefix(Self.maxRecents))
        }
        lock.unlock()
        save()
    }

    /// Adds playtime to the most recent launch of the given game (called when
    /// a handoff ends / emulation exits).
    func recordPlaytime(entryID: String, duration: TimeInterval) {
        lock.lock()
        if let idx = _launches.firstIndex(where: { $0.entryID == entryID }) {
            let existing = _launches[idx].durationSeconds ?? 0
            _launches[idx].durationSeconds = existing + Int(duration)
        }
        lock.unlock()
        save()
    }

    /// Total tracked playtime across all launches of the given game.
    func totalPlaytime(for entryID: String) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _launches.reduce(TimeInterval(0)) { $0 + TimeInterval($1.durationSeconds ?? 0) }
    }

    func lastPlayedDate(for entryID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return _launches.first(where: { $0.entryID == entryID })?.date
    }

    /// Maps the persisted list back onto the current library (drops entries
    /// whose game is no longer installed).
    func recentGames(from library: [GameEntry]) -> [GameEntry] {
        var byID: [String: GameEntry] = [:]
        for game in library { byID[game.id] = game }
        lock.lock()
        let snapshot = _launches
        lock.unlock()
        return snapshot.compactMap { launch in
            guard var game = byID[launch.entryID] else { return nil }
            game.lastPlayed = launch.date
            return game
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        lock.lock()
        _launches = (try? JSONDecoder().decode([RecentLaunch].self, from: data)) ?? []
        lock.unlock()
    }

    private func save() {
        lock.lock()
        let copy = _launches
        lock.unlock()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(copy)
            try FileManager.default.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("RecentsStore: save failed — \(error.localizedDescription)")
        }
    }
}
