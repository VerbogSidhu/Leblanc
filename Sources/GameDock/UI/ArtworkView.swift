import SwiftUI

/// Art style: `.banner` (wide landscape, fills its box) or `.cover`
/// (portrait box art, fitted). The XMB uses covers; banners elsewhere.
enum ArtworkStyle { case banner, cover }

/// Game artwork with a placeholder for missing art.
struct ArtworkView: View {
    @ObservedObject private var loader = ArtworkLoader.shared
    let entry: GameEntry
    var style: ArtworkStyle = .banner

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Theme.ink
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: style == .banner ? .fill : .fit)
                    .transition(.opacity)
            } else {
                ArtworkPlaceholder.gradient(for: entry.title)
                Text(ArtworkPlaceholder.initials(for: entry.title))
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear(perform: load)
        .onReceive(loader.$loadedKeys) { keys in
            if keys.contains(entry.id) { load() }
        }
    }

    private func load() {
        if image == nil {
            image = style == .banner ? loader.banner(for: entry) : loader.image(for: entry)
        }
    }
}
