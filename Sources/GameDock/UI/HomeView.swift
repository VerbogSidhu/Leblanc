import SwiftUI

/// Fullscreen console dashboard: top bar with platform tabs, then per-panel
/// hero + carousel. L1/R1 slides between panels; left/right moves the
/// selection; A launches; PS opens the quick bar.
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, Theme.gridPadding)
                    .padding(.top, 18)
                panelArea
                    .padding(.horizontal, Theme.gridPadding)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.background,
                    Color(red: 0.04, green: 0.045, blue: 0.07),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Platform-tinted glow behind the active panel.
            RadialGradient(
                colors: [
                    (nav.currentPanel?.accent ?? Theme.accent).opacity(0.16),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            // Wordmark
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text("GameDock")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }

            Spacer()

            // Platform tabs (clickable; L1/R1 driven)
            HStack(spacing: 6) {
                ForEach(nav.panels) { panel in
                    tabPill(panel)
                }
            }

            Spacer()

            // Status: game count / scanning
            if env.library.isScanning {
                ProgressView().controlSize(.small)
            }
            Text("\(env.library.games.count)")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textFaint)
        }
    }

    private func tabPill(_ panel: HomeNavModel.Panel) -> some View {
        let active = nav.currentPanel?.id == panel.id
        return HStack(spacing: 6) {
            Image(systemName: panel.icon)
                .font(.system(size: 11, weight: .bold))
            Text(panel.title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(active ? .white : Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            active ? AnyShapeStyle(panel.accent.gradient) : AnyShapeStyle(Theme.panel.opacity(0.7)),
            in: Capsule()
        )
        .overlay(Capsule().stroke(.white.opacity(active ? 0.25 : 0.06), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { env.selectPanel(panel.id) }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
    }

    // MARK: - Panel area

    private var panelArea: some View {
        ZStack {
            if nav.panels.isEmpty {
                emptyAll
            } else {
                ForEach(nav.panels.indices, id: \.self) { idx in
                    if idx == nav.panelIndex {
                        panelContent(nav.panels[idx])
                            .transition(slideTransition)
                    }
                }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: nav.panelIndex)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var slideTransition: AnyTransition {
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

    private var emptyAll: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textFaint)
            Text("No games yet")
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.textPrimary)
            Text("Add ROM folders in Settings (PS → Settings), or launch Steam once so its library can be read.")
                .font(Theme.hintFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
    }

    @ViewBuilder
    private func panelContent(_ panel: HomeNavModel.Panel) -> some View {
        if panel.games.isEmpty {
            emptyPanel(panel)
        } else {
            VStack(spacing: 14) {
                hero(panel)
                carousel(panel)
            }
        }
    }

    private func emptyPanel(_ panel: HomeNavModel.Panel) -> some View {
        VStack(spacing: 12) {
            Image(systemName: panel.icon)
                .font(.system(size: 44))
                .foregroundStyle(panel.accent.opacity(0.6))
            Text("No \(panel.title) games")
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.textPrimary)
            Text(panel.id == "psp"
                ? "Add PSP ROMs in Settings, or drop them in your ROM folder."
                : "Add \(panel.title) ROMs in Settings (PS → Settings).")
                .font(Theme.hintFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero

    private func hero(_ panel: HomeNavModel.Panel) -> some View {
        let game = nav.selectedGame ?? panel.games[0]
        return HStack(spacing: 26) {
            // Wide art banner with title overlay.
            ZStack(alignment: .bottomLeading) {
                ArtworkView(entry: game)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(game.title)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(panel.title)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(panel.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.5), in: Capsule())
                        Text("A · Launch")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(22)
            }
            .frame(width: 640, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .shadow(color: panel.accent.opacity(0.25), radius: 40)

            // Details column.
            VStack(alignment: .leading, spacing: 12) {
                Text(game.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(panel.games.count == 1 ? "1 game" : "\(panel.games.count) games")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textFaint)
                Spacer()
                VStack(alignment: .leading, spacing: 7) {
                    hintRow("A", "Launch")
                    hintRow("L1 / R1", "Switch panel")
                    hintRow("PS", "Quick bar")
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 380)
        .id(game.id)
    }

    private func hintRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 5))
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Carousel

    private func carousel(_ panel: HomeNavModel.Panel) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(Array(panel.games.enumerated()), id: \.element.id) { idx, game in
                        GameCardView(
                            game: game,
                            accent: panel.accent,
                            isSelected: nav.selection == idx
                        )
                        .id("card-\(idx)")
                        .onTapGesture { env.launch(game) }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 4)
            }
            .onChange(of: nav.selection) { _, newSel in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("card-\(newSel)", anchor: .center)
                }
            }
        }
    }
}

// MARK: - Game card

struct GameCardView: View {
    let game: GameEntry
    let accent: Color
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(entry: game)
                .frame(width: Theme.cardWidth, height: Theme.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(isSelected ? accent : .white.opacity(0.08), lineWidth: isSelected ? 3 : 1)
                        .shadow(color: isSelected ? accent.opacity(0.6) : .clear, radius: 12)
                )
                .scaleEffect(isSelected ? 1.05 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)

            Text(game.title)
                .font(Theme.cardTitleFont)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: Theme.cardWidth)
    }
}
