import SwiftUI

/// Top bar: app name, platform tabs, game count. One row, fixed height,
/// hairline underneath. Tabs underline the active platform with amber.
struct TopBar: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var nav: HomeNavModel

    var body: some View {
        HStack(spacing: 16) {
            Text("GameDock")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.ivory)

            Spacer()

            HStack(spacing: 4) {
                ForEach(nav.panels) { panel in
                    tabButton(panel)
                }
            }

            Spacer()

            if env.library.isScanning {
                ProgressView().controlSize(.small).tint(Theme.amber)
            } else {
                Text("\(env.library.games.count)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.ash)
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .frame(height: 56)
    }

    private func tabButton(_ panel: HomeNavModel.Panel) -> some View {
        let active = nav.currentPanel?.id == panel.id
        return Button {
            env.selectPanel(panel.id)
        } label: {
            VStack(spacing: 4) {
                Text(panel.title.uppercased())
                    .font(Theme.tabLabel)
                    .tracking(1.0)
                    .foregroundStyle(active ? Theme.ivory : Theme.ash)
                Rectangle()
                    .fill(active ? Theme.amber : .clear)
                    .frame(height: 3)
                    .frame(maxWidth: 30)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
        .buttonStyle(.plain)
    }
}
