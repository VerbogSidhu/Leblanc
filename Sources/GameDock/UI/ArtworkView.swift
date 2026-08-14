import SwiftUI

/// Art style: `.banner` (wide landscape) or `.cover` (portrait capsule).
/// Both fill their frame — never `.fit`, which letterboxes in a mismatched
/// frame. Missing art gets a typographic placeholder tinted with the
/// platform's accent.
enum ArtworkStyle { case banner, cover }

struct ArtworkView: View {
    @ObservedObject private var loader = ArtworkLoader.shared
    let entry: GameEntry
    var style: ArtworkStyle = .banner

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill) // clip, never letterbox
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear(perform: load)
        .onChange(of: entry.id) { _, _ in
            // The same view instance may be reused for a different game;
            // drop the stale cached cover.
            image = nil
            load()
        }
        .onReceive(loader.$loadedKeys) { keys in
            if keys.contains(entry.id) { load() }
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.accent(for: entry.source).opacity(0.16)
            Text(ArtworkPlaceholder.initials(for: entry.title))
                .font(GameDockFonts.display(30, weight: .semibold))
                .foregroundStyle(Theme.paper.opacity(0.55))
        }
    }

    private func load() {
        if image == nil {
            image = style == .banner ? loader.banner(for: entry) : loader.cover(for: entry)
        }
    }
}
