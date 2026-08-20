import SwiftUI

struct RootView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            if env.errorMessage != nil {
                errorBanner
                    .zIndex(20)
            }

            // Modal confirmation for destructive actions (folder removal).
            if let confirmation = env.pendingConfirmation {
                ConfirmationOverlay(confirmation: confirmation)
                    .zIndex(25)
            }

            // "Capture saved" confirmation (touchpad screenshot), any screen.
            CaptureToastView(model: env.captureToasts)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
                .zIndex(30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The declared transitions only run if the container animates the
        // insertion/removal — scope it to each overlay's visibility flag.
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.spring, value: env.quickBarVisible)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.spring, value: env.pendingConfirmation != nil)
        .animation(.easeInOut(duration: 0.2), value: env.errorMessage)
    }

    private var errorBanner: some View {
        VStack {
            HStack(alignment: .top, spacing: 10) {
                Text(env.errorMessage ?? "")
                    .font(Theme.body)
                    .foregroundStyle(Theme.paper)
                Button {
                    env.dismissError()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(30)
            .transition(.move(edge: .top).combined(with: .opacity))
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
