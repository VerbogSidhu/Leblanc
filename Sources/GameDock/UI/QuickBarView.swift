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
        case .up:
            selection = QuickBarItem(rawValue: (selection.rawValue - 1 + QuickBarItem.allCases.count) % QuickBarItem.allCases.count) ?? .home
        case .down:
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
        VStack(spacing: 10) {
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

            statusRow
        }
        .padding(10)
        .background(Theme.ink.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.mist.opacity(0.25)).frame(height: 1) }
        .overlay(alignment: .trailing) { volumeIndicator }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .animation(reduceMotion ? nil : Theme.spring, value: model.selection)
    }

    // MARK: - Status HUD (clock, batteries, network)

    private var statusRow: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 16) {
                Text(context.date.formatted(date: .omitted, time: .shortened))
                statusItem("battery.75", env.status.macBattery, charging: env.status.macCharging)
                statusItem("gamecontroller.fill", env.status.controllerBattery)
                statusItem("wifi", env.status.network)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.mist)
        }
    }

    private func statusItem(_ icon: String, _ text: String, charging: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: charging ? "bolt.fill" : icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(charging ? Theme.trophy : Theme.mist)
            Text(text)
        }
    }

    // MARK: - Volume indicator (controller + keyboard volume)

    private var volumeIndicator: some View {
        Group {
            if env.volume.hudVisible {
                HStack(spacing: 8) {
                    Image(systemName: env.volume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.paper)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.ink)
                            Capsule().fill(Theme.signal)
                                .frame(width: geo.size.width * CGFloat(env.volume.level))
                        }
                    }
                    .frame(width: 110, height: 8)
                }
                .padding(10)
                .background(Theme.ink.opacity(0.9), in: Capsule())
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
    }
}
