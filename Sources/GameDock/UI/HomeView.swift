import SwiftUI

/// GameDock home — a simple, clean launcher: a top bar with platform tabs,
/// then a grid of wide banner cards. Nothing fancy: clear spacing, readable
/// titles, one accent for the focused card. L1/R1 switches platform,
/// arrows move the grid, A launches, PS opens the quick bar.
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.hairline)
            content
        }
        .background(Theme.void.ignoresSafeArea())
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Text("GameDock")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.ivory)

            Spacer()

            HStack(spacing: 4) {
                ForEach(nav.panels) { panel in
                    tabButton(panel)
                }
            }

            Spacer()

            if env.library.isScanning {
                ProgressView().controlSize(.small).tint(Theme.amber)
            } else {
                Text("\(env.library.games.count)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.ash)
            }
        }
        .padding(.horizontal, Theme.gridPadding)
        .padding(.vertical, 14)
    }

    private func tabButton(_ panel: HomeNavModel.Panel) -> some View {
        let active = nav.currentPanel?.id == panel.id
        return Button {
            env.selectPanel(panel.id)
        } label: {
            Text(panel.title.uppercased())
                .font(Theme.railLabel)
                .tracking(0.8)
                .foregroundStyle(active ? Theme.ivory : Theme.ash)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(active ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Theme.hairline : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .none : Theme.crossfade, value: active)
    }

    // MARK: - Grid

    @ViewBuilder
    private var content: some View {
        if let panel = nav.currentPanel, panel.games.isEmpty {
            emptyState(panel)
        } else {
            GeometryReader { geo in
                let columns = max(2, Int(floor((geo.size.width + Theme.cardGap) / (300 + Theme.cardGap))))
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: Theme.cardGap), count: columns),
                            spacing: Theme.rowGap
                        ) {
                            ForEach(Array((nav.currentPanel?.games ?? []).enumerated()), id: \.element.id) { idx, game in
                                GameCard(
                                    game: game,
                                    isSelected: nav.selection == idx
                                )
                                .id("card-\(idx)")
                                .onTapGesture { env.launch(game) }
                            }
                        }
                        .padding(.horizontal, Theme.gridPadding)
                        .padding(.top, 22)
                        .padding(.bottom, Theme.gridPadding)
                    }
                    .onChange(of: nav.selection) { _, newSel in
                        withAnimation(reduceMotion ? .none : Theme.crossfade) {
                            proxy.scrollTo("card-\(newSel)", anchor: .center)
                        }
                    }
                }
                .onAppear { nav.columnCount = columns }
                .onChange(of: geo.size.width) { _, _ in nav.columnCount = columns }
            }
            .id("grid-\(nav.panelIndex)") // fresh layout per panel
        }
    }

    private func emptyState(_ panel: HomeNavModel.Panel) -> some View {
        VStack(spacing: 10) {
            Text(panel.title.uppercased())
                .font(Theme.captionFont)
                .tracking(1.6)
                .foregroundStyle(Theme.ash)
            Text(panel.id == "home"
                 ? "Nothing played yet"
                 : "No \(panel.title) games")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.ivory)
            Text(panel.id == "home"
                 ? "Launch a game from Steam or PSP — it shows up here."
                 : "Add a ROM folder in Settings (PS → Settings).")
                .font(Theme.hintFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card (wide banner + title)

struct GameCard: View {
    let game: GameEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            art
            Text(game.title)
                .font(Theme.cardTitleFont)
                .foregroundStyle(isSelected ? Theme.ivory : Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }

    /// The banner slot. A blurred copy of the art fills the whole box so
    /// portrait PSP box art doesn't float as a sliver; the real art is fitted
    /// on top — full banner always visible, never cropped.
    private var art: some View {
        ZStack {
            ArtworkView(entry: game)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 12)
                .scaleEffect(1.25)
                .brightness(-0.25)

            ArtworkView(entry: game)
                .padding(6)
                .aspectRatio(contentMode: .fit)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 172)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(isSelected ? Theme.amber : Theme.hairline, lineWidth: isSelected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(isSelected ? 0.45 : 0.2), radius: isSelected ? 14 : 6, y: 4)
        .brightness(isSelected ? 0.02 : -0.10)
    }
}
