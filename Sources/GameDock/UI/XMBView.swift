import SwiftUI

/// The XMB shell: horizontal category rail + vertical item stack, over the
/// ambient wave field. Left/right walks categories, up/down walks items.
/// The selected cover is notably larger than its dimmed neighbors — the size
/// jump is the primary "what's selected" signal, moved with a matched-geometry
/// morph so it reads as one continuous plane.
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
                HStack {
                    Spacer()
                    ControllerHints()
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)

                categoryRail
                    .padding(.top, 34)

                Spacer()

                itemStack
                    .frame(maxWidth: .infinity)

                Spacer()
            }
            .opacity(booted ? 1 : 0)
        }
        .background(Theme.void.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { booted = true }
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
        return Button {
            let delta = index - nav.categoryIndex
            if delta < 0 { nav.left() } else if delta > 0 { nav.right() }
            env.hapticTick()
        } label: {
            VStack(spacing: 6) {
                Text(cat.title)
                    .font(Theme.railLabel(selected: selected))
                    .foregroundStyle(selected ? Theme.paper : Theme.mist)
                Rectangle()
                    .fill(selected ? cat.accent : .clear)
                    .frame(width: 36, height: 2)
                    .shadow(color: selected ? cat.accent.opacity(0.9) : .clear, radius: 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Item stack (vertical window around the selection)

    @ViewBuilder
    private var itemStack: some View {
        if let cat = nav.currentCategory {
            if cat.items.isEmpty {
                emptyCategory(cat)
            } else {
                VStack(spacing: 22) {
                    ForEach(windowItems(cat.items), id: \.item.id) { entry in
                        if entry.isSelected {
                            selectedItemView(entry.item, accent: cat.accent)
                        } else {
                            neighborView(entry.item, accent: cat.accent)
                        }
                    }
                }
                .animation(reduceMotion ? nil : Theme.spring, value: nav.itemIndex)
            }
        }
    }

    private struct WindowEntry {
        let item: XMBItem
        let isSelected: Bool
    }

    private func windowItems(_ items: [XMBItem]) -> [WindowEntry] {
        let lo = max(0, nav.itemIndex - 2)
        let hi = min(items.count - 1, nav.itemIndex + 2)
        return (lo...hi).map { i in
            WindowEntry(item: items[i], isSelected: i == nav.itemIndex)
        }
    }

    private func selectedItemView(_ item: XMBItem, accent: Color) -> some View {
        VStack(spacing: 16) {
            itemCover(item, width: Theme.itemCoverWidth, accent: accent, dimmed: false)
            Text(item.title)
                .font(Theme.itemTitleSelected)
                .foregroundStyle(Theme.paper)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .transition(.opacity)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.mist)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 40)
    }

    private func neighborView(_ item: XMBItem, accent: Color) -> some View {
        itemCover(item, width: 92, accent: accent, dimmed: true)
    }

    private func itemCover(_ item: XMBItem, width: CGFloat, accent: Color, dimmed: Bool) -> some View {
        let height = width / Theme.itemCoverAspect
        return Group {
            if let entry = item.entry {
                ArtworkView(entry: entry, style: .cover)
            } else {
                ZStack {
                    Theme.ink
                    Image(systemName: glyph(for: item))
                        .font(.system(size: width * 0.16, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(width: width, height: height)
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
                 ? "Nothing played yet — launch a game from Steam or PSP."
                 : "No \(cat.title) games found. Add ROMs or change the folder in Settings.")
                .font(Theme.body)
                .foregroundStyle(Theme.mist)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(.horizontal, 40)
    }
}

/// Persistent PS / Share glyph hints — icon-first, the way console UIs do it.
struct ControllerHints: View {
    var body: some View {
        HStack(spacing: 10) {
            // PS button: △○✕□ in a rounded outline.
            VStack(spacing: 1.5) {
                HStack(spacing: 1.5) {
                    Image(systemName: "triangle.fill")
                    Image(systemName: "circle.fill")
                }
                HStack(spacing: 1.5) {
                    Image(systemName: "xmark")
                    Image(systemName: "square.fill")
                }
            }
            .font(.system(size: 5, weight: .bold))
            .foregroundStyle(Theme.mist)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.mist.opacity(0.6), lineWidth: 1))

            // Share button glyph.
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.mist)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.mist.opacity(0.6), lineWidth: 1))
        }
    }
}
