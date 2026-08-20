import SwiftUI

/// Art style: `.banner` (wide landscape) or `.cover` (portrait capsule).
/// Both fill their frame — never `.fit`, which letterboxes in a mismatched
/// frame. Missing art gets a typographic placeholder tinted with the
/// platform's accent.
enum ArtworkStyle { case banner, cover }

struct ArtworkView: View {
    @ObservedObject private var loader = ArtworkLoader.shared
    let entry: GameEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var style: ArtworkStyle = .banner

    @State private var image: NSImage?
    /// The entry the currently shown image belongs to — prevents a stale
    /// cover flashing for a different game on reuse.
    @State private var loadedForID: String?

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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: image)
        .onAppear(perform: loadIfNeeded)
        .onChange(of: entry.id) { _, _ in loadIfNeeded() }
        .onReceive(loader.$loadedKeys) { keys in
            // Re-resolve only when *this* game's art finished loading (set
            // membership check — no pointless re-load on other games' keys).
            if keys.contains(entry.id) {
                image = resolve()
            }
        }
    }

    /// Loads art for the current entry without blanking a *valid* image. If
    /// the art isn't cached yet, resolve() returns nil and the async fetch
    /// publishes via loadedKeys — placeholder shows until then (no flash).
    private func loadIfNeeded() {
        guard loadedForID != entry.id else { return }
        loadedForID = entry.id
        image = nil
        image = resolve()
    }

    private func resolve() -> NSImage? {
        let img = style == .banner ? loader.banner(for: entry) : loader.cover(for: entry)
        if img != nil { loadedForID = entry.id }
        return img
    }

    private var placeholder: some View {
        ZStack {
            Theme.accent(for: entry.source).opacity(0.16)
            Text(ArtworkPlaceholder.initials(for: entry.title))
                .font(GameDockFonts.display(30, weight: .semibold))
                .foregroundStyle(Theme.paper.opacity(0.55))
        }
    }
}
