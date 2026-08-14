import Foundation

/// A game discovered in a Steam library folder (from an appmanifest_*.acf).
struct SteamAppInfo {
    let appID: String
    let name: String
    let installDir: String
    let sizeOnDisk: Int64
    let lastPlayed: Date?
    /// Absolute path to the steamapps folder that contains this app.
    let libraryPath: URL
}

/// Scans Steam's install by parsing `libraryfolders.vdf` and every
/// `appmanifest_*.acf`. Steam stays a closed client — we only read its
/// metadata and launch games via the `steam://run/<appid>` URL scheme.
final class SteamLibrary {
    static let defaultSteamPath = "~/Library/Application Support/Steam"
    static let steamBundleID = "com.valvesoftware.steam"

    private let fileManager = FileManager.default

    /// Resolves Steam's base install directory.
    func steamRoot() -> URL? {
        let expanded = (SteamLibrary.defaultSteamPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// All steamapps folders: the default one plus any extra mount points
    /// declared in libraryfolders.vdf.
    func steamAppsFolders() -> [URL] {
        guard let root = steamRoot() else { return [] }
        var folders = [root.appendingPathComponent("steamapps", isDirectory: true)]

        let vdfURL = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: vdfURL, encoding: .utf8),
              let value = VDFParser.parse(text),
              let libs = value.dict else {
            return folders
        }

        // libraryfolders.vdf maps "0".."N" -> { "path": "...", ... }
        for key in 0...64 where libs[String(key)] != nil {
            if let path = libs[String(key)]?["path"]?.string {
                folders.append(URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("steamapps", isDirectory: true))
            }
        }
        return Array(Set(folders)).sorted { $0.path < $1.path }
    }

    /// Parses every appmanifest_*.acf across all library folders.
    func installedGames() -> [SteamAppInfo] {
        var games: [SteamAppInfo] = []
        for folder in steamAppsFolders() {
            guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                if let info = parseManifest(at: file) {
                    games.append(info)
                }
            }
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
            libraryPath: url.deletingLastPathComponent()
        )
    }

    /// Local Steam grid artwork (custom art the user set in the Steam UI).
    /// Prefers the landscape grid image (<appid>.png), falls back to portrait.
    func gridArtPath(forAppID appID: String) -> URL? {
        guard let root = steamRoot() else { return nil }
        let gridDir = root.appendingPathComponent("userdata", isDirectory: true)
        guard let userDirs = try? fileManager.contentsOfDirectory(at: gridDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for userDir in userDirs where userDir.hasDirectoryPath {
            let config = userDir.appendingPathComponent("config/grid", isDirectory: true)
            for candidate in ["\(appID).png", "\(appID).jpg", "\(appID)p.png"] {
                let url = config.appendingPathComponent(candidate)
                if fileManager.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Steam CDN header art (needs network; the loader falls back gracefully).
    static func remoteHeaderURL(forAppID appID: String) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")
    }

    /// Converts Steam install metadata into frontend game entries.
    func gameEntries() -> [GameEntry] {
        installedGames().map { info in
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
