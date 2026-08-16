import AppKit
import SwiftUI

/// The selection preview panel: a small ink panel to the right of the XMB's
/// selected item, vertically centered against it. Contents, top to bottom:
/// a rotating image area (Steam screenshots / personal captures / box-art
/// fallback) and a playtime line.
///
/// The panel is purely additive — the vertical XMB navigation and selection
/// behavior are untouched; it is driven by the same selection state the big
/// cover art uses (through SelectionPreviewModel's debounce).
struct SelectionPreviewPanel: View {
    @ObservedObject var model: SelectionPreviewModel
    let entry: GameEntry
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelWidth: CGFloat = 300
    private var imageHeight: CGFloat { panelWidth * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            imageArea
                .frame(width: panelWidth, height: imageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(accent.opacity(model.isLoading ? 0.25 : 0.55), lineWidth: 1)
                )

            if let playtime = model.playtimeText {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                    Text(playtime + " played")
                }
                .font(GameDockFonts.data(12))
                .foregroundStyle(Theme.mist)
            }
        }
        .padding(12)
        .background(Theme.ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.mist.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18)
    }

    // MARK: - Image area

    @ViewBuilder
    private var imageArea: some View {
        ZStack {
            Theme.ink

            if model.imageSources.isEmpty {
                // Settled with no screenshots/captures → fall back to the same
                // banner/box art the library already loads (ArtworkView shows
                // the platform-tinted title placeholder when even that doesn't
                // exist — the panel is never a broken image). Not rendered
                // while loading, so scrolling past items never triggers art
                // fetches for anything but the settled selection.
                if !model.isLoading {
                    ArtworkView(entry: entry, style: .banner)
                }
            } else {
                ForEach(Array(model.imageSources.enumerated()), id: \.element) { idx, source in
                    PreviewImage(source: source)
                        .opacity(idx == model.currentIndex ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.mist)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: model.currentIndex)
    }
}

// MARK: - PreviewImage

/// Loads one preview image (remote screenshot URL or local capture file)
/// through PreviewImageLoader, filling its frame.
struct PreviewImage: View {
    let source: SelectionPreviewModel.ImageSource

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.ink
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear(perform: load)
        .onChange(of: source) { _, _ in
            image = nil
            load()
        }
    }

    private func load() {
        guard image == nil else { return }
        PreviewImageLoader.shared.image(for: source) { img in
            DispatchQueue.main.async {
                if let img { image = img }
            }
        }
    }
}

/// Small image cache for preview sources: in-memory LRU (capped), background
/// decode, remote fetch with in-flight completion fan-out (a re-request for an
/// image already loading shares the same fetch instead of duplicating it).
final class PreviewImageLoader {
    static let shared = PreviewImageLoader()

    private let lock = NSLock()
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var inflight: Set<String> = []
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private let maxEntries = 80

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Loads (or serves from cache) the image for `source`; completion runs on
    /// the main queue. On failure the completion receives nil.
    func image(for source: SelectionPreviewModel.ImageSource, completion: @escaping (NSImage?) -> Void) {
        let key = source.cacheKey

        lock.lock()
        if let img = cache[key] {
            touch(key)
            lock.unlock()
            completion(img)
            return
        }
        if inflight.contains(key) {
            pending[key, default: []].append(completion)
            lock.unlock()
            return
        }
        inflight.insert(key)
        pending[key, default: []].append(completion)
        lock.unlock()

        switch source {
        case .local(let url):
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let img = NSImage(contentsOfFile: url.path)
                self?.finish(key: key, image: img)
            }
        case .remote(let url):
            session.dataTask(with: url) { [weak self] data, _, _ in
                let img = data.flatMap { NSImage(data: $0) }
                self?.finish(key: key, image: img)
            }.resume()
        }
    }

    /// Delivers to every waiter for `key` on the main queue.
    private func finish(key: String, image: NSImage?) {
        lock.lock()
        inflight.remove(key)
        let waiters = pending.removeValue(forKey: key) ?? []
        if let image {
            storeLocked(key, image)
        }
        lock.unlock()

        DispatchQueue.main.async {
            for waiter in waiters { waiter(image) }
        }
    }

    // MARK: - LRU bookkeeping (call under lock)

    private func storeLocked(_ key: String, _ img: NSImage) {
        if cache[key] == nil { order.append(key) }
        cache[key] = img
        while order.count > maxEntries {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }
}
