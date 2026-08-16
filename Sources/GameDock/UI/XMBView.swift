import SwiftUI

/// The XMB shell: a horizontal category rail, and under it a horizontal bar of
/// items — the selected item large and centered, its neighbors smaller and
/// dimmed to the left/right. Left/right walks categories; up/down walks the
/// item bar (which slides, the newly-selected growing into place). The ambient
/// wave field fills the whole frame behind everything.
struct XMBView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: XMBNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var coverNS
    @State private var booted = false

    var body: some View {
        ZStack {
            WaveField(model: env.waveField, accent: nav.currentCategory?.accent ?? Theme.signal)

            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Spacer()
                    // Console-shell readout: a small mono clock beside the hints.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(GameDockFonts.data(12))
                            .foregroundStyle(Theme.mist)
                    }
                    ControllerHints()
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)

                categoryRail
                    .padding(.top, 26)

                itemBar
                    .padding(.top, 52)   // pulled up close to the rail

                Spacer(minLength: 0)
            }
            .opacity(booted ? 1 : 0)

            // Grounding: a subtle darkening toward the bottom so the content
            // sits on a surface rather than floating in void.
            LinearGradient(
                colors: [.clear, Theme.void.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 220)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
        .background(Theme.void.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { booted = true }
        }
        .onChange(of: nav.selectedItem) { _, item in
            // The selection preview panel is driven by the same selection
            // state that updates the big cover art — no separate interaction.
            env.preview.select(item?.entry)
        }
        .onDisappear {
            // XMB gone (emulator launch / app switch): stop debounce + rotation.
            env.preview.clear()
        }
    }

    // MARK: - Category rail

    private var categoryRail: some View {
        HStack(spacing: 42) {
            ForEach(Array(nav.categories.enumerated()), id: \.element.id) { idx, cat in
                categoryButton(cat, index: idx)
            }
        }
        .animation(reduceMotion ? nil : Theme.spring, value: nav.categoryIndex)
    }

    private func categoryButton(_ cat: XMBNavModel.Category, index: Int) -> some View {
        let selected = index == nav.categoryIndex
        // Game-library categories get a small mono item count (Home/Steam/PSP/DS).
        let showCount = ["home", "steam", "psp", "ds"].contains(cat.id) && !cat.items.isEmpty
        return Button {
            nav.jumpToCategory(at: index)
            env.selectionMoved()
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Text(cat.title)
                        .font(Theme.railLabel(selected: selected))
                        .foregroundStyle(selected ? Theme.paper : Theme.mist)
                    if showCount {
                        Text("\(cat.items.count)")
                            .font(GameDockFonts.data(12))
                            .foregroundStyle(selected ? cat.accent : Theme.mist.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(selected ? cat.accent.opacity(0.2) : Theme.ink.opacity(0.6), in: Capsule())
                    }
                }
                Rectangle()
                    .fill(selected ? cat.accent : .clear)
                    .frame(width: 36, height: 2)
                    .shadow(color: selected ? cat.accent.opacity(0.9) : .clear, radius: 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Item bar (vertical stack; neighbors peek above/below)

    @ViewBuilder
    private var itemBar: some View {
        if let cat = nav.currentCategory {
            if cat.items.isEmpty {
                emptyCategory(cat)
            } else {
                let lo = max(0, nav.itemIndex - 2)
                let hi = min(cat.items.count - 1, nav.itemIndex + 2)
                let window = (lo...hi).map { cat.items[$0] }
                VStack(spacing: 20) {
                    // Identity is the ITEM id (not the index) so a given view
                    // slot never carries a stale cover from a previous game.
                    ForEach(window, id: \.id) { item in
                        if item.id == nav.selectedItem?.id {
                            selectedItemView(item, accent: cat.accent)
                        } else {
                            neighborView(item, accent: cat.accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : Theme.spring, value: nav.itemIndex)
                .overlay(alignment: .trailing) {
                    // Selection preview panel: purely additive, sits to the
                    // right of the selected card, vertically centered.
                    if let entry = nav.selectedItem?.entry {
                        SelectionPreviewPanel(model: env.preview, entry: entry,
                                              accent: cat.accent)
                            .padding(.trailing, 40)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: nav.selectedItem?.id)
            }
        }
    }

    private func selectedItemView(_ item: XMBItem, accent: Color) -> some View {
        VStack(spacing: 16) {
            cover(for: item, size: selectedCoverSize(for: item), accent: accent, dimmed: false)
            Text(item.title)
                .font(Theme.itemTitleSelected)
                .foregroundStyle(Theme.paper)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.mist)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .transition(.opacity)
    }

    private func neighborView(_ item: XMBItem, accent: Color) -> some View {
        cover(for: item, size: 72, accent: accent, dimmed: true)
    }

    /// Caps the selected cover's height (scaling width to preserve aspect) so
    /// the item stack can't push the title off-screen on shorter windows.
    private func selectedCoverSize(for item: XMBItem) -> CGFloat {
        guard item.kind == .game || item.kind == .action else { return 220 }
        return min(Theme.itemCoverWidth, Self.selectedCoverMaxHeight * Theme.itemCoverAspect)
    }

    private static let selectedCoverMaxHeight: CGFloat = 360

    /// One cover for every item kind: portrait for games/actions (matches the
    /// item-bar silhouette), square for RA hub entries (avatars/badges).
    @ViewBuilder
    private func cover(for item: XMBItem, size: CGFloat, accent: Color, dimmed: Bool) -> some View {
        let portrait = item.kind == .game || item.kind == .action
        let height = portrait ? size / Theme.itemCoverAspect : size
        Group {
            switch item.kind {
            case .game:
                if let entry = item.entry { ArtworkView(entry: entry, style: .cover) }
            case .action:
                ZStack {
                    Theme.ink
                    Image(systemName: glyph(for: item))
                        .font(.system(size: size * 0.16, weight: .semibold))
                        .foregroundStyle(accent)
                }
            case .profile:
                RemoteImage(urlString: item.profile?.userPic)
            case .unlock:
                RemoteImage(urlString: item.unlock?.badgeURL)
            case .completion:
                RemoteImage(urlString: item.completion?.imageIcon)
            case .refresh:
                ZStack {
                    Theme.ink
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: size * 0.2, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(width: size, height: height)
        .clipShape(RoundedRectangle(cornerRadius: dimmed ? 6 : 10))
        .overlay(
            RoundedRectangle(cornerRadius: dimmed ? 6 : 10)
                .stroke(dimmed ? Theme.mist.opacity(0.25) : accent, lineWidth: dimmed ? 1 : 2)
        )
        .shadow(color: dimmed ? .clear : accent.opacity(0.35), radius: 26)
        .brightness(dimmed ? -0.45 : 0)
        .matchedGeometryEffect(id: "cover-\(item.id)", in: coverNS)
    }

    private func glyph(for item: XMBItem) -> String {
        switch item.action {
        case .discord: return "bubble.left.and.bubble.right.fill"
        case .settings: return "gearshape.fill"
        case nil: return "questionmark"
        }
    }

    private func emptyCategory(_ cat: XMBNavModel.Category) -> some View {
        VStack(spacing: 10) {
            Text(cat.title)
                .font(Theme.railLabel(selected: true))
                .foregroundStyle(Theme.paper)
            Text(cat.id == "home"
                 ? "Nothing played yet — launch a game from Steam, PSP or DS."
                 : "No \(cat.title) games found. Add ROMs or change the folder in Settings.")
                .font(Theme.body)
                .foregroundStyle(Theme.mist)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(.horizontal, 40)
    }
}

/// Persistent PS / Share glyph hints — unmistakable PlayStation iconography.
struct ControllerHints: View {
    var body: some View {
        HStack(spacing: 12) {
            // PS button: the "PS" wordmark in a button outline.
            Text("PS")
                .font(GameDockFonts.display(15, weight: .bold))
                .foregroundStyle(Theme.paper)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.paper.opacity(0.7), lineWidth: 1.5))

            // Share button: the share glyph in a button outline.
            Image(systemName: "square.and.arrow.up.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.paper.opacity(0.7), lineWidth: 1.5))
        }
        .opacity(0.85)
    }
}
