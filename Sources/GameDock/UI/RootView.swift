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

            if env.activeError != nil {
                errorBanner(env.activeError!)
                    .zIndex(20)
            }

            // "Starting…" handoff overlay (Steam/PPSSPP launch).
            if env.isLaunching {
                StartingOverlay()
                    .zIndex(15)
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
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.spring, value: env.activeError)
    }

    private func errorBanner(_ error: AppError) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon(for: error.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color(for: error.kind))
            Text(error.message)
                .font(Theme.body)
                .foregroundStyle(Theme.paper)
            Button {
                env.dismissError()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.mist)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.ink.opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color(for: error.kind).opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.bottom, 24)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private func icon(for kind: AppError.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    private func color(for kind: AppError.Kind) -> Color {
        switch kind {
        case .info: return Theme.signal
        case .warn: return Theme.ember
        case .error: return Theme.error
        }
    }
}

/// Full-screen ink overlay shown during a game handoff launch.
struct StartingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.regular).tint(Theme.signal)
            Text("Starting…")
                .font(GameDockFonts.display(22, weight: .semibold))
                .foregroundStyle(Theme.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.void.opacity(0.9).ignoresSafeArea())
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { appear = true }
        }
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
