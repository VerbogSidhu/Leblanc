import SwiftUI

/// GameDock home — Steam Big Picture energy: the selected game's art is the
/// full-bleed backdrop (crossfades as you move), a big hero panel shows the
/// current game with a PLAY button, and a horizontal row of wide tiles sits at
/// the bottom with titles overlaid on the art. L1/R1 switches platform,
/// left/right moves the tile row, A launches, PS opens the quick bar.
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var backdropZoomed = false

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                Spacer()
                panelContent
                    .id("panel-\(nav.panelIndex)")
                    .transition(slideTransition)
                Spacer(minLength: 0)
            }
        }
        .animation(reduceMotion ? Theme.crossfade : Theme.panelSlide, value: nav.panelIndex)
        .background(Theme.void.ignoresSafeArea())
        .onChange(of: nav.selectedGame?.id) { _, _ in triggerBackdropZoom() }
        .onAppear { triggerBackdropZoom() }
    }

    private func triggerBackdropZoom() {
        guard !reduceMotion else { return }
        backdropZoomed = false
        withAnimation(.easeOut(duration: 7.0)) {
            backdropZoomed = true
        }
    }

    // MARK: - Backdrop (full-bleed selected art)

    @ViewBuilder
    private var backdrop: some View {
        if let game = nav.selectedGame {
            ArtworkView(entry: game)
                .ignoresSafeArea()
                .scaleEffect(backdropZoomed ? 1.07 : 1.0)
                .overlay(Theme.void.opacity(0.34)) // dark veil: bright art recedes
                .overlay(
                    LinearGradient(
                        colors: [
                            .black.opacity(0.52),   // top bar legibility
                            .clear.opacity(0),
                            .black.opacity(0.18),
                            .black.opacity(0.80),   // tile contrast
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .id(game.id)
                .transition(.opacity)
        } else {
            Theme.void.ignoresSafeArea()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            Text("GameDock")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(Theme.ivory)
                .shadow(color: .black.opacity(0.5), radius: 4)

            Spacer()

            HStack(spacing: 22) {
                ForEach(nav.panels) { panel in
                    tabButton(panel)
                }
            }

            Spacer()

            if env.library.isScanning {
                ProgressView().controlSize(.small).tint(Theme.amber)
            } else {
                Text(String(format: "%02d", env.library.games.count))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ivory.opacity(0.7))
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 18)
    }

    private func tabButton(_ panel: HomeNavModel.Panel) -> some View {
        let active = nav.currentPanel?.id == panel.id
        return Button {
            env.selectPanel(panel.id)
        } label: {
            VStack(spacing: 5) {
                Text(panel.title.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(active ? Theme.ivory : Theme.ivory.opacity(0.55))
                    .shadow(color: .black.opacity(0.5), radius: 4)
                Rectangle()
                    .fill(active ? Theme.amber : .clear)
                    .frame(height: 3)
                    .frame(maxWidth: 34)
            }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? .none : Theme.crossfade, value: active)
    }

    // MARK: - Panel content (hero + tile row)

    @ViewBuilder
    private var panelContent: some View {
        if let panel = nav.currentPanel, panel.games.isEmpty {
            emptyState(panel)
        } else {
            hero
            tileRow
                .padding(.bottom, 18)
        }
    }

    private var slideTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch nav.slideDirection {
        case .forward:
            return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                               removal: .move(edge: .leading).combined(with: .opacity))
        case .backward:
            return .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                               removal: .move(edge: .trailing).combined(with: .opacity))
        case .none:
            return .opacity
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if let panel = nav.currentPanel, let game = nav.selectedGame ?? panel.games.first {
            // Horizontal hero on wide screens; stacks vertically on narrow ones
            // so nothing is ever cut off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 30) {
                    heroArt(game)
                    heroMeta(panel: panel, game: game)
                }
                VStack(alignment: .leading, spacing: 18) {
                    heroArt(game)
                    heroMeta(panel: panel, game: game)
                }
            }
            .padding(.horizontal, 30)
            .id("hero-\(game.id)")
        }
    }

    private func heroArt(_ game: GameEntry) -> some View {
        // The game's BANNER (wide landscape) fills the frame edge-to-edge —
        // Steam header and PSP snaps fit this aspect exactly. Width is
        // flexible so it adapts to the window.
        ArtworkView(entry: game)
            .frame(minWidth: 340, maxWidth: 760)
            .aspectRatio(Theme.cardAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.heroRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.heroRadius).stroke(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
            .animation(reduceMotion ? .none : Theme.crossfade, value: game.id)
    }

    private func heroMeta(panel: HomeNavModel.Panel, game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow(for: panel, game: game))
                .font(.system(size: 13, weight: .bold))
                .tracking(2.0)
                .foregroundStyle(Theme.amber)

            Text(game.title)
                .font(.system(size: 42, weight: .heavy))
                .foregroundStyle(Theme.ivory)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .shadow(color: .black.opacity(0.6), radius: 10)

            Button {
                env.launch(game)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .heavy))
                    Text("PLAY")
                        .font(.system(size: 16, weight: .heavy))
                        .tracking(1.5)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 26)
                .padding(.vertical, 13)
                .background(Theme.amber, in: Capsule())
                .shadow(color: Theme.amber.opacity(0.45), radius: 16, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Text("A to launch · L1/R1 switch panel · PS quick bar")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ivory.opacity(0.55))
                .padding(.top, 4)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func eyebrow(for panel: HomeNavModel.Panel, game: GameEntry) -> String {
        guard let idx = panel.games.firstIndex(where: { $0.id == game.id }) else {
            return panel.title.uppercased()
        }
        return String(format: "%@ · %02d / %02d", panel.title.uppercased(), idx + 1, panel.games.count)
    }

    // MARK: - Tile row

    private var tileRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(Array((nav.currentPanel?.games ?? []).enumerated()), id: \.element.id) { idx, game in
                        BigTile(game: game, isSelected: nav.selection == idx)
                            .id("tile-\(idx)")
                            .onTapGesture { env.launch(game) }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 10)
            }
            .onChange(of: nav.selection) { _, newSel in
                withAnimation(reduceMotion ? .none : Theme.reticleSpring) {
                    proxy.scrollTo("tile-\(newSel)", anchor: .center)
                }
            }
        }
    }

    // MARK: - Empty

    private func emptyState(_ panel: HomeNavModel.Panel) -> some View {
        VStack(spacing: 12) {
            Text(panel.title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.amber)
            Text(panel.id == "home"
                 ? "Nothing played yet"
                 : "No \(panel.title) games")
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Theme.ivory)
            Text(panel.id == "home"
                 ? "Launch a game from Steam or PSP — it shows up here."
                 : "Add a ROM folder in Settings (PS → Settings).")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ivory.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }
}

// MARK: - Big tile (overlaid title, Steam-Big-Picture style)

struct BigTile: View {
    let game: GameEntry
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The banner fills the 460:215 box — Steam headers fit exactly.
            ArtworkView(entry: game)
                .frame(width: 336)
                .aspectRatio(Theme.cardAspect, contentMode: .fit)

            // Title scrim + overlaid title.
            LinearGradient(
                colors: [.clear, .black.opacity(0.95)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 60)
            .frame(maxWidth: .infinity, alignment: .bottom)

            Text(game.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ivory)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
        .frame(width: 336, height: 336 / Theme.cardAspect)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(isSelected ? Theme.amber : .white.opacity(0.10), lineWidth: isSelected ? 3 : 1)
        )
        .shadow(color: isSelected ? Theme.amber.opacity(0.30) : .black.opacity(0.35),
                radius: isSelected ? 20 : 8, y: 6)
        .brightness(isSelected ? 0.02 : -0.32)
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .zIndex(isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isSelected)
    }
}
