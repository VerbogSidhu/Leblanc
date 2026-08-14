import SwiftUI

/// Navigation state for the home grid: platform panels, each a flat list of
/// games rendered as a grid. L1/R1 switches panels; arrows move the selection
/// (row-major, driven by `columnCount`); A launches; PS opens the quick bar.
final class HomeNavModel: ObservableObject {
    struct Panel: Identifiable, Equatable {
        let id: String
        let title: String
        let games: [GameEntry]
    }

    @Published private(set) var panels: [Panel] = []
    @Published var panelIndex = 0
    @Published var selection = 0

    /// Grid column count (set by the view from the actual layout).
    @Published var columnCount = 4

    /// Direction of the last panel switch (for the slide animation).
    @Published private(set) var slideDirection: SlideDirection = .none
    enum SlideDirection { case none, forward, backward }

    var currentPanel: Panel? {
        panels.indices.contains(panelIndex) ? panels[panelIndex] : nil
    }

    var selectedGame: GameEntry? {
        guard let panel = currentPanel, panel.games.indices.contains(selection) else { return nil }
        return panel.games[selection]
    }

    func rebuild(_ newPanels: [Panel]) {
        let old = panels
        panels = newPanels
        panelIndex = min(panelIndex, max(0, panels.count - 1))
        clampSelection()
        if old != panels {
            Log.debug("HomeNavModel: \(panels.map { "\($0.id):\($0.games.count)" }.joined(separator: ", "))")
        }
    }

    // MARK: - Panel switching (L1/R1)

    func previousPanel() { move(by: -1) }
    func nextPanel() { move(by: 1) }

    /// Moves the panel by delta. On wrap (last<->first) the slide is replaced
    /// by a plain crossfade so the motion never fights the wrap.
    private func move(by delta: Int) {
        guard panels.count > 1 else { return }
        let old = panelIndex
        let n = (panelIndex + delta + panels.count) % panels.count
        let wrapped = (delta > 0 && n <= old) || (delta < 0 && n >= old)
        slideDirection = wrapped ? .none : (delta > 0 ? .forward : .backward)
        panelIndex = n
        selection = 0
    }

    func selectPanel(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panelIndex = idx
        selection = 0
    }

    // MARK: - Input (row-major grid navigation)

    /// Applies a nav action; returns the confirmed game (on .confirm), if any.
    func handle(_ action: GamepadUIAction) -> GameEntry? {
        guard let panel = currentPanel, !panel.games.isEmpty else { return nil }
        let count = panel.games.count
        let cols = max(1, columnCount)

        switch action {
        case .left:
            if selection % cols == 0 {
                selection = min(count - 1, selection + cols - 1) // wrap to row end
            } else {
                selection -= 1
            }
        case .right:
            if selection % cols == cols - 1 || selection == count - 1 {
                selection = max(0, selection - (selection % cols)) // wrap to row start
            } else {
                selection += 1
            }
        case .up:
            break // single horizontal tile row; up/down do nothing
        case .down:
            break
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
