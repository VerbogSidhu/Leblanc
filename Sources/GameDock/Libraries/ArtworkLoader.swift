import AppKit
import Combine
import Foundation

/// Loads game artwork with a three-tier strategy:
///   1. memory cache
///   2. local Steam grid art (`artworkLocalPath`) or on-disk artwork cache
///   3. async download of the remote URL (Steam CDN header.jpg) → disk cache
/// Missing artwork yields nil → the UI falls back to a gradient placeholder.
final class ArtworkLoader: ObservableObject {
    static let shared = ArtworkLoader()

    /// Keys whose artwork finished loading (drives SwiftUI refresh).
    @Published private(set) var loadedKeys: Set<String> = []

    private var memory: [String: NSImage] = [:]
    private var inflight: Set<String> = []
    private let fileManager = FileManager.default
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {
        try? AppPaths.ensureDirectories()
    }

    /// Synchronous lookup; kicks off an async remote fetch when needed.
    func image(for entry: GameEntry) -> NSImage? {
        if let cached = memory[entry.id] { return cached }

        // Local Steam grid art (Steam userdata).
        if let localPath = entry.artworkLocalPath, let img = NSImage(contentsOfFile: localPath) {
            memory[entry.id] = img
            return img
        }

        // On-disk cache of a previously downloaded image.
        let cacheURL = diskCacheURL(for: entry.id)
        if let img = NSImage(contentsOfFile: cacheURL.path) {
            memory[entry.id] = img
            return img
        }

        // Local RetroArch thumbnail collection (Named_Boxarts), if present.
        // Used as a read-only art source — GameDock never launches RetroArch.
        if let artKey = entry.artKey,
           let system = thumbnailSystemName(for: entry.source),
           let img = NSImage(contentsOfFile: retroArchThumbnailPath(system: system, artKey: artKey)) {
            memory[entry.id] = img
            return img
        }

        // Remote: libretro thumbnails CDN for ROMs, Steam CDN for Steam games.
        if let artKey = entry.artKey, let system = thumbnailSystemName(for: entry.source),
           let url = cdnURL(system: system, artKey: artKey) {
            fetchRemote(url, entryID: entry.id)
        } else if let remote = entry.artworkRemoteURL {
            fetchRemote(remote, entryID: entry.id)
        }
        return nil
    }

    private func fetchRemote(_ url: URL, entryID: String) {
        guard !inflight.contains(entryID) else { return }
        inflight.insert(entryID)

        session.dataTask(with: url) { [weak self] data, response, error in
            defer { self?.inflight.remove(entryID) }
            guard let self else { return }
            if let error { Log.debug("artwork \(entryID): \(error.localizedDescription)"); return }
            guard let data, let img = NSImage(data: data) else {
                Log.debug("artwork \(entryID): bad image data")
                return
            }
            try? data.write(to: self.diskCacheURL(for: entryID), options: .atomic)
            DispatchQueue.main.async {
                self.memory[entryID] = img
                self.loadedKeys.insert(entryID)
            }
        }.resume()
    }

    private func diskCacheURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return AppPaths.artworkDir.appendingPathComponent("\(safe).img")
    }

    // MARK: - RetroArch thumbnail collection (read-only art source)

    /// System folder name used by the RetroArch thumbnail collection and CDN.
    private func thumbnailSystemName(for source: GameSource) -> String? {
        switch source {
        case .steam: return nil
        case .psp: return "Sony - PlayStation Portable"
        case .ds: return "Nintendo - Nintendo DS"
        }
    }

    private func retroArchThumbnailsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RetroArch/thumbnails", isDirectory: true)
    }

    private func retroArchThumbnailPath(system: String, artKey: String) -> String {
        retroArchThumbnailsRoot()
            .appendingPathComponent(system)
            .appendingPathComponent("Named_Boxarts")
            .appendingPathComponent("\(artKey).png")
            .path
    }

    /// thumbnails.libretro.com CDN URL (offline fallback is the placeholder).
    private func cdnURL(system: String, artKey: String) -> URL? {
        let systemEncoded = system.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? system
        let keyEncoded = artKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artKey
        return URL(string: "https://thumbnails.libretro.com/\(systemEncoded)/Named_Boxarts/\(keyEncoded).png")
    }
}
