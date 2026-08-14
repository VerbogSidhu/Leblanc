import SwiftUI

/// Quick bar items (PS button overlay). D-pad driven; PS/B dismisses.
enum QuickBarItem: Int, CaseIterable, Identifiable {
    case home, recentlyPlayed, discord, settings
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
            selection = QuickBarItem(rawValue: (selection.rawValue - 1 + QuickBarItem.allCases.count) % QuickBarItem.allCases.count) ?? .home
        case .right:
            selection = QuickBarItem(rawValue: (selection.rawValue + 1) % QuickBarItem.allCases.count) ?? .home
        case .confirm:
            return selection
        default:
            break
        }
        return nil
    }
}

/// The PS-button quick bar: a translucent ink strip that slides in from the top.
struct QuickBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var model: QuickBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(QuickBarItem.allCases) { item in
                let selected = model.selection == item
                HStack(spacing: 8) {
                    Image(systemName: item.icon).font(.system(size: 12, weight: .semibold))
                    Text(item.title).font(Theme.body)
                }
                .foregroundStyle(selected ? Theme.void : Theme.paper)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(selected ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(.clear), in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : Theme.mist.opacity(0.35), lineWidth: 1))
                .contentShape(Capsule())
                .onTapGesture { env.quickBarSelect(item) }
            }
        }
        .padding(10)
        .background(Theme.ink.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.mist.opacity(0.25)).frame(height: 1) }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .animation(reduceMotion ? nil : Theme.spring, value: model.selection)
    }
}
