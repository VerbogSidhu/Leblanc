import Foundation
import GameController

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

// MARK: - --diagnose-input

/// Prints connected GameController devices + their button inventory, plus the
/// raw HID device/element summary. Needs a live run loop to observe
/// GameController notifications, so we spin the main run loop briefly.
enum CLIDiagnoseInput {
    static func run() -> Bool {
        // Spin the main run loop so GCController notifications can arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            finish()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        return true
    }

    private static func finish() {
        Log.cliPrint("GameController devices:")
        let controllers = GCController.controllers()
        if controllers.isEmpty {
            Log.cliPrint("  (none connected)")
        }
        for controller in controllers {
            Log.cliPrint("  \(controller.productCategory) — extended: \(controller.extendedGamepad != nil)")
            let buttons = controller.physicalInputProfile.buttons
            Log.cliPrint("    buttons: \(buttons.keys.sorted().joined(separator: ", "))")
        }
        Log.cliPrint("")
        Log.cliPrint("Raw HID gamepads:")
        Log.cliPrint(GlobalHIDMonitor.shared.describeDevices())
    }
}
