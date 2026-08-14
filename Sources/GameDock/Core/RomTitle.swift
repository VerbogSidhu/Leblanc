import Foundation

/// ROM filename → display title + artwork key.
///
/// ROM files typically follow No-Intro/Redump naming:
///   "Shin Megami Tensei - Persona 2 - Innocent Sin (USA).iso"
/// The artwork key is the exact stem (with region tag) — it matches RetroArch
/// thumbnail names 1:1. The display title strips region/beta/dump tags.
enum RomTitle {
    /// Exact stem without extension — the RetroArch thumbnail lookup key.
    static func artKey(from filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    /// Human display title: strips [tags] and trailing (Region)/(Rev N)/(v1.01)
    /// parentheticals, normalizes underscores.
    static func cleanedTitle(from filename: String) -> String {
        var t = artKey(from: filename)

        // [b], [!], [h1], [T+Eng] style tags.
        t = t.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)

        // Trailing parenthetical groups: (USA), (Europe), (En,Fr,De,Es,It),
        // (Rev 1), (v1.01), (Proto), (Beta 2), ...
        while let range = t.range(of: #"\s*\([^()]*\)\s*$"#, options: .regularExpression) {
            t.removeSubrange(range)
        }
        // Embedded parentheticals that remain (e.g. "Game (2001)") are kept.

        t = t.replacingOccurrences(of: "_", with: " ")
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
