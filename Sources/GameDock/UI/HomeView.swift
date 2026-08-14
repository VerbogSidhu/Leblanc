import SwiftUI

/// Home: a top bar and a scrolling grid of games. A grid adapts to every
/// resolution by construction — columns reflow, rows scroll, nothing is ever
/// cut off. L1/R1 switches platform; arrows move the grid; A launches;
/// PS opens the quick bar.
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TopBar(nav: nav)
                Rectangle().fill(Theme.hairline).frame(height: 1)

                if let panel = nav.currentPanel, panel.games.isEmpty {
                    emptyState(panel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GameGrid(nav: nav)
                        .id(nav.panelIndex) // fresh scroll position per panel
                        .transition(.opacity)
                }
            }
            // Respect the notch / menu bar / rounded corners in fullscreen.
            .padding(.top, geo.safeAreaInsets.top)
            .padding(.bottom, geo.safeAreaInsets.bottom)
        }
        .background(Theme.void.ignoresSafeArea())
        .animation(reduceMotion ? nil : Theme.fade, value: nav.panelIndex)
    }

    private func emptyState(_ panel: HomeNavModel.Panel) -> some View {
        VStack(spacing: 10) {
            Text(panel.title.uppercased())
                .font(Theme.caption)
                .tracking(1.8)
                .foregroundStyle(Theme.ash)
            Text(panel.id == "home"
                 ? "Nothing played yet"
                 : "No \(panel.title) games")
                .font(Theme.emptyTitle)
                .foregroundStyle(Theme.ivory)
            Text(panel.id == "home"
                 ? "Launch a game from Steam or PSP — it shows up here."
                 : "Add a ROM folder in Settings (PS → Settings).")
                .font(Theme.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(.bottom, 40)
    }
}
