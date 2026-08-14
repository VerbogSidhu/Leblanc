import SwiftUI

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch env.screen {
            case .home:
                home
            case .settings:
                Text("Settings")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.textPrimary)
            case .emulator:
                Text("Emulator")
                    .font(Theme.titleFont)
                    .foregroundStyle(Theme.textPrimary)
            }

            if env.quickBarVisible {
                Text("QuickBar")
                    .padding()
                    .background(Theme.panelRaised)
                    .zIndex(10)
            }

            if let error = env.errorMessage {
                VStack {
                    Text(error).font(Theme.captionFont).foregroundStyle(.white)
                        .padding(12)
                        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { env.dismissError() }
                    Spacer()
                }
                .padding(.top, 24)
                .zIndex(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var home: some View {
        VStack(spacing: 12) {
            Text("GameDock")
                .font(Theme.titleFont)
                .foregroundStyle(Theme.textPrimary)

            if env.library.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning libraries…")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
            } else if env.library.isEmpty {
                Text("No games found. Add ROM folders in Settings, or make sure Steam is installed.")
                    .font(Theme.hintFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            } else {
                VStack(spacing: 6) {
                    Text("Steam: \(env.library.steamGames.count)")
                    Text("PSP: \(env.library.pspGames.count)")
                    Text("DS: \(env.library.dsGames.count)")
                    Text("Recent: \(env.library.recentGames.count)")
                }
                .font(Theme.hintFont)
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
