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
                    EmulatorScreen(toasts: session.raToasts, session: session)
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

            // "Capture saved" confirmation (touchpad screenshot), any screen.
            CaptureToastView(model: env.captureToasts)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
                .zIndex(30)
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

/// A small transient confirmation pill shown when a screenshot is saved.
/// Observes its own model so the root view doesn't need to forward publishes.
struct CaptureToastView: View {
    @ObservedObject var model: RAToastModel

    var body: some View {
        Group {
            if let toast = model.current {
                Text(toast.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.paper)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.ink.opacity(0.95), in: Capsule())
                    .overlay(Capsule().stroke(Theme.signal.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.current?.id)
    }
}
