import SwiftUI

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        ZStack {
            Theme.void.ignoresSafeArea()

            switch env.screen {
            case .home:
                HomeView(nav: env.homeNav)
            case .settings:
                SettingsView(model: env.settingsNav)
            case .emulator:
                if let session = env.emulator {
                    EmulatorScreen(session: session)
                } else {
                    // Session failed between screen switch and view build.
                    HomeView(nav: env.homeNav)
                }
            }

            if env.quickBarVisible {
                QuickBarView(model: env.quickBarModel)
                    .zIndex(10)
            }

            if let error = env.errorMessage {
                VStack {
                    HStack(alignment: .top, spacing: 10) {
                        Text(error)
                            .font(Theme.hintFont)
                            .foregroundStyle(.white)
                        Button {
                            env.dismissError()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(14)
                    .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 40)
                    Spacer()
                }
                .padding(.top, 24)
                .zIndex(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
