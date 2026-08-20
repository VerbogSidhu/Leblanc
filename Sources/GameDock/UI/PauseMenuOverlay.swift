import SwiftUI

/// Pause menu model — the in-game overlay opened with Circle/back while an
/// emulator is running (fixed item set; multiple saves slots are future work).
final class PauseMenuModel: ObservableObject {
    enum Item: Int, CaseIterable {
        case resume, saveState, loadState, coreOptions, reset, quit

        var title: String {
            switch self {
            case .resume: return "Resume"
            case .saveState: return "Save State"
            case .loadState: return "Load State"
            case .coreOptions: return "Core Options"
            case .reset: return "Reset"
            case .quit: return "Quit Game"
            }
        }

        var icon: String {
            switch self {
            case .resume: return "play.fill"
            case .saveState: return "square.and.arrow.down.fill"
            case .loadState: return "square.and.arrow.up.fill"
            case .coreOptions: return "slider.horizontal.3"
            case .reset: return "arrow.counterclockwise"
            case .quit: return "power"
            }
        }
    }

    @Published var selection: Item = .resume

    func reset() { selection = .resume }

    /// Returns the confirmed item on .confirm, wrapping on up/down.
    func handle(_ action: GamepadUIAction) -> Item? {
        let all = Item.allCases
        guard let idx = all.firstIndex(of: selection) else { selection = .resume; return nil }
        switch action {
        case .up: selection = all[(idx - 1 + all.count) % all.count]
        case .down: selection = all[(idx + 1) % all.count]
        case .confirm: return selection
        default: break
        }
        return nil
    }

    /// Mouse parity: click a row to select + confirm it.
    func select(_ item: Item) -> Item {
        selection = item
        return item
    }
}

/// In-game pause menu: a scrim + ink panel with the action list. Controller /
/// mouse driven. Emulation is paused while it's open (AppEnvironment routes
/// input here before anything else).
struct PauseMenuOverlay: View {
    @ObservedObject var model: PauseMenuModel
    let onActivate: (PauseMenuModel.Item) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture {} // swallow clicks; controller-driven

            VStack(spacing: 18) {
                Text("Pause Menu")
                    .font(GameDockFonts.display(26, weight: .bold))
                    .foregroundStyle(Theme.paper)

                VStack(spacing: 6) {
                    ForEach(PauseMenuModel.Item.allCases, id: \.self) { item in
                        row(item)
                    }
                }

                Text("▲▼ SELECT · ✕ CONFIRM · ○ CLOSE")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.mist)
                    .padding(.top, 6)
            }
            .padding(26)
            .frame(maxWidth: 460)
            .background(Theme.ink.opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.mist.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
    }

    private func row(_ item: PauseMenuModel.Item) -> some View {
        let selected = model.selection == item
        return HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
            Text(item.title)
                .font(Theme.body)
            Spacer()
            if selected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.signal)
            }
        }
        .foregroundStyle(selected ? Theme.paper : Theme.mist)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(selected ? Theme.signal.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.signal.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // Mouse: select + activate (same action as pressing confirm).
            _ = model.select(item)
            onActivate(item)
        }
    }
}
