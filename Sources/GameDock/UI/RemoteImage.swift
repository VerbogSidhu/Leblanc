import SwiftUI

/// Loads a remote image (RA avatar/badge) over URLSession with an in-memory
/// cache and a placeholder while loading. Prefix-relative RA paths are
/// resolved to the full https://retroachievements.org URL before use.
struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?
    /// NSCache auto-evicts under memory pressure (the old dictionary grew
    /// without bound) and is thread-safe on its own.
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 100
        return c
    }()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                ZStack {
                    Theme.ink
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(Theme.trophy.opacity(0.7))
                }
            }
        }
        .clipped()
        .onAppear(perform: load)
        .onChange(of: urlString) { _, _ in
            image = nil
            load()
        }
    }

    private func load() {
        guard let urlString, let url = resolvedURL(urlString) else { return }
        if let cached = Self.cache.object(forKey: urlString as NSString) {
            image = cached
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            Self.cache.setObject(img, forKey: urlString as NSString)
            DispatchQueue.main.async { image = img }
        }.resume()
    }

    private func resolvedURL(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(string: "https://retroachievements.org" + s) }
        return URL(string: "https://retroachievements.org/" + s)
    }
}
