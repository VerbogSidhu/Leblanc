import AppKit
import Combine
import Foundation

/// Loads game artwork with memory + disk cache, local thumbnail collection,
/// and remote CDN fallback.
///
/// Two distinct kinds, so a portrait cover is never a stretched landscape
/// banner and vice versa:
///   • `.banner` — wide landscape (Steam header art; PSP/DS in-game snaps).
///   • `.cover`  — portrait capsule (Steam `library_600x900.jpg` capsule;
///     PSP/DS box art). The XMB selected-item frame uses covers.
final class ArtworkLoader: ObservableObject {
    enum Kind { case banner, cover }

    static let shared = ArtworkLoader()

    /// Keys whose artwork finished loading (drives SwiftUI refresh).
    @Published private(set) var loadedKeys: Set<String> = []

    private var cache: [String: NSImage] = [:]
    /// Insertion/access order for LRU eviction. `cache` is capped at
    /// `maxCacheEntries` to keep decode memory bounded (a few hundred games ×
    /// ~1 MB decoded each would otherwise grow unbounded).
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 200
    /// Dated failure tombstones (key → when it last failed). Transient CDN
    /// blips don't permanently block art: after `failedRetryInterval` a load
    /// retries the fetch.
    private var failed: [String: Date] = [:]
    private let failedRetryInterval: TimeInterval = 60
    /// Keys with a fetch currently in flight (all mutations on the main thread
    /// — the completion hops to main before touching it).
    private var inflight: Set<String> = []
    /// Background queue for decoding local/disk artwork. NSImage decode is
    /// CPU-heavy; doing it in SwiftUI body evaluation janks the XMB on cold
    /// caches (memory cache stays a synchronous fast path). Concurrent with
    /// a semaphore cap of 4 to parallelize cold-boot decoding (200 games
    /// × ~5ms each = ~250ms concurrent vs ~1s serial).
    private let decodeQueue = DispatchQueue(label: "com.leblanc.artwork.decode", qos: .utility, attributes: .concurrent)
    private let decodeSemaphore = DispatchSemaphore(value: 4)
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {
        try? AppPaths.ensureDirectories()
    }

    // MARK: - Public

    func banner(for entry: GameEntry) -> NSImage? { load(entry, kind: .banner, fallback: nil) }

    func cover(for entry: GameEntry) -> NSImage? { load(entry, kind: .cover, fallback: .banner) }

    /// Triggers background loads for banner + cover art for the given entries.
    /// Called at launch with recently-played games so the art is in the memory
    /// cache by the time the user scrolls to them. Each call returns nil
    /// immediately (async fetch); the image lands in cache when the fetch
    /// completes, and ArtworkView picks it up via `loadedKeys`.
    func prewarm(entries: [GameEntry]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for entry in entries {
                _ = self?.banner(for: entry)
                _ = self?.cover(for: entry)
            }
        }
    }

    // MARK: - Resolution

    private func load(_ entry: GameEntry, kind: Kind, fallback: Kind?) -> NSImage? {
        let key = "\(kind == .banner ? "banner" : "cover")-\(entry.id)"
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        // Recent failure tombstone: back off, then allow a retry.
        if let failedAt = failed[key], Date().timeIntervalSince(failedAt) < failedRetryInterval {
            return nil
        }
        failed.removeValue(forKey: key) // stale tombstone → retry

        // 1) Already in the disk cache → decode off main, publish when ready.
        let cacheURL = diskCacheURL(for: key)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            decodeOffMain(url: cacheURL, cacheKey: key, entryID: entry.id)
            return nil
        }
        // 2) Local art (RetroArch thumbnails / Steam grid) → decode off main
        //    and populate the disk cache so the next visit is a cache hit.
        if let local = localPath(for: entry, kind: kind),
           FileManager.default.fileExists(atPath: local) {
            decodeOffMain(url: URL(fileURLWithPath: local), cacheKey: key, entryID: entry.id, copyToDiskCache: cacheURL)
            return nil
        }
        // 3) Remote (CDN / Steam capsule) — a fetch is starting (or already in
        //    flight). Do NOT tombstone the key here — the completion either
        //    succeeds (store clears it) or fails (marks a dated tombstone).
        //    Previously any transient CDN blip permanently blocked the entry
        //    for the whole session.
        if let remote = remoteURL(for: entry, kind: kind) {
            fetchRemote(remote, cacheKey: key, entryID: entry.id)
            if let fallback {
                return load(entry, kind: fallback, fallback: nil) // one level only
            }
            return nil
        }
        if let fallback {
            return load(entry, kind: fallback, fallback: nil) // one level only
        }
        // Nothing local, nothing remote, nothing to fall back to — permanent miss.
        failed[key] = Date()
        return nil
    }

    /// Decodes a local/disk image off the main thread, then publishes via
    /// `loadedKeys` (the view re-evaluates and picks it up from the cache).
    private func decodeOffMain(url: URL, cacheKey: String, entryID: String, copyToDiskCache: URL? = nil) {
        guard !inflight.contains(cacheKey) else { return }
        inflight.insert(cacheKey)

        decodeQueue.async { [weak self] in
            self?.decodeSemaphore.wait()
            let img = NSImage(contentsOfFile: url.path)
            self?.decodeSemaphore.signal()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(cacheKey)
                guard let img else {
                    Log.debug("artwork \(entryID): failed to decode \(url.lastPathComponent)")
                    self.failed[cacheKey] = Date()
                    return
                }
                if let copyToDiskCache, !FileManager.default.fileExists(atPath: copyToDiskCache.path) {
                    try? FileManager.default.copyItem(at: url, to: copyToDiskCache)
                }
                self.store(cacheKey, img)
                self.loadedKeys.insert(entryID)
            }
        }
    }

    private func localPath(for entry: GameEntry, kind: Kind) -> String? {
        switch (entry.source, kind) {
        case (.steam, .banner):
            guard let path = entry.artworkLocalPath,
                  let img = NSImage(contentsOfFile: path),
                  img.size.width > img.size.height else { return nil }
            return path
        case (.steam, .cover):
            return nil // no reliable local portrait capsule for Steam
        case (.psp, .banner), (.ds, .banner):
            return thumbnailPath(system: thumbnailSystemName(for: entry.source), subdir: "Named_Snaps", artKey: entry.artKey)
        case (.psp, .cover), (.ds, .cover):
            return thumbnailPath(system: thumbnailSystemName(for: entry.source), subdir: "Named_Boxarts", artKey: entry.artKey)
        }
    }

    private func remoteURL(for entry: GameEntry, kind: Kind) -> URL? {
        switch (entry.source, kind) {
        case (.steam, .banner):
            return entry.artworkRemoteURL // header.jpg (460x215)
        case (.steam, .cover):
            guard let appID = entry.appID else { return nil }
            // Valve's library capsule — already portrait (600x900).
            return URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/library_600x900.jpg")
        case (.psp, .banner), (.ds, .banner):
            return thumbnailCDN(system: thumbnailSystemName(for: entry.source), subdir: "Named_Snaps", artKey: entry.artKey)
        case (.psp, .cover), (.ds, .cover):
            return thumbnailCDN(system: thumbnailSystemName(for: entry.source), subdir: "Named_Boxarts", artKey: entry.artKey)
        }
    }

    // MARK: - Thumbnail collection paths

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

    private func thumbnailPath(system: String?, subdir: String, artKey: String?) -> String? {
        guard let system, let artKey else { return nil }
        return retroArchThumbnailsRoot()
            .appendingPathComponent(system)
            .appendingPathComponent(subdir)
            .appendingPathComponent("\(artKey).png")
            .path
    }

    private func thumbnailCDN(system: String?, subdir: String, artKey: String?) -> URL? {
        guard let system, let artKey else { return nil }
        let s = system.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? system
        let k = artKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artKey
        return URL(string: "https://thumbnails.libretro.com/\(s)/\(subdir)/\(k).png")
    }

    // MARK: - Cache bookkeeping

    /// Inserts an image into the memory cache, evicting the least-recently-used
    /// entry when the cap is exceeded.
    private func store(_ key: String, _ img: NSImage) {
        if cache[key] == nil {
            cacheOrder.append(key)
        }
        cache[key] = img
        failed.removeValue(forKey: key)
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Moves a cache hit to the most-recently-used end of the order.
    private func touch(_ key: String) {
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
            cacheOrder.append(key)
        }
    }

    // MARK: - Fetching

    private func fetchRemote(_ url: URL, cacheKey: String, entryID: String) {
        guard !inflight.contains(cacheKey) else { return }
        inflight.insert(cacheKey)

        session.dataTask(with: url) { [weak self] data, response, error in
            // Hop to main: inflight/cache/failed/loadedKeys are all
            // main-thread state (previously `inflight` was mutated on the
            // URLSession queue — a cross-thread Set race).
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(cacheKey)
                if let error {
                    Log.debug("artwork \(entryID): \(error.localizedDescription)")
                    self.failed[cacheKey] = Date()
                    return
                }
                guard let data, let img = NSImage(data: data) else {
                    Log.debug("artwork \(entryID): bad image data")
                    self.failed[cacheKey] = Date()
                    return
                }
                try? data.write(to: self.diskCacheURL(for: cacheKey), options: .atomic)
                self.store(cacheKey, img)
                self.loadedKeys.insert(entryID)
            }
        }.resume()
    }

    private func diskCacheURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return AppPaths.artworkDir.appendingPathComponent("\(safe).img")
    }
}
