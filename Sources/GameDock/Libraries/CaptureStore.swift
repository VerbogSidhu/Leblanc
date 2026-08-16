import Foundation

/// Locates personal screenshot captures for emulator games.
///
/// ScreenshotController saves to `~/Pictures/Leblanc Captures/` as
/// `<sanitizedTitle> <yyyy-MM-dd HH.mm.ss>.png` — this store scans that
/// directory for files whose name starts with the game's sanitized title, so
/// a PSP/DS game's own captures can rotate in the selection preview panel.
final class CaptureStore {
    static let shared = CaptureStore()

    private static let maxCaptures = 5

    /// Capture file URLs for a game title, newest first (timestamp-sorted
    /// names), capped at `maxCaptures`. Empty when the user has no captures.
    func captures(for title: String) -> [URL] {
        let safe = ScreenshotController.sanitizedTitle(title)
        let dir = ScreenshotController.directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        let matches = files.filter { file in
            file.pathExtension.lowercased() == "png" && file.lastPathComponent.hasPrefix(safe + " ")
        }
        // "Title 2025-01-01 10.00.00.png" sorts lexicographically by timestamp;
        // descending = newest first.
        return matches
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(Self.maxCaptures)
            .map { $0 }
    }
}
