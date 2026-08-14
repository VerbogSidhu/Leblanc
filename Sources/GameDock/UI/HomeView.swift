import SwiftUI

/// GameDock home — horizontal-first. The selected game's wide banner fills the
/// screen as a wallpaper; a single horizontal row of wide 16:9 cards sits at
/// the bottom; the focused card is framed by the amber reticle. All chrome is
/// thin and horizontal — nothing eats the horizontal space that banner art
/// needs. See docs/design-spec.md for tokens.
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            wallpaper
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
    }

    /// Slides the panel (hero info + filmstrip) in the L1/R1 direction.
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

    @ViewBuilder
    private var panelContent: some View {
        if let panel = nav.currentPanel, panel.games.isEmpty {
            emptyPanel(panel)
        } else {
            heroInfo
            filmstrip
                .padding(.bottom, 14)
        }
    }

    // MARK: - Wallpaper (the selected game's banner, full-bleed)

    @ViewBuilder
    private var wallpaper: some View {
        if let game = nav.selectedGame {
            ArtworkView(entry: game)
                .ignoresSafeArea()
                .overlay(
                    LinearGradient(
                        colors: [
                            .black.opacity(0.62),   // top: top-bar legibility
                            .clear.opacity(0),
                            .black.opacity(0.30),
                            .black.opacity(0.82),   // bottom: title + strip
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .id("wallpaper-\(game.id)")
                .transition(.opacity)
        } else {
            Theme.void.ignoresSafeArea()
        }
    }

    // MARK: - Top bar (thin, horizontal)

    private var topBar: some View {
        HStack(spacing: 14) {
            Text("GAMEDOCK")
                .font(Theme.wordmark)
                .tracking(2.5)
                .foregroundStyle(Theme.ivory)

            Spacer()

            HStack(spacing: 6) {
                ForEach(nav.panels) { panel in
                    topPill(panel)
                }
            }

            Spacer()

            if env.library.isScanning {
                ProgressView().controlSize(.small).tint(Theme.amber)
            }
            Text(String(format: "%02d", env.library.games.count))
                .font(Theme.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Theme.ash)
        }
        .padding(.horizontal, 30)
        .padding(.top, 16)
    }

    private func topPill(_ panel: HomeNavModel.Panel) -> some View {
        let active = nav.currentPanel?.id == panel.id
        return Text(panel.title.uppercased())
            .font(Theme.railLabel)
            .tracking(1.6)
            .foregroundStyle(active ? Theme.void : Theme.ivory.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.black.opacity(0.35)), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(active ? 0 : 0.14), lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Theme.railSpring) { env.selectPanel(panel.id) } }
            .animation(reduceMotion ? .none : Theme.crossfade, value: active)
    }

    // MARK: - Hero info (over the wallpaper, bottom-left)

    @ViewBuilder
    private var heroInfo: some View {
        if let panel = nav.currentPanel, let game = nav.selectedGame {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(eyebrow(for: panel, game: game))
                        .font(Theme.eyebrow)
                        .tracking(1.8)
                        .foregroundStyle(Theme.amber)
                    Rectangle().fill(Theme.amber).frame(width: 40, height: 1)
                }
                Text(game.title)
                    .font(.system(size: 54, weight: .heavy, design: .default))
                    .foregroundStyle(Theme.ivory)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .shadow(color: .black.opacity(0.7), radius: 12)
                HStack(spacing: 20) {
                    playCue(accent: Theme.amber)
                    hint("L1 / R1", "Panel")
                    hint("A", "Launch")
                    hint("PS", "Quick bar")
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("info-\(game.id)")
            .transition(.opacity)
        }
    }

    private func eyebrow(for panel: HomeNavModel.Panel, game: GameEntry) -> String {
        guard let idx = panel.games.firstIndex(where: { $0.id == game.id }) else {
            return panel.title.uppercased()
        }
        return String(format: "%@  ·  %02d / %02d", panel.title.uppercased(), idx + 1, panel.games.count)
    }

    private func playCue(accent: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(accent)
            Text("A · PLAY")
                .font(Theme.hint)
                .tracking(1.5)
                .foregroundStyle(accent)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(Theme.caption)
                .foregroundStyle(Theme.ivory)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.ivory.opacity(0.65))
        }
    }

    // MARK: - Filmstrip (one horizontal row of wide banners)

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(Array((nav.currentPanel?.games ?? []).enumerated()), id: \.element.id) { idx, game in
                        WideCard(
                            game: game,
                            accent: Theme.amber,
                            isSelected: nav.selection == idx
                        )
                        .id("card-\(idx)")
                        .onTapGesture { env.launch(game) }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 10)
            }
            .onChange(of: nav.selection) { _, newSel in
                withAnimation(reduceMotion ? .none : Theme.reticleSpring) {
                    proxy.scrollTo("card-\(newSel)", anchor: .center)
                }
            }
        }
    }

    // MARK: - Empties

    private func emptyPanel(_ panel: HomeNavModel.Panel) -> some View {
        VStack(spacing: 12) {
                Text(panel.title.uppercased())
                    .font(Theme.eyebrow)
                    .tracking(2)
                    .foregroundStyle(Theme.amber)
                Text(panel.id == "home"
                     ? "No recently played games yet"
                     : "No \(panel.title) games found")
                    .font(.system(size: 30, weight: .heavy, design: .default))
                    .foregroundStyle(Theme.ivory)
                Text(panel.id == "home"
                     ? "Launch something from Steam or PSP — it shows up here."
                     : "Add a ROM folder in Settings (PS → Settings).")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

// MARK: - Wide horizontal card (16:9)

struct WideCard: View {
    let game: GameEntry
    let accent: Color
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Blurred backdrop: fills the wide card with the art's colors so
            // portrait box art never leaves dead space.
            ArtworkView(entry: game)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 10)
                .scaleEffect(1.15)
                .overlay(.black.opacity(0.55))

            // The real artwork, fitted (landscape fills; portrait centers).
            ArtworkView(entry: game)
                .padding(8)
                .aspectRatio(contentMode: .fit)

            // Title scrim + title.
            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 70)
            .frame(maxWidth: .infinity, alignment: .bottom)

            Text(game.title)
                .font(Theme.cardTitle)
                .foregroundStyle(Theme.ivory)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
        .frame(width: Theme.cardWidth, height: Theme.cardArtHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(isSelected ? accent.opacity(0.9) : Theme.hairline, lineWidth: 1)
        )
        .overlay {
            if isSelected {
                Reticle(accent: accent)
                    .padding(-3)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .brightness(isSelected ? 0 : -0.28)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .shadow(color: .black.opacity(isSelected ? 0.6 : 0.3), radius: isSelected ? 18 : 8, y: 6)
        .zIndex(isSelected ? 1 : 0)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: isSelected)
    }
}

/// The signature: amber L-shaped corner brackets that frame the focused card —
/// a viewfinder "target lock". Sharp corners, only on the focus.
struct Reticle: View {
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let len: CGFloat = 20
            let t: CGFloat = 3
            let r = CGRect(origin: .zero, size: geo.size)
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY + len))
                p.addLine(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
                p.move(to: CGPoint(x: r.maxX - len, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
                p.move(to: CGPoint(x: r.minX, y: r.maxY - len))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX + len, y: r.maxY))
                p.move(to: CGPoint(x: r.maxX - len, y: r.maxY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - len))
            }
            .stroke(accent, style: StrokeStyle(lineWidth: t, lineCap: .round))
            .shadow(color: accent.opacity(0.5), radius: 6)
        }
    }
}