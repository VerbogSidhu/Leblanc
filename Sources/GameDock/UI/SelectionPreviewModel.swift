import Combine
import Foundation

/// State for the selection preview panel (the rotating screenshot / playtime
/// box to the right of the XMB's selected item).
///
/// Behavior contract (see the feature plan):
///   • Debounced: a selection change only starts work after the selection has
///     *settled* (~350 ms), so scrolling through a long list never fires a
///     network request (Steam screenshots) or a cache lookup per item passed
///     over — and the panel doesn't flicker mid-scroll.
///   • Steam: real screenshots from the storefront endpoint, cached locally,
///     with the existing banner/box art as fallback (never empty).
///   • PSP/DS: the user's own captures (`~/Pictures/Leblanc Captures/`) when
///     they exist, box art otherwise, and the standard art placeholder when
///     neither exists (the view renders ArtworkView when `imageSources` is
///     empty).
///   • Playtime: Steam → `localconfig.vdf` (minutes); emulators → Leblanc's
///     own session tracking (RecentsStore, seconds).
///
/// All published state is mutated on the main queue. `select` is called from
/// the XMB view on selection change.
final class SelectionPreviewModel: ObservableObject {
    enum ImageSource: Hashable {
        case remote(URL)
        case local(URL)

        var cacheKey: String {
            switch self {
            case .remote(let url): return url.absoluteString
            case .local(let url): return "local:\(url.path)"
            }
        }
    }

    @Published private(set) var entryID: String?
    /// Rotating image sources for the current entry (empty → view falls back
    /// to the standard art/placeholder via ArtworkView).
    @Published private(set) var imageSources: [ImageSource] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var playtimeText: String?
    /// True while debouncing or fetching; the panel shows a quiet loading
    /// state instead of swapping content mid-scroll.
    @Published private(set) var isLoading = false

    private let recents: RecentsStore
    private let screenshots = SteamScreenshotStore.shared
    private let steamPlaytime = SteamLocalConfigReader.shared
    private let captures = CaptureStore.shared

    /// Selection-settle delay (ms) before any work starts.
    private let debounceNanoseconds: UInt64 = 350_000_000
    /// Rotation interval for multi-image previews.
    private let rotationNanoseconds: UInt64 = 3_000_000_000
    private static let maxImages = 5

    private var debounceTask: Task<Void, Never>?
    private var rotateTask: Task<Void, Never>?
    /// Bumped on every selection; stale async work checks it before applying.
    private var generation = 0

    init(recents: RecentsStore) {
        self.recents = recents
    }

    /// Called on XMB selection change (main thread). A nil entry (non-game
    /// items) hides the panel.
    func select(_ entry: GameEntry?) {
        debounceTask?.cancel()
        rotateTask?.cancel()
        debounceTask = nil
        rotateTask = nil

        guard let entry else {
            clearNow()
            return
        }

        generation += 1
        let gen = generation

        // Reflect the new selection immediately so the panel never shows a
        // stale game's screenshots; content is populated after the debounce.
        entryID = entry.id
        imageSources = []
        currentIndex = 0
        playtimeText = nil
        isLoading = true

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.debounceNanoseconds ?? 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.populate(entry: entry, generation: gen)
        }
    }

    // MARK: - Population

    private func populate(entry: GameEntry, generation gen: Int) async {
        let images: [ImageSource]
        let playtime: String?

        switch entry.source {
        case .steam:
            guard let appID = entry.appID else {
                await apply(gen, images: [], playtime: nil)
                return
            }
            let urls = await screenshots.screenshotURLs(for: appID)
            images = urls.prefix(Self.maxImages).map { .remote($0) }
            let minutes = steamPlaytime.playtimeMinutes(appID: appID)
            playtime = minutes.flatMap { $0 > 0 ? PlaytimeFormatter.minutes($0) : nil }

        case .psp, .ds:
            let found = captures.captures(for: entry.title)
            images = found.map { .local($0) }
            let seconds = recents.totalPlaytime(for: entry.id)
            playtime = seconds >= 60 ? PlaytimeFormatter.seconds(seconds) : nil
        }

        await apply(gen, images: images, playtime: playtime)
    }

    /// Applies the result on the main queue only if it's still the current
    /// selection (a newer selection invalidates stale fetches).
    private func apply(_ gen: Int, images: [ImageSource], playtime: String?) async {
        await MainActor.run { [weak self] in
            guard let self, gen == self.generation else { return }
            self.imageSources = images
            self.currentIndex = 0
            self.playtimeText = playtime
            self.isLoading = false
            self.startRotation()
        }
    }

    // MARK: - Rotation

    private func startRotation() {
        rotateTask?.cancel()
        rotateTask = nil
        guard imageSources.count > 1 else { return }
        rotateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.rotationNanoseconds ?? 3_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.imageSources.count > 1 else { return }
                    self.currentIndex = (self.currentIndex + 1) % self.imageSources.count
                }
            }
        }
    }

    private func clearNow() {
        entryID = nil
        imageSources = []
        currentIndex = 0
        playtimeText = nil
        isLoading = false
    }
}
