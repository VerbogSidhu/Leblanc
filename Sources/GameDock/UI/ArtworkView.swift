import SwiftUI

/// Game artwork: the FULL image is always visible (aspect-fit) on a clean
/// dark backdrop — banners are never cropped. Games without art get a
/// gradient + initials placeholder.
struct ArtworkView: View {
    @ObservedObject private var loader = ArtworkLoader.shared
    let entry: GameEntry

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Theme.panel // clean backdrop behind fitted art
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                ArtworkPlaceholder.gradient(for: entry.title)
                Text(ArtworkPlaceholder.initials(for: entry.title))
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .clipped()
        .onAppear(perform: load)
        .onReceive(loader.$loadedKeys) { keys in
            if keys.contains(entry.id) { load() }
        }
    }

    private func load() {
        if image == nil {
            image = loader.image(for: entry)
        }
    }
}
