import Foundation

/// Standard on-disk locations. The app is NOT sandboxed (v1), so we use the
/// conventional ~/Library/Application Support/GameDock tree.
enum AppPaths {
    /// ~/Library/Application Support/GameDock
    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("GameDock", isDirectory: true)
    }

    static var recentsFile: URL { appSupport.appendingPathComponent("recents.json") }
    static var favoritesFile: URL { appSupport.appendingPathComponent("favorites.json") }
    static var artworkDir: URL { appSupport.appendingPathComponent("artwork", isDirectory: true) }
    static var coresDir: URL { appSupport.appendingPathComponent("cores", isDirectory: true) }
    static var savesDir: URL { appSupport.appendingPathComponent("saves", isDirectory: true) }

    static func ensureDirectories() throws {
        for dir in [appSupport, artworkDir, coresDir, savesDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
