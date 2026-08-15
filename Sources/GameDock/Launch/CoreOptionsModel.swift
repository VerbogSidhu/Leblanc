import Combine
import Foundation

/// A single core option as defined by the core (via SET_VARIABLES).
struct CoreOptionDefinition: Equatable {
    let key: String
    let title: String
    let values: [String]
}

/// Parses a classic libretro option string: `"Human Title; opt1|opt2|opt3"`.
/// Pure — unit-tested in CLIUnitTest.
enum CoreOptionParser {
    static func parse(_ value: String) -> (title: String, values: [String])? {
        let parts = value.split(separator: ";", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let values = parts[1].split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        return (parts[0], values)
    }
}

/// Single source of truth for the running core's options.
///
/// Threading contract:
///   • RetroEnvironment handlers run on the main thread during load and on the
///     core thread during run — they call the lock-guarded read/write methods.
///   • UI (AppEnvironment router) calls `moveCursor`/`cycleValue` on main.
///   • `@Published` state is only mutated on the main queue (publish() hops).
///
/// Persistence is per game: `coreOptions[coreID][gameID][optionKey]` in
/// SettingsStore. A game with no saved overrides starts from the core's
/// defaults (first token of each option) — never another game's values.
final class CoreOptionsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let key: String
        let title: String
        let values: [String]
        var selectedIndex: Int
        var id: String { key }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var cursor = 0

    private let lock = NSLock()
    private var definitions: [String: CoreOptionDefinition] = [:]
    private var keys: [String] = []
    private var values: [String: String] = [:]
    /// Stable C-string storage for GET_VARIABLE answers (keyed by option key).
    /// Content is rewritten in place on value changes; never freed until deinit.
    private var buffers: [String: UnsafeMutablePointer<CChar>] = [:]
    private var bufferCapacity: [String: Int] = [:]
    /// Set when the frontend changes a value; consumed by GET_VARIABLE_UPDATE.
    private var changed = false

    private weak var settings: SettingsStore?
    private let coreID: String
    private let gameID: String

    init(coreID: String, gameID: String, settings: SettingsStore?) {
        self.coreID = coreID
        self.gameID = gameID
        self.settings = settings
    }

    var hasOptions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !keys.isEmpty
    }

    // MARK: - Environment-side API (any thread)

    /// SET_VARIABLES: adopt the core's definitions and seed values (persisted
    /// per-game token when valid, else the first token).
    func ingest(_ definitions: [String: CoreOptionDefinition]) {
        lock.lock()
        self.definitions = definitions
        self.keys = definitions.keys.sorted()
        for (key, def) in definitions {
            let persisted = settings?.coreOption(def.key, core: coreID, game: gameID)
            let token = (persisted != nil && def.values.contains(persisted!)) ? persisted! : (def.values.first ?? "")
            values[key] = token
            writeBuffer(key: key, token: token, def: def)
        }
        changed = false
        lock.unlock()
        publish()
    }

    /// GET_VARIABLE: pointer to the currently selected token's stable buffer.
    func readValue(forKey key: String) -> UnsafePointer<CChar>? {
        lock.lock()
        defer { lock.unlock() }
        return buffers[key].map { UnsafePointer($0) }
    }

    /// GET_VARIABLE_UPDATE: the changed flag, cleared after the read.
    func takeChangedFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let c = changed
        changed = false
        return c
    }

    /// SET_VARIABLE (core-initiated) or programmatic set (self-test):
    /// adopt a token and persist it for this game.
    @discardableResult
    func setValue(_ token: String, forKey key: String, persist: Bool) -> Bool {
        lock.lock()
        guard let def = definitions[key], def.values.contains(token) else {
            lock.unlock()
            return false
        }
        values[key] = token
        writeBuffer(key: key, token: token, def: def)
        changed = true
        lock.unlock()
        if persist { settings?.setCoreOption(token, key: key, core: coreID, game: gameID) }
        publish()
        return true
    }

    // MARK: - UI API (main thread)

    func moveCursor(_ delta: Int) {
        lock.lock()
        if !keys.isEmpty { cursor = (cursor + delta + keys.count) % keys.count }
        lock.unlock()
        publish()
    }

    /// Cycles the value at the cursor by `delta` and applies it live (updates
    /// the stored token + GET_VARIABLE_UPDATE flag + per-game persistence).
    func cycleValue(_ delta: Int) {
        lock.lock()
        guard keys.indices.contains(cursor), let def = definitions[keys[cursor]] else {
            lock.unlock()
            return
        }
        let current = values[def.key] ?? def.values.first ?? ""
        let idx = def.values.firstIndex(of: current) ?? 0
        let newToken = def.values[(idx + delta + def.values.count) % def.values.count]
        values[def.key] = newToken
        writeBuffer(key: def.key, token: newToken, def: def)
        changed = true
        lock.unlock()
        settings?.setCoreOption(newToken, key: def.key, core: coreID, game: gameID)
        publish()
    }

    // MARK: - Buffer management

    /// Writes `token` into (or allocates) the stable buffer for `key`. The
    /// pointer handed to cores stays valid for the session — content is
    /// rewritten in place; realloc only if a token outgrows the allocation.
    private func writeBuffer(key: String, token: String, def: CoreOptionDefinition) {
        let needed = token.utf8.count + 1
        if let existing = buffers[key] {
            if needed <= bufferCapacity[key] ?? 0 {
                token.withCString { strcpy(existing, $0); return () }
            } else {
                existing.deallocate()
                let capacity = max(needed, (def.values.map { $0.utf8.count }.max() ?? 0) + 1)
                let p = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
                token.withCString { strcpy(p, $0); return () }
                buffers[key] = p
                bufferCapacity[key] = capacity
            }
        } else {
            let capacity = max(needed, (def.values.map { $0.utf8.count }.max() ?? 0) + 1)
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
            token.withCString { strcpy(p, $0); return () }
            buffers[key] = p
            bufferCapacity[key] = capacity
        }
    }

    /// Publishes the UI snapshot on the main queue.
    private func publish() {
        let snapshot: [Row]
        let cur: Int
        lock.lock()
        snapshot = keys.compactMap { key in
            guard let def = definitions[key] else { return nil }
            let token = values[key] ?? def.values.first ?? ""
            return Row(key: key, title: def.title, values: def.values,
                       selectedIndex: def.values.firstIndex(of: token) ?? 0)
        }
        cur = cursor
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rows = snapshot
            self.cursor = snapshot.isEmpty ? 0 : min(cur, snapshot.count - 1)
        }
    }

    deinit {
        for p in buffers.values {
            p.deallocate()
        }
    }
}
