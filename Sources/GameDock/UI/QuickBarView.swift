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

/// The PS-button quick bar — a horizontal pill of mono-labeled actions.
/// Active item uses the amber fill; PS/B dismisses.
struct QuickBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var model: QuickBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(QuickBarItem.allCases) { item in
                let selected = model.selection == item
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .semibold))
                    Text(item.title.uppercased())
                        .font(Theme.railLabel)
                        .tracking(1.2)
                }
                .foregroundStyle(selected ? Theme.void : Theme.ivory.opacity(0.8))
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    selected ? AnyShapeStyle(Theme.amber) : AnyShapeStyle(.black.opacity(0.0)),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(selected ? .clear : .white.opacity(0.14), lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { env.quickBarSelect(item) }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(Theme.panel.opacity(0.96))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
        .animation(reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.85), value: model.selection)
    }
}
