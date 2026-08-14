import SwiftUI

/// The responsive game grid. Columns are measured from the live width so the
/// same count drives both layout and controller navigation. The grid scrolls,
/// so it can never be cut off at any resolution.
struct GameGrid: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let cols = columnCount(for: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gridGap), count: cols),
                        spacing: Theme.gridRowGap
                    ) {
                        ForEach(Array((nav.currentPanel?.games ?? []).enumerated()), id: \.element.id) { idx, game in
                            GameCard(game: game, isSelected: nav.selection == idx)
                                .id("game-\(idx)")
                                .onTapGesture { env.launch(game) }
                        }
                    }
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.vertical, 22)
                }
                .onChange(of: nav.selection) { _, newSel in
                    withAnimation(reduceMotion ? nil : Theme.fade) {
                        proxy.scrollTo("game-\(newSel)", anchor: .center)
                    }
                }
            }
            .onAppear { nav.columnCount = cols }
            .onChange(of: geo.size.width) { _, _ in nav.columnCount = cols }
        }
    }

    /// Columns from the available width, matching a comfortable minimum card.
    private func columnCount(for width: CGFloat) -> Int {
        let available = max(width - Theme.screenPadding * 2, 1)
        return max(2, Int(available / 260))
    }
}
