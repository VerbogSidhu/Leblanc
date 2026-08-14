import SwiftUI

/// Game artwork with a gradient+initials placeholder while loading/missing.
struct ArtworkView: View {
    @ObservedObject private var loader = ArtworkLoader.shared
    let entry: GameEntry

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            ArtworkPlaceholder.gradient(for: entry.title)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Text(ArtworkPlaceholder.initials(for: entry.title))
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
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
            image = loader.image(for: entry)
        }
    }
}
