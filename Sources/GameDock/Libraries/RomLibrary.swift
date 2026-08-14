import Foundation

/// Scans user-configured ROM folders for a given system and turns files into
/// frontend entries. Box art is a stretch goal — v1 uses placeholder art.
final class RomLibrary {
    private let fileManager = FileManager.default

    /// Recursively scans `folder` for files with the given extensions.
    /// Skips hidden files/dirs and symlink loops (enumerator handles cycles).
    func scan(folder: URL, extensions: Set<String>, source: GameSource) -> [GameEntry] {
        guard fileManager.fileExists(atPath: folder.path) else { return [] }

        var entries: [GameEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .fileSizeKey]

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            Log.warn("RomLibrary: cannot enumerate \(folder.path)")
            return []
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            let title = url.deletingPathExtension().lastPathComponent
            entries.append(GameEntry(
                id: GameEntry.romID(source: source, path: url.path),
                title: title,
                source: source,
                romPath: url.path,
                appID: nil,
                artworkLocalPath: nil,
                artworkRemoteURL: nil,
                lastPlayed: nil
            ))
        }

        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
