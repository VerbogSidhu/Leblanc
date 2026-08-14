import Combine
import Foundation

/// User configuration, persisted in UserDefaults (suite com.gamedock.GameDock):
/// ROM folder paths per system and optional libretro core path overrides.
final class SettingsStore: ObservableObject {
    static let suiteName = "com.gamedock.GameDock"

    private enum Key {
        static let romFolders = "romFolders"          // [GameSource.rawValue: [String]]
        static let coreOverrides = "coreOverrides"    // [GameSource.rawValue: String]
    }

    private let defaults: UserDefaults

    @Published private(set) var romFolders: [GameSource: [String]]
    @Published private(set) var coreOverrides: [GameSource: String]

    init(defaults: UserDefaults? = nil) {
        let storage = defaults ?? UserDefaults(suiteName: SettingsStore.suiteName) ?? .standard
        self.defaults = storage

        let rawFolders = storage.dictionary(forKey: Key.romFolders) as? [String: [String]] ?? [:]
        self.romFolders = Dictionary(uniqueKeysWithValues: rawFolders.compactMap { key, value in
            guard let source = GameSource(rawValue: key) else { return nil }
            return (source, value)
        })

        let rawCores = storage.dictionary(forKey: Key.coreOverrides) as? [String: String] ?? [:]
        self.coreOverrides = Dictionary(uniqueKeysWithValues: rawCores.compactMap { key, value in
            guard let source = GameSource(rawValue: key) else { return nil }
            return (source, value)
        })
    }

    // MARK: - ROM folders

    func addROMFolder(_ path: String, for source: GameSource) {
        var list = romFolders[source] ?? []
        if !list.contains(path) {
            list.append(path)
        }
        romFolders[source] = list
        persistROMFolders()
    }

    func removeROMFolder(at index: Int, for source: GameSource) {
        var list = romFolders[source] ?? []
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        romFolders[source] = list
        persistROMFolders()
    }

    // MARK: - Core overrides

    func setCoreOverride(_ path: String?, for source: GameSource) {
        if let path, !path.isEmpty {
            coreOverrides[source] = path
        } else {
            coreOverrides.removeValue(forKey: source)
        }
        persistCoreOverrides()
    }

    // MARK: - Persistence

    private func persistROMFolders() {
        let raw = Dictionary(uniqueKeysWithValues: romFolders.map { ($0.key.rawValue, $0.value) })
        defaults.set(raw, forKey: Key.romFolders)
    }

    private func persistCoreOverrides() {
        let raw = Dictionary(uniqueKeysWithValues: coreOverrides.map { ($0.key.rawValue, $0.value) })
        defaults.set(raw, forKey: Key.coreOverrides)
    }
}
