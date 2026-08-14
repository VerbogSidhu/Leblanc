import Combine
import Foundation

/// User configuration, persisted in UserDefaults (suite com.gamedock.GameDock):
/// ROM folder paths per system and optional libretro core path overrides.
final class SettingsStore: ObservableObject {
    static let suiteName = "com.gamedock.GameDock"

    private enum Key {
        static let romFolders = "romFolders"          // [GameSource.rawValue: [String]]
        static let coreOverrides = "coreOverrides"    // [GameSource.rawValue: String]
        static let standalonePaths = "standalonePaths" // [appKey: String] (e.g. "ppsspp")
        static let raUsername = "raUsername"          // String? (not sensitive)
        static let raAPIToken = "raAPIToken"          // legacy UserDefaults key — migrated to Keychain
        static let raHardcore = "raHardcore"          // Bool (default true)
        static let raUnofficial = "raUnofficial"      // Bool (default false)
    }

    private static let keychainAccount = "ra-api-key"

    private let defaults: UserDefaults

    @Published private(set) var romFolders: [GameSource: [String]]
    @Published private(set) var coreOverrides: [GameSource: String]
    @Published private(set) var standalonePaths: [String: String]

    @Published private(set) var raUsername: String?
    @Published private(set) var raAPIToken: String?
    @Published private(set) var raHardcore: Bool
    @Published private(set) var raUnofficial: Bool

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

        self.standalonePaths = storage.dictionary(forKey: Key.standalonePaths) as? [String: String] ?? [:]

        self.raUsername = storage.string(forKey: Key.raUsername)
        self.raAPIToken = Self.loadAPIToken(legacyDefaults: storage)
        self.raHardcore = storage.object(forKey: Key.raHardcore) as? Bool ?? true
        self.raUnofficial = storage.object(forKey: Key.raUnofficial) as? Bool ?? false
    }

    /// The API key lives in the Keychain. One-time migration: if a legacy
    /// UserDefaults value exists, move it to the Keychain and delete it.
    private static func loadAPIToken(legacyDefaults: UserDefaults) -> String? {
        if let keychain = KeychainStore.get(keychainAccount) {
            return keychain
        }
        if let legacy = legacyDefaults.string(forKey: Key.raAPIToken), !legacy.isEmpty {
            _ = KeychainStore.set(legacy, forKey: keychainAccount)
            legacyDefaults.removeObject(forKey: Key.raAPIToken)
            return legacy
        }
        return nil
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

    // MARK: - Standalone emulator paths

    func standaloneAppPath(for key: String) -> String? {
        standalonePaths[key]
    }

    func setStandaloneAppPath(_ path: String?, for key: String) {
        if let path, !path.isEmpty {
            standalonePaths[key] = path
        } else {
            standalonePaths.removeValue(forKey: key)
        }
        defaults.set(standalonePaths, forKey: Key.standalonePaths)
    }

    // MARK: - RetroAchievements

    func setRACredentials(username: String?, token: String?) {
        raUsername = username
        defaults.set(username, forKey: Key.raUsername)
        // The key goes to the Keychain only — never UserDefaults/plist/logs.
        if let token, !token.isEmpty {
            _ = KeychainStore.set(token, forKey: Self.keychainAccount)
            raAPIToken = token
        } else {
            KeychainStore.delete(Self.keychainAccount)
            raAPIToken = nil
        }
    }

    func setRAHardcore(_ enabled: Bool) {
        raHardcore = enabled
        defaults.set(enabled, forKey: Key.raHardcore)
    }

    func setRAUnofficial(_ enabled: Bool) {
        raUnofficial = enabled
        defaults.set(enabled, forKey: Key.raUnofficial)
    }

    /// True when both RA credentials are set (achievements enabled).
    var raConfigured: Bool {
        !(raUsername?.isEmpty ?? true) && !(raAPIToken?.isEmpty ?? true)
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
