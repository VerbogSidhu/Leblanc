import Combine
import Foundation

/// Aggregates all library sources into the flat list the UI renders, and
/// surfaces the recently-launched subset. Scans run off the main thread.
final class LibraryStore: ObservableObject {
    @Published private(set) var games: [GameEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanError: String?

    let steam = SteamLibrary()
    let roms = RomLibrary()
    let recents = RecentsStore()
    let settings: SettingsStore

    private let scanQueue = DispatchQueue(label: "com.gamedock.library.scan", qos: .userInitiated)

    init(settings: SettingsStore) {
        self.settings = settings
    }

    // MARK: - Derived collections (UI consumes these)

    var steamGames: [GameEntry] { games.filter { $0.source == .steam } }
    var pspGames: [GameEntry] { games.filter { $0.source == .psp } }
    var dsGames: [GameEntry] { games.filter { $0.source == .ds } }
    var recentGames: [GameEntry] { recents.recentGames(from: games) }
    var isEmpty: Bool { games.isEmpty }

    // MARK: - Scanning

    /// Runs a full rescan off the main thread and publishes results.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        scanQueue.async { [weak self] in
            guard let self else { return }
            let result = self.scanSynchronously()
            DispatchQueue.main.async {
                self.games = result
                self.lastScanError = nil
                self.isScanning = false
                Log.info("LibraryStore: refreshed — \(result.count) games")
            }
        }
    }

    private func scanSynchronously() -> [GameEntry] {
        var all: [GameEntry] = []

        // Steam — fastest, do it first so the UI can render soon.
        all.append(contentsOf: steam.gameEntries())

        // Emulator sources.
        for source in [GameSource.psp, GameSource.ds] {
            for folderPath in settings.romFolders[source] ?? [] {
                let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
                all.append(contentsOf: roms.scan(folder: folder, extensions: Set(source.romExtensions), source: source))
            }
        }

        // Fold in the most recent launch time for each game.
        for index in all.indices {
            if let date = recents.lastPlayedDate(for: all[index].id) {
                all[index].lastPlayed = date
            }
        }
        return all
    }

    // MARK: - Launch bookkeeping

    func recordLaunch(_ entry: GameEntry) {
        recents.record(entry: entry)
        for index in games.indices where games[index].id == entry.id {
            games[index].lastPlayed = Date()
            break
        }
    }
}
