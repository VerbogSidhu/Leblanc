import Foundation

/// Finds a libretro core dylib for a system. Search order:
///   1. User override (Settings → Cores)
///   2. GameDock's own cores dir (~/Library/Application Support/GameDock/cores)
///   3. RetroArch's cores dir (~/Library/Application Support/RetroArch/cores)
///   4. Fuzzy name match (*.dylib containing the core prefix) in the above dirs
enum CoreLocator {
    static func resolveCorePath(for source: GameSource, settings: SettingsStore) -> String? {
        let fileManager = FileManager.default

        if let override = settings.coreOverrides[source] {
            if fileManager.fileExists(atPath: override) {
                return override
            }
            Log.warn("CoreLocator: override missing — \(override)")
        }

        let name = source.defaultCoreFileName
        let searchDirs = [AppPaths.coresDir, retroArchCoresDir()]

        for dir in searchDirs {
            let direct = dir.appendingPathComponent(name)
            if fileManager.fileExists(atPath: direct.path) {
                Log.info("CoreLocator: \(source.rawValue) → \(direct.path)")
                return direct.path
            }
        }

        // Fuzzy fallback: any dylib under those dirs that mentions the core.
        // Rank deterministically so e.g. melondsds can't hijack a melonds
        // lookup: exact "<prefix>_libretro.dylib" first, then shortest name,
        // then lexicographic.
        let prefix = String(name.split(separator: "_").first ?? "")
        var candidates: [URL] = []
        for dir in searchDirs {
            if let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                candidates.append(contentsOf: files.filter {
                    $0.pathExtension == "dylib" && $0.lastPathComponent.contains(prefix)
                })
            }
        }

        let exactName = "\(prefix)_libretro.dylib"
        let ranked = candidates.sorted { lhs, rhs in
            let lName = lhs.lastPathComponent
            let rName = rhs.lastPathComponent
            if (lName == exactName) != (rName == exactName) { return lName == exactName }
            if lName.count != rName.count { return lName.count < rName.count }
            return lName < rName
        }
        if let best = ranked.first {
            Log.info("CoreLocator: \(source.rawValue) → \(best.path) (fuzzy)")
            return best.path
        }

        Log.warn("CoreLocator: no core found for \(source.rawValue) — searched \(searchDirs.map(\.path).joined(separator: ", "))")
        return nil
    }

    private static func retroArchCoresDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RetroArch/cores", isDirectory: true)
    }
}
