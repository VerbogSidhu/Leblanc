import SwiftUI

/// GameDock home — a CRT-operator console dashboard: a vertical channel rail
/// (the machine) on the left, a big game hero on top (the thesis: "this is the
/// game you're about to play"), and a filmstrip of cards below where the
/// focused card is framed by an amber focus reticle (the signature).
///
/// L1/R1 switches panels; left/right moves the selection; A launches; PS opens
/// the quick bar. See docs/design-spec.md for the design rationale.
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            rail
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.void.ignoresSafeArea())
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Wordmark — mono, tracked, quiet.
            Text("GAMEDOCK")
                .font(Theme.wordmark)
                .tracking(2.5)
                .foregroundStyle(Theme.ivory)
                .padding(.horizontal, 16)
                .padding(.bottom, 28)

            VStack(spacing: 2) {
                ForEach(nav.panels) { panel in
                    railRow(panel)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            railFooter
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(width: Theme.railWidth, alignment: .top)
        .padding(.top, 30)
        .background(Theme.panel.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea()
        }
    }

    private func railRow(_ panel: HomeNavModel.Panel) -> some View {
        let active = nav.currentPanel?.id == panel.id
        let countStr = panel.games.isEmpty ? "—" : String(format: "%02d", panel.games.count)
        return HStack(spacing: 12) {
            // Amber focus bar on the active channel.
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.amber)
                .frame(width: 3, height: 26)
                .opacity(active ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title.uppercased())
                    .font(Theme.railLabel)
                    .tracking(1.6)
                    .foregroundStyle(active ? Theme.ivory : Theme.ash)
                Text(countStr)
                    .font(Theme.railCount)
                    .foregroundStyle(active ? Theme.textSecondary : Theme.ash)
                    .opacity(active ? 1 : 0.7)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(active ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Theme.railSpring) { env.selectPanel(panel.id) } }
        .animation(reduceMotion ? .none : Theme.railSpring, value: active)
    }

    private var railFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(env.library.isScanning ? Theme.amber : Theme.ash.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(String(format: "%03d GAMES", env.library.games.count))
                    .font(Theme.eyebrow)
                    .tracking(1.4)
                    .foregroundStyle(Theme.ash)
            }
        }
    }

    // MARK: - Content (hero + filmstrip)

    @ViewBuilder
    private var content: some View {
        if nav.panels.isEmpty {
            emptyAll
        } else {
            ZStack {
                ForEach(nav.panels.indices, id: \.self) { idx in
                    if idx == nav.panelIndex {
                        panelView(nav.panels[idx])
                            .transition(slideTransition)
                    }
                }
            }
            .animation(reduceMotion ? Theme.crossfade : Theme.panelSlide, value: nav.panelIndex)
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

    private func panelView(_ panel: HomeNavModel.Panel) -> some View {
        VStack(spacing: 22) {
            hero(panel)
            filmstrip(panel)
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ panel: HomeNavModel.Panel) -> some View {
        if panel.games.isEmpty {
            emptyPanel(panel)
        } else {
            let game = nav.selectedGame ?? panel.games[0]
            ZStack(alignment: .bottomLeading) {
                ArtworkView(entry: game)
                    .frame(maxWidth: .infinity)
                    .frame(height: 374)
                    .clipped()

                // Bottom scrim so the title reads over any art.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.30), .black.opacity(0.86)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 230)
                .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 10) {
                        Text(eyebrow(for: panel, game: game))
                            .font(Theme.eyebrow)
                            .tracking(1.6)
                            .foregroundStyle(panel.accent)
                        Rectangle().fill(panel.accent).frame(width: 34, height: 1)
                    }
                    Text(game.title)
                        .font(Theme.heroTitle)
                        .foregroundStyle(Theme.ivory)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.7), radius: 10)
                    HStack(spacing: 18) {
                        playCue(accent: panel.accent)
                        hint("L1 / R1", "Switch")
                        hint("PS", "Quick bar")
                    }
                }
                .padding(26)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .frame(height: 374)
            .clipShape(RoundedRectangle(cornerRadius: Theme.heroRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.heroRadius).stroke(Theme.hairline, lineWidth: 1))
            .id(game.id)
            .animation(reduceMotion ? .none : Theme.crossfade, value: game.id)
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
                .tracking(1.4)
                .foregroundStyle(accent)
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.ash)
        }
    }

    // MARK: - Filmstrip + reticle

    private func filmstrip(_ panel: HomeNavModel.Panel) -> some View {
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
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
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
        HStack(spacing: 22) {
            RoundedRectangle(cornerRadius: Theme.heroRadius)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: Theme.heroRadius).stroke(Theme.hairline, lineWidth: 1))
                .frame(maxWidth: .infinity)
                .frame(height: 374)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(panel.title.uppercased())
                            .font(Theme.eyebrow)
                            .tracking(1.6)
                            .foregroundStyle(panel.accent)
                        Text(panel.id == "home"
                             ? "No recently played games yet"
                             : "No \(panel.title) games found")
                            .font(Theme.heroTitle)
                            .foregroundStyle(Theme.ivory)
                        Text(panel.id == "home"
                             ? "Launch something from the Steam or PSP panel — it shows up here."
                             : "Add a ROM folder in Settings (PS → Settings).")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: 440, alignment: .leading)
                    }
                    .padding(26)
                }
            Spacer()
        }
    }

    private var emptyAll: some View {
        VStack(spacing: 14) {
            Text("GAMEDOCK").font(Theme.wordmark).tracking(3).foregroundStyle(Theme.ash)
            Text("No games yet")
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.ivory)
            Text("Add ROM folders in Settings, or launch Steam once so its library can be read.")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card

struct GameCardView: View {
    let game: GameEntry
    let accent: Color
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ArtworkView(entry: game)
                    .frame(width: Theme.cardWidth, height: Theme.cardArtHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                // Dim unfocused cards so the focused one is the bright target.
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(.black.opacity(isSelected ? 0 : 0.42))
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.hairline, lineWidth: 1)
                if isSelected {
                    Reticle(accent: accent)
                        .padding(-2) // brackets sit just outside the art
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())

            Text(game.title)
                .font(Theme.cardTitle)
                .foregroundStyle(isSelected ? Theme.ivory : Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .frame(width: Theme.cardWidth, height: 38, alignment: .topLeading)
        }
        .frame(width: Theme.cardWidth)
        .animation(.spring(response: 0.30, dampingFraction: 0.8), value: isSelected)
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
                // top-left
                p.move(to: CGPoint(x: r.minX, y: r.minY + len))
                p.addLine(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
                // top-right
                p.move(to: CGPoint(x: r.maxX - len, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
                // bottom-left
                p.move(to: CGPoint(x: r.minX, y: r.maxY - len))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX + len, y: r.maxY))
                // bottom-right
                p.move(to: CGPoint(x: r.maxX - len, y: r.maxY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - len))
            }
            .stroke(accent, style: StrokeStyle(lineWidth: t, lineCap: .round))
            .shadow(color: accent.opacity(0.5), radius: 6)
        }
    }
}