import SwiftUI

/// One game in the grid: banner art (fills the column at the banner aspect)
/// with the title beneath. The focused card gets an amber ring. Nothing here
/// uses fixed widths — the column decides, so it adapts everywhere.
struct GameCard: View {
    let game: GameEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(entry: game)
                .frame(maxWidth: .infinity)
                .aspectRatio(Theme.bannerAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .stroke(isSelected ? Theme.amber : Theme.hairline, lineWidth: isSelected ? 2.5 : 1)
                )
                .brightness(isSelected ? 0.02 : -0.08)

            Text(game.title)
                .font(Theme.cardTitle)
                .foregroundStyle(isSelected ? Theme.ivory : Theme.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
}
