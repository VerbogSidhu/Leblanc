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
        static let globalCapture = "globalCapture"     // Bool (default false) — experimental
        static let coreOptions = "coreOptions"        // [coreID: [gameID: [optionKey: token]]]
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
    /// Experimental global PS-button capture (needs Input Monitoring). Off
    /// by default so ordinary launches never prompt TCC; the Cmd+Shift+Home
    /// hotkey remains the permission-free fallback.
    @Published private(set) var globalCaptureEnabled: Bool

    /// Per-game core options: coreID → gameID → optionKey → selected token.
    /// GameID is the stable GameEntry id (FNV-1a romID); a game with no saved
    /// overrides starts from the core's defaults (first token).
    @Published private(set) var coreOptions: [String: [String: [String: String]]] = [:]

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
        self.globalCaptureEnabled = storage.object(forKey: Key.globalCapture) as? Bool ?? false
        self.coreOptions = storage.dictionary(forKey: Key.coreOptions)
            as? [String: [String: [String: String]]] ?? [:]
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

    func setGlobalCapture(_ enabled: Bool) {
        globalCaptureEnabled = enabled
        defaults.set(enabled, forKey: Key.globalCapture)
    }

    /// True when both RA credentials are set (achievements enabled).
    var raConfigured: Bool {
        !(raUsername?.isEmpty ?? true) && !(raAPIToken?.isEmpty ?? true)
    }

    // MARK: - Core options (per game)

    func setCoreOption(_ token: String, key: String, core: String, game: String) {
        var byGame = coreOptions[core] ?? [:]
        var opts = byGame[game] ?? [:]
        opts[key] = token
        byGame[game] = opts
        coreOptions[core] = byGame
        defaults.set(coreOptions, forKey: Key.coreOptions)
    }

    func coreOption(_ key: String, core: String, game: String) -> String? {
        coreOptions[core]?[game]?[key]
    }

    /// Clears a game's saved overrides (future "Reset to defaults" action).
    func clearCoreOptions(core: String, game: String) {
        coreOptions[core]?.removeValue(forKey: game)
        defaults.set(coreOptions, forKey: Key.coreOptions)
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
