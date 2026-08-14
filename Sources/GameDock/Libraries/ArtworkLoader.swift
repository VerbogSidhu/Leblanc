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

        // Local grid art (Steam userdata).
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

        if let remote = entry.artworkRemoteURL {
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
}
