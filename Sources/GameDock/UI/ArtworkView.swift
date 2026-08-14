import SwiftUI

/// Game artwork. Loads the game's BANNER (wide landscape: Steam header art,
/// PSP/DS in-game snaps) — covers its box edge-to-edge so it fits perfectly;
/// box art only as a fallback. Missing art gets a gradient + initials.
struct ArtworkView: View {
    @ObservedObject private var loader = ArtworkLoader.shared
    let entry: GameEntry

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Theme.panel
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                ArtworkPlaceholder.gradient(for: entry.title)
                Text(ArtworkPlaceholder.initials(for: entry.title))
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
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
            image = loader.banner(for: entry)
        }
    }
}
