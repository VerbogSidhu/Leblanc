import SwiftUI

/// Navigation state for the home grid: platform panels, each a flat list of
/// games rendered as a responsive grid. L1/R1 switches panels; arrows move
/// the selection (row-major, using the grid's real column count); A launches.
final class HomeNavModel: ObservableObject {
    struct Panel: Identifiable, Equatable {
        let id: String
        let title: String
        let games: [GameEntry]
    }

    @Published private(set) var panels: [Panel] = []
    @Published var panelIndex = 0
    @Published var selection = 0

    /// Number of grid columns, set by the grid view from the live layout.
    @Published var columnCount = 4

    var currentPanel: Panel? {
        panels.indices.contains(panelIndex) ? panels[panelIndex] : nil
    }

    var selectedGame: GameEntry? {
        guard let panel = currentPanel, panel.games.indices.contains(selection) else { return nil }
        return panel.games[selection]
    }

    // MARK: - Panel data

    func rebuild(_ newPanels: [Panel]) {
        panels = newPanels
        panelIndex = min(panelIndex, max(0, panels.count - 1))
        clampSelection()
    }

    // MARK: - Panel switching (L1/R1)

    func previousPanel() {
        guard panels.count > 1 else { return }
        panelIndex = (panelIndex - 1 + panels.count) % panels.count
        selection = 0
    }

    func nextPanel() {
        guard panels.count > 1 else { return }
        panelIndex = (panelIndex + 1) % panels.count
        selection = 0
    }

    func selectPanel(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panelIndex = idx
        selection = 0
    }

    // MARK: - Grid navigation

    /// Applies a nav action; returns the confirmed game (on .confirm), if any.
    func handle(_ action: GamepadUIAction) -> GameEntry? {
        guard let panel = currentPanel, !panel.games.isEmpty else { return nil }
        let count = panel.games.count
        let cols = max(1, columnCount)

        switch action {
        case .left:
            selection = max(0, selection - 1)
        case .right:
            selection = min(count - 1, selection + 1)
        case .up:
            if selection - cols >= 0 { selection -= cols }
        case .down:
            if selection + cols < count { selection += cols }
        case .confirm:
            return selectedGame
        case .previousPanel:
            previousPanel()
        case .nextPanel:
            nextPanel()
        default:
            break
        }
        return nil
    }

    private func clampSelection() {
        guard let panel = currentPanel else { selection = 0; return }
        selection = min(selection, max(0, panel.games.count - 1))
    }
}
