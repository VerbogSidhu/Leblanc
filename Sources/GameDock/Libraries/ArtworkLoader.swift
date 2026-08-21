import AppKit
import Combine
import CoreGraphics
import Foundation

/// Loads game artwork with memory + disk cache, local thumbnail collection,
/// and remote CDN fallback. Uses `CGImageSource` thumbnails throughout for
/// fast decode — display-sized images without decoding the full source.
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
    /// `maxCacheEntries` to keep decode memory bounded.
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 200
    /// Dated failure tombstones (key → when it last failed). Transient CDN
    /// blips don't permanently block art: after `failedRetryInterval` a load
    /// retries the fetch.
    private var failed: [String: Date] = [:]
    private let failedRetryInterval: TimeInterval = 60
    /// Keys with a fetch currently in flight.
    private var inflight: Set<String> = []
    /// Background queue for thumbnail creation. CGImageSource is fast
    /// (~0.5ms per image) but we still keep a concurrent queue to avoid
    /// saturating the main thread during batch pre-warming.
    private let decodeQueue = DispatchQueue(label: "com.leblanc.artwork.decode", qos: .utility, attributes: .concurrent)
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Max pixel dimension for thumbnails. The XMB shows covers at 300pt
    /// (600px @2x) and banners at similar sizes.
    private static let thumbnailMaxSize: CGFloat = 600

    private init() {
        try? AppPaths.ensureDirectories()
    }

    // MARK: - Public

    func banner(for entry: GameEntry) -> NSImage? { load(entry, kind: .banner, fallback: nil) }

    func cover(for entry: GameEntry) -> NSImage? { load(entry, kind: .cover, fallback: .banner) }

    /// Triggers background loads for banner + cover art for the given entries.
    /// Called at launch with recently-played games so the art is in the memory
    /// cache by the time the user scrolls to them.
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

        // 1) Already in the disk cache → thumbnail off main, publish when ready.
        let cacheURL = diskCacheURL(for: key)
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            thumbnailOffMain(url: cacheURL, cacheKey: key, entryID: entry.id)
            return nil
        }
        // 2) Local art (RetroArch thumbnails / Steam grid) → thumbnail off main
        //    and populate the disk cache so the next visit is a cache hit.
        if let local = localPath(for: entry, kind: kind),
           FileManager.default.fileExists(atPath: local) {
            thumbnailOffMain(url: URL(fileURLWithPath: local), cacheKey: key, entryID: entry.id, copyToDiskCache: cacheURL)
            return nil
        }
        // 3) Remote (CDN / Steam capsule) — a fetch is starting (or already in
        //    flight). Do NOT tombstone the key here — the completion either
        //    succeeds (store clears it) or fails (marks a dated tombstone).
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

    // MARK: - CGImageSource thumbnail creation

    /// Creates a display-sized thumbnail from a file URL using CGImageSource.
    /// ~0.5ms per image vs ~5-20ms for full NSImage decode. The thumbnail is
    /// created at `thumbnailMaxSize` pixels on the longest edge, preserving
    /// aspect ratio with transforms.
    private func thumbnailOffMain(url: URL, cacheKey: String, entryID: String, copyToDiskCache: URL? = nil) {
        guard !inflight.contains(cacheKey) else { return }
        inflight.insert(cacheKey)

        decodeQueue.async { [weak self] in
            let img = Self.createThumbnail(from: url)
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

    /// Creates a thumbnail from a file URL. Returns nil on failure.
    private static func createThumbnail(from url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Creates a thumbnail from in-memory data. Returns nil on failure.
    private static func createThumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Reads image dimensions without decode. Returns nil if the file isn't
    /// a readable image.
    private static func imageDimensions(at path: String) -> (width: Int, height: Int)? {
        guard let url = URL(string: "file://\(path)") ?? URL(fileURLWithPath: path) as URL?,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return w > 0 && h > 0 ? (w, h) : nil
    }

    /// Checks if a local path is landscape (width > height) without decoding.
    private static func isLandscape(at path: String) -> Bool {
        guard let dims = imageDimensions(at: path) else { return false }
        return dims.width > dims.height
    }

    /// Checks if a local path is portrait (height ≥ width) without decoding.
    private static func isPortrait(at path: String) -> Bool {
        guard let dims = imageDimensions(at: path) else { return false }
        return dims.height > dims.width
    }

    private func localPath(for entry: GameEntry, kind: Kind) -> String? {
        switch (entry.source, kind) {
        case (.steam, .banner):
            // Check aspect ratio without full decode — CGImageSource reads
            // dimensions from the file header in ~0.1ms.
            guard let path = entry.artworkLocalPath,
                  Self.isLandscape(at: path) else { return nil }
            return path
        case (.steam, .cover):
            // Local Steam grid portrait capsule (<appid>p.png) — avoids a CDN
            // fetch for covers and fixes offline first-run art.
            guard let appID = entry.appID,
                  let path = SteamLibrary().portraitGridArtPath(forAppID: appID)?.path,
                  Self.isPortrait(at: path) else { return nil }
            return path
        case (.psp, .banner), (.ds, .banner):
            return thumbnailPath(system: thumbnailSystemName(for: entry.source), subdir: "Named_Snaps", artKey: entry.artKey)
        case (.psp, .cover), (.ds, .cover):
            return thumbnailPath(system: thumbnailSystemName(for: entry.source), subdir: "Named_Boxarts", artKey: entry.artKey)
        }
    }

    private func remoteURL(for entry: GameEntry, kind: Kind) -> URL? {
        switch (entry.source, kind) {
        case (.steam, .banner):
            if let appID = entry.appID, let gridURL = SteamGridDBStore.syncCachedURL(for: appID) {
                // Community hero/banner from GridDB disk cache — higher quality
                // than Steam header.jpg; async fetch populates cache for next load.
                return gridURL
            }
            if let appID = entry.appID, Secrets.isSteamGridDBConfigured {
                Task { _ = await SteamGridDBStore.shared.gridArtURLs(for: appID) }
            }
            return entry.artworkRemoteURL // header.jpg (460x215)
        case (.steam, .cover):
            guard let appID = entry.appID else { return nil }
            if let gridURL = SteamGridDBStore.syncCachedURL(for: appID) {
                return gridURL // portrait GridDB capsule outranks Steam CDN
            }
            if Secrets.isSteamGridDBConfigured {
                Task { _ = await SteamGridDBStore.shared.gridArtURLs(for: appID) }
            }
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
            DispatchQueue.main.async {
                guard let self else { return }
                self.inflight.remove(cacheKey)
                if let error {
                    Log.debug("artwork \(entryID): \(error.localizedDescription)")
                    self.failed[cacheKey] = Date()
                    return
                }
                guard let data else {
                    self.failed[cacheKey] = Date()
                    return
                }
                // Create thumbnail from fetched data (fast, no full decode).
                guard let img = Self.createThumbnail(from: data) else {
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
