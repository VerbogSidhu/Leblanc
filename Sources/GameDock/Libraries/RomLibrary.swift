import Foundation

/// Scans user-configured ROM folders for a given system and turns files into
/// frontend entries. Box art is a stretch goal — v1 uses placeholder art.
final class RomLibrary {
    private let fileManager = FileManager.default

    /// Recursively scans `folder` for files with the given extensions.
    /// Skips hidden files/dirs. Symlink loops stay safe: the enumerator
    /// handles directory cycles, and file symlinks are only accepted when
    /// they resolve to a regular file inside the scanned root.
    func scan(folder: URL, extensions: Set<String>, source: GameSource) -> [GameEntry] {
        guard fileManager.fileExists(atPath: folder.path) else { return [] }

        var entries: [GameEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .isSymbolicLinkKey]

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            Log.warn("RomLibrary: cannot enumerate \(folder.path)")
            return []
        }

        // Symlink targets are compared against the *resolved* root so a scan
        // root that is itself behind a symlink (e.g. /tmp → /private/tmp)
        // doesn't reject every entry.
        let resolvedRoot = folder.resolvingSymlinksInPath().path
        let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"

        for case let original as URL in enumerator {
            var url = original
            var values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isSymbolicLink == true {
                // A symlinked ROM file reports isRegularFile == false and used
                // to be skipped silently. Resolve the link, require the target
                // to stay inside the scanned root (no escaping via ../), then
                // re-check that it is a regular file.
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(rootPrefix),
                      let resolvedValues = try? resolved.resourceValues(forKeys: Set(keys)),
                      resolvedValues.isRegularFile == true else { continue }
                url = resolved
                values = resolvedValues
            }

            guard values?.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            let fileName = url.lastPathComponent
            entries.append(GameEntry(
                id: GameEntry.romID(source: source, path: url.path),
                title: RomTitle.cleanedTitle(from: fileName),
                source: source,
                romPath: url.path,
                appID: nil,
                artworkLocalPath: nil,
                artworkRemoteURL: nil,
                artKey: RomTitle.artKey(from: fileName),
                lastPlayed: nil
            ))
        }

        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
