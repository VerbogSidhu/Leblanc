import Foundation

/// A game discovered in a Steam library folder (from an appmanifest_*.acf).
struct SteamAppInfo {
    let appID: String
    let name: String
    let installDir: String
    let sizeOnDisk: Int64
    let lastPlayed: Date?
    /// Raw StateFlags bitfield (scout report §3.3).
    let stateFlags: Int
    /// True when Steam flags the install as needing an update (bit 0x2).
    let needsUpdate: Bool
    /// Absolute path to the steamapps folder that contains this app.
    let libraryPath: URL
}

/// Result of a full Steam library scan, with diagnostics for the UI/CLI.
struct SteamScanResult {
    let games: [SteamAppInfo]
    let foldersScanned: Int
    let skippedManifests: Int
}

/// Scans Steam's install by parsing `libraryfolders.vdf` and every
/// `appmanifest_*.acf`. Steam stays a closed client — we only read its
/// metadata and launch games via the `steam://run/<appid>` URL scheme.
///
/// Ground rules established by docs/scout-steam-report.md:
///   • appmanifest_*.acf + StateFlags is the authoritative "installed" source
///     (the libraryfolders "apps" block is stale; common/ is full of orphans).
///   • A manifest is launchable when (StateFlags & 0x4) != 0 (installed/ready);
///     StateFlags == 0x2 means uninstalling → excluded.
final class SteamLibrary {
    static let defaultSteamPath = "~/Library/Application Support/Steam"
    static let steamBundleID = "com.valvesoftware.steam"

    private let fileManager = FileManager.default
    private var cachedGridDirs: [URL]?

    // MARK: - Steam root & library folders

    /// Resolves Steam's base install directory.
    func steamRoot() -> URL? {
        let expanded = (SteamLibrary.defaultSteamPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// All steamapps folders: the default one plus any extra mount points.
    /// Reads the `steamapps/libraryfolders.vdf` mirror; falls back to
    /// `config/libraryfolders.vdf` if the mirror is missing.
    func steamAppsFolders() -> [URL] {
        guard let root = steamRoot() else { return [] }
        var folders = [root.appendingPathComponent("steamapps", isDirectory: true)]

        let primary = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        let fallback = root.appendingPathComponent("config/libraryfolders.vdf")
        let vdfURL = fileManager.fileExists(atPath: primary.path) ? primary : fallback

        guard let text = try? String(contentsOf: vdfURL, encoding: .utf8),
              let value = VDFParser.parse(text),
              // Root key is the file's top-level name (e.g. "libraryfolders").
              let libs = (value["libraryfolders"]?.dict) ?? value.dict else {
            return folders
        }

        // libraryfolders.vdf maps "0".."N" -> { "path": "...", ... }.
        // Iterate the parsed integer keys instead of a magic 0...64 range.
        let mountKeys = libs.keys.compactMap(Int.init).sorted()
        for key in mountKeys {
            guard let rawPath = libs[String(key)]?["path"]?.string,
                  let path = normalizedLibraryPath(rawPath, root: root) else {
                Log.warn("SteamLibrary: skipping unreadable mount \(key)")
                continue
            }
            folders.append(path.appendingPathComponent("steamapps", isDirectory: true))
        }
        return Array(Set(folders)).sorted { $0.path < $1.path }
    }

    /// Normalizes a library path value: `\` → `/`, relative paths resolve
    /// against the Steam root, duplicate slashes collapse.
    private func normalizedLibraryPath(_ raw: String, root: URL) -> URL? {
        var p = raw.replacingOccurrences(of: "\\", with: "/")
        if !p.hasPrefix("/") {
            p = root.path + "/" + p
        }
        while p.contains("//") {
            p = p.replacingOccurrences(of: "//", with: "/")
        }
        let url = URL(fileURLWithPath: p, isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Installed game enumeration

    /// Parses every appmanifest_*.acf across all library folders, deduped by
    /// appID (first-intact-wins; LastPlayed/SizeOnDisk merged to max).
    func scan() -> SteamScanResult {
        cachedGridDirs = nil // reset per-scan artwork cache
        var byAppID: [String: SteamAppInfo] = [:]
        var skipped = 0

        let folders = steamAppsFolders()
        for folder in folders {
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                if let info = parseManifest(at: file) {
                    if let existing = byAppID[info.appID] {
                        byAppID[info.appID] = merge(existing, info)
                    } else {
                        byAppID[info.appID] = info
                    }
                } else {
                    skipped += 1
                }
            }
        }

        let games = byAppID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return SteamScanResult(games: games, foldersScanned: folders.count, skippedManifests: skipped)
    }

    /// Convenience wrapper over `scan()` for call sites that don't need
    /// diagnostics.
    func installedGames() -> [SteamAppInfo] {
        scan().games
    }

    private func parseManifest(at url: URL) -> SteamAppInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let value = VDFParser.parse(text),
              let appState = value["AppState"]?.dict,
              let appID = appState["appid"]?.string,
              let name = appState["name"]?.string else {
            Log.warn("SteamLibrary: skipping unparseable manifest \(url.lastPathComponent)")
            return nil
        }

        // StateFlags gate (scout report §3.3/§6.2): bit 0x4 = installed/ready.
        // bit 0x2 = uninstalling/needs update → still show (needsUpdate badge)
        // but only when the install bits are present at all.
        let stateFlags = Int(appState["StateFlags"]?.string ?? "0") ?? 0
        guard stateFlags & 0x4 != 0 else {
            Log.info("SteamLibrary: skipping \(name) (StateFlags=\(stateFlags)) — not installed")
            return nil
        }

        let installDir = appState["installdir"]?.string ?? ""
        let sizeOnDisk = Int64(appState["SizeOnDisk"]?.string ?? "0") ?? 0

        var lastPlayed: Date?
        if let raw = appState["LastPlayed"]?.string, let seconds = TimeInterval(raw), seconds > 0 {
            lastPlayed = Date(timeIntervalSince1970: seconds)
        }

        return SteamAppInfo(
            appID: appID,
            name: name,
            installDir: installDir,
            sizeOnDisk: sizeOnDisk,
            lastPlayed: lastPlayed,
            stateFlags: stateFlags,
            needsUpdate: stateFlags & 0x2 != 0,
            libraryPath: url.deletingLastPathComponent()
        )
    }

    private func merge(_ a: SteamAppInfo, _ b: SteamAppInfo) -> SteamAppInfo {
        SteamAppInfo(
            appID: a.appID,
            name: a.name,
            installDir: a.installDir,
            sizeOnDisk: max(a.sizeOnDisk, b.sizeOnDisk),
            lastPlayed: [a.lastPlayed, b.lastPlayed].compactMap { $0 }.max(),
            stateFlags: a.stateFlags | b.stateFlags,
            needsUpdate: a.needsUpdate || b.needsUpdate,
            libraryPath: a.libraryPath
        )
    }

    // MARK: - Artwork

    /// Local Steam grid artwork (userdata/<account>/config/grid), matching
    /// Steam's real naming scheme (scout report §5.2). Memoized per scan.
    func gridArtPath(forAppID appID: String) -> URL? {
        let candidates = [
            "\(appID).png", "\(appID).jpg", "\(appID)p.png",
            "\(appID)_hero.png", "\(appID)_hero.jpg",
            "\(appID)_header.jpg", "\(appID)c.png",
        ]
        for gridDir in gridDirs() {
            for candidate in candidates {
                let url = gridDir.appendingPathComponent(candidate)
                if fileManager.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private func gridDirs() -> [URL] {
        if let cached = cachedGridDirs { return cached }
        guard let root = steamRoot() else { return [] }
        let gridRoot = root.appendingPathComponent("userdata", isDirectory: true)
        var dirs: [URL] = []
        if let users = try? fileManager.contentsOfDirectory(at: gridRoot, includingPropertiesForKeys: nil) {
            for user in users where user.hasDirectoryPath {
                dirs.append(user.appendingPathComponent("config/grid", isDirectory: true))
            }
        }
        cachedGridDirs = dirs
        return dirs
    }

    /// Steam CDN header art (needs network; the loader falls back gracefully).
    static func remoteHeaderURL(forAppID appID: String) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    /// Converts Steam install metadata into frontend game entries.
    func gameEntries() -> [GameEntry] {
        scan().games.map { info in
            GameEntry(
                id: "steam-\(info.appID)",
                title: info.name,
                source: .steam,
                romPath: nil,
                appID: info.appID,
                artworkLocalPath: gridArtPath(forAppID: info.appID)?.path,
                artworkRemoteURL: SteamLibrary.remoteHeaderURL(forAppID: info.appID),
                lastPlayed: info.lastPlayed
            )
        }
    }
}
