import SwiftUI

/// Navigation state for the home screen: platform panels (Home / Steam /
/// PSP / DS), each a list of games. L1/R1 switches panels (with a slide
/// direction), left/right moves the selection within a panel, A launches.
final class HomeNavModel: ObservableObject {
    struct Panel: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let accent: Color
        let games: [GameEntry]
    }

    @Published private(set) var panels: [Panel] = []
    @Published var panelIndex = 0
    @Published var selection = 0

    /// Direction of the last panel switch (for slide animation).
    @Published private(set) var slideDirection: SlideDirection = .none
    enum SlideDirection { case none, forward, backward }

    var currentPanel: Panel? {
        panels.indices.contains(panelIndex) ? panels[panelIndex] : nil
    }

    var selectedGame: GameEntry? {
        guard let panel = currentPanel, panel.games.indices.contains(selection) else { return nil }
        return panel.games[selection]
    }

    var hasContent: Bool { !panels.isEmpty }

    /// Rebuilds the panel list; keeps panel/selection valid.
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

    func previousPanel() {
        guard panels.count > 1 else { return }
        panelIndex = (panelIndex - 1 + panels.count) % panels.count
        slideDirection = .backward
        clampSelection()
    }

    func nextPanel() {
        guard panels.count > 1 else { return }
        panelIndex = (panelIndex + 1) % panels.count
        slideDirection = .forward
        clampSelection()
    }

    func selectPanel(_ id: String) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        slideDirection = idx > panelIndex ? .forward : .backward
        panelIndex = idx
        clampSelection()
    }

    // MARK: - Input

    /// Applies a nav action; returns the confirmed game (on .confirm), if any.
    func handle(_ action: GamepadUIAction) -> GameEntry? {
        guard hasContent else { return nil }
        switch action {
        case .left:
            if selection > 0 {
                selection -= 1
            } else if let panel = currentPanel, !panel.games.isEmpty {
                selection = panel.games.count - 1 // wrap
            }
        case .right:
            if let panel = currentPanel, !panel.games.isEmpty {
                selection = (selection + 1) % panel.games.count
            }
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
