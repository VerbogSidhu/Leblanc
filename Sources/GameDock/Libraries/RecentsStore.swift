import Foundation

/// Persists recently-launched games as a small JSON list
/// (~/Library/Application Support/GameDock/recents.json).
final class RecentsStore {
    static let maxRecents = 20

    private let fileURL = AppPaths.recentsFile
    private(set) var launches: [RecentLaunch] = []

    init() {
        load()
    }

    func record(entry: GameEntry) {
        let launch = RecentLaunch(
            entryID: entry.id,
            title: entry.title,
            source: entry.source,
            date: Date()
        )
        launches.removeAll { $0.entryID == launch.entryID }
        launches.insert(launch, at: 0)
        if launches.count > Self.maxRecents {
            launches = Array(launches.prefix(Self.maxRecents))
        }
        save()
    }

    func lastPlayedDate(for entryID: String) -> Date? {
        launches.first(where: { $0.entryID == entryID })?.date
    }

    /// Maps the persisted list back onto the current library (drops entries
    /// whose game is no longer installed).
    func recentGames(from library: [GameEntry]) -> [GameEntry] {
        var byID: [String: GameEntry] = [:]
        for game in library { byID[game.id] = game }
        return launches.compactMap { launch in
            guard var game = byID[launch.entryID] else { return nil }
            game.lastPlayed = launch.date
            return game
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        launches = (try? JSONDecoder().decode([RecentLaunch].self, from: data)) ?? []
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(launches)
            try FileManager.default.createDirectory(at: AppPaths.appSupport, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("RecentsStore: save failed — \(error.localizedDescription)")
        }
    }
}
