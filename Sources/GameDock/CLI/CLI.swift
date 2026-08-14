import Foundation

// MARK: - --scan-steam

/// Dumps the parsed Steam library. Used to validate VDF/ACF parsing against
/// a real Steam install (this machine has one).
enum CLIScanSteam {
    static func run() -> Bool {
        let library = SteamLibrary()
        let folders = library.steamAppsFolders()
        Log.cliPrint("Steam root: \(library.steamRoot()?.path ?? "NOT FOUND")")
        Log.cliPrint("steamapps folders (\(folders.count)):")
        for folder in folders {
            Log.cliPrint("  \(folder.path)")
        }

        let games = library.installedGames()
        Log.cliPrint("\nInstalled games (\(games.count)):")
        for game in games {
            let played = game.lastPlayed.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "never"
            let art = library.gridArtPath(forAppID: game.appID)?.path ?? "-"
            Log.cliPrint("  [\(game.appID)] \(game.name)  (lastPlayed: \(played))  art: \(art)")
        }
        Log.cliPrint("\nScan \(games.isEmpty ? "FAILED" : "OK")")
        return !games.isEmpty
    }
}

// MARK: - --selftest (implemented in the emulator phase)

enum CLISelfTest {
    static func run() -> Bool {
        Log.cliPrint("SELFTEST not yet wired (emulator phase) — placeholder")
        return false
    }
}

// MARK: - --diagnose-input (implemented in the controller phase)

enum CLIDiagnoseInput {
    static func run() -> Bool {
        Log.cliPrint("DIAGNOSE-INPUT not yet wired (controller phase) — placeholder")
        return false
    }
}
