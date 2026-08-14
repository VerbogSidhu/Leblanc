import SwiftUI

/// Loads a remote image (RA avatar/badge) over URLSession with an in-memory
/// cache and a placeholder while loading. Prefix-relative RA paths are
/// resolved to the full https://retroachievements.org URL before use.
struct RemoteImage: View {
    let urlString: String?
    var contentMode: ContentMode = .fit

    @State private var image: NSImage?
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

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
    }

    private func load() {
        guard let urlString, let url = resolvedURL(urlString) else { return }
        Self.lock.lock()
        if let cached = Self.cache[urlString] {
            Self.lock.unlock()
            image = cached
            return
        }
        Self.lock.unlock()

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            Self.lock.lock()
            Self.cache[urlString] = img
            Self.lock.unlock()
            DispatchQueue.main.async { image = img }
        }.resume()
    }

    private func resolvedURL(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        if s.hasPrefix("/") { return URL(string: "https://retroachievements.org" + s) }
        return URL(string: "https://retroachievements.org/" + s)
    }
}
