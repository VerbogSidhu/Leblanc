import Foundation

/// The three game sources the v1 frontend knows about.
enum GameSource: String, Codable, CaseIterable, Identifiable {
    case steam
    case psp
    case ds

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .psp: return "PSP"
        case .ds: return "Nintendo DS"
        }
    }

    /// ROM file extensions for this system (empty for Steam).
    var romExtensions: [String] {
        switch self {
        case .steam: return []
        case .psp: return ["cso", "iso", "pbp", "chd"]
        case .ds: return ["nds", "zip"]
        }
    }

    /// Conventional libretro core filename for this system.
    var defaultCoreFileName: String {
        switch self {
        case .steam: return ""
        case .psp: return "ppsspp_libretro.dylib"
        case .ds: return "melonds_libretro.dylib"
        }
    }
}

/// A single game entry in the frontend library.
/// One of `appID` (Steam) or `romPath` (emulator) is set, per `source`.
struct GameEntry: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let source: GameSource

    var romPath: String?
    var appID: String?
    var artworkLocalPath: String?
    var artworkRemoteURL: URL?
    var lastPlayed: Date?

    var isEmulator: Bool { source != .steam }

    /// Deterministic id for ROM entries (stable across rescans/launches —
    /// NOT Swift's randomized hashValue).
    static func romID(source: GameSource, path: String) -> String {
        let lower = path.lowercased()
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a offset basis
        for byte in lower.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "\(source.rawValue)-\(String(hash, radix: 16))"
    }
}

/// A persisted record of a recent launch (recents.json).
struct RecentLaunch: Codable, Identifiable, Equatable {
    let entryID: String
    let title: String
    let source: GameSource
    let date: Date

    var id: String { "\(entryID)-\(date.timeIntervalSince1970)" }
}
