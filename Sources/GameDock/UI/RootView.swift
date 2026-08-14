import SwiftUI

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        ZStack {
            switch env.screen {
            case .xmb:
                XMBView(nav: env.xmb)
            case .emulator:
                if let session = env.emulator {
                    EmulatorScreen(session: session)
                } else {
                    XMBView(nav: env.xmb)
                }
            }

            // PS quick bar: slides in from the top as a translucent strip.
            if env.quickBarVisible {
                QuickBarView(model: env.quickBarModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(10)
            }

            if let error = env.errorMessage {
                errorBanner(error)
                    .zIndex(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack {
            HStack(alignment: .top, spacing: 10) {
                Text(message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.paper)
                Button { env.dismissError() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(30)
            Spacer()
        }
        .padding(.top, 20)
    }
}
