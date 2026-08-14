import SwiftUI

/// Quick bar items (PS button overlay). Selection is d-pad driven; PS/B dismisses.
enum QuickBarItem: Int, CaseIterable, Identifiable {
    case home
    case recentlyPlayed
    case discord
    case settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .recentlyPlayed: return "Recently Played"
        case .discord: return "Discord"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .recentlyPlayed: return "clock.fill"
        case .discord: return "bubble.left.and.bubble.right.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

final class QuickBarModel: ObservableObject {
    @Published var selection: QuickBarItem = .home

    func reset() { selection = .home }

    func handle(_ action: GamepadUIAction) -> QuickBarItem? {
        switch action {
        case .left:
            let raw = (selection.rawValue - 1 + QuickBarItem.allCases.count) % QuickBarItem.allCases.count
            selection = QuickBarItem(rawValue: raw) ?? .home
        case .right:
            let raw = (selection.rawValue + 1) % QuickBarItem.allCases.count
            selection = QuickBarItem(rawValue: raw) ?? .home
        case .confirm:
            return selection
        default:
            break
        }
        return nil
    }
}

struct QuickBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var model: QuickBarModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(QuickBarItem.allCases) { item in
                let selected = model.selection == item
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                    Text(item.title)
                        .font(Theme.hintFont)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(selected ? .white : Theme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    selected ? Theme.accent : Theme.panelRaised.opacity(0.9),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(selected ? .white.opacity(0.35) : .clear, lineWidth: 1)
                )
                .scaleEffect(selected ? 1.06 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: selected)
                .onTapGesture { env.quickBarSelect(item) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Theme.panel.opacity(0.92))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
