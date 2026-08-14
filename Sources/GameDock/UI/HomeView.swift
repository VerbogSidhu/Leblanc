import SwiftUI

/// Navigation state for the home grid: sections (Recently Played / Steam /
/// PSP / DS) plus a (row, column) selection that d-pad/stick/keyboard drives.
final class HomeNavModel: ObservableObject {
    struct Section: Identifiable, Equatable {
        let id: String
        let title: String
        let games: [GameEntry]
    }

    @Published private(set) var sections: [Section] = []
    @Published var selection: (row: Int, col: Int) = (0, 0)

    var selectedGame: GameEntry? {
        guard sections.indices.contains(selection.row) else { return nil }
        let games = sections[selection.row].games
        guard games.indices.contains(selection.col) else { return nil }
        return games[selection.col]
    }

    var hasContent: Bool { !sections.isEmpty }

    func rebuild(_ newSections: [Section]) {
        let old = sections
        sections = newSections.filter { !$0.games.isEmpty }
        // Keep the selection valid after a rescan.
        selection.row = min(selection.row, max(0, sections.count - 1))
        if !sections.isEmpty {
            selection.col = min(selection.col, max(0, sections[selection.row].games.count - 1))
        }
        if old != sections {
            Log.debug("HomeNavModel: rebuilt — \(sections.map { "\($0.title):\($0.games.count)" }.joined(separator: ", "))")
        }
    }

    // MARK: - Input

    /// Applies a nav action. Returns the confirmed game (on .confirm), if any.
    func handle(_ action: GamepadUIAction) -> GameEntry? {
        guard hasContent else { return nil }
        switch action {
        case .up:
            if selection.row > 0 { selection.row -= 1 }
            clampColumn()
        case .down:
            if selection.row < sections.count - 1 { selection.row += 1 }
            clampColumn()
        case .left:
            if selection.col > 0 {
                selection.col -= 1
            } else {
                // Wrap to the end of the row.
                selection.col = sections[selection.row].games.count - 1
            }
        case .right:
            let maxCol = max(0, sections[selection.row].games.count - 1)
            if selection.col < maxCol {
                selection.col += 1
            } else {
                selection.col = 0
            }
        case .confirm:
            return selectedGame
        case .back, .openQuickBar, .toggleDiscord:
            break
        }
        return nil
    }

    private func clampColumn() {
        guard sections.indices.contains(selection.row) else { return }
        selection.col = min(selection.col, max(0, sections[selection.row].games.count - 1))
    }
}

// MARK: - Home view

struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel

    var body: some View {
        ScrollViewReader { vProxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                    header

                    if nav.sections.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(nav.sections.enumerated()), id: \.element.id) { index, section in
                            sectionView(section, row: index)
                                .id("row-\(index)")
                        }
                    }
                }
                .padding(Theme.gridPadding)
            }
            .onChange(of: nav.selection.row) { _, newRow in
                withAnimation(.easeOut(duration: 0.2)) {
                    vProxy.scrollTo("row-\(newRow)", anchor: .center)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("GameDock")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(env.library.isScanning ? "Scanning…" : "\(env.library.games.count) games")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textFaint)
            Text("No games yet")
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.textPrimary)
            Text("Add ROM folders in Settings (PS button → Settings), or launch Steam once so its library can be read.")
                .font(Theme.hintFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Text("Press PS (or F1) to open the quick bar")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func sectionView(_ section: HomeNavModel.Section, row: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(Theme.sectionFont)
                .foregroundStyle(Theme.textPrimary)

            ScrollViewReader { hProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(Array(section.games.enumerated()), id: \.element.id) { col, game in
                            GameCardView(
                                game: game,
                                isSelected: nav.selection.row == row && nav.selection.col == col
                            )
                            .id("card-\(section.id)-\(col)")
                            .onTapGesture { env.launch(game) }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .onChange(of: nav.selection.row) { _, rowChanged in
                    if rowChanged == row {
                        let col = nav.selection.col
                        withAnimation(.easeOut(duration: 0.2)) {
                            hProxy.scrollTo("card-\(section.id)-\(col)", anchor: .center)
                        }
                    }
                }
                .onChange(of: nav.selection.col) { _, col in
                    if nav.selection.row == row {
                        withAnimation(.easeOut(duration: 0.2)) {
                            hProxy.scrollTo("card-\(section.id)-\(col)", anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Game card

struct GameCardView: View {
    let game: GameEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(entry: game)
                .frame(width: Theme.cardWidth, height: Theme.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardCornerRadius)
                        .stroke(isSelected ? Theme.accent : .clear, lineWidth: 3)
                        .shadow(color: isSelected ? Theme.accent.opacity(0.6) : .clear, radius: 10)
                )
                .scaleEffect(isSelected ? 1.03 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)

            HStack(spacing: 6) {
                Text(game.title)
                    .font(Theme.cardTitleFont)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if game.source != .steam {
                    Text(game.source.displayName)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.panelRaised, in: Capsule())
                }
            }
        }
        .frame(width: Theme.cardWidth)
    }
}
