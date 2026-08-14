import SwiftUI

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch env.screen {
            case .home:
                Text("GameDock — library loading…")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.textPrimary)
            case .settings:
                Text("Settings")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.textPrimary)
            case .emulator:
                Text("Emulator")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
