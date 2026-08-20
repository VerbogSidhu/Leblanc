import SwiftUI

/// Fullscreen emulator surface: Metal view + a minimal brand-styled overlay
/// (mono hint pills on a black scrim). B exits, PS opens the quick bar,
/// Share toggles Discord — routed by AppEnvironment.
struct EmulatorScreen: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var toasts: RAToastModel
    let session: EmulatorSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EmulatorView(session: session)
                .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    Text(session.title)
                        .font(.system(size: 26, weight: .bold, design: .default))
                        .foregroundStyle(Theme.paper)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.8), radius: 8)
                        .padding(20)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        if let toast = toasts.current {
                            toastPill(toast)
                        }
                        if env.coreOptionsVisible || env.pauseMenuVisible {
                            HStack(spacing: 6) {
                                Rectangle().fill(Theme.signal).frame(width: 8, height: 8)
                                Text("PAUSED")
                            }
                            .font(GameDockFonts.data(11))
                            .tracking(1.5)
                            .foregroundStyle(Theme.signal)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: Capsule())
                            .overlay(Capsule().stroke(Theme.signal.opacity(0.4), lineWidth: 1))
                        }
                        hintPill("CIRCLE · PAUSE")
                    }
                    .padding(20)
                }
                Spacer()
                HStack(spacing: 10) {
                    hintPill("PS · QUICK BAR")
                    hintPill("SHARE · DISCORD")
                    hintPill("TOUCHPAD · CAPTURE")
                }
                .padding(.bottom, 22)
            }
            .allowsHitTesting(false)

            // Core-options overlay (emulation is paused while open).
            if env.coreOptionsVisible {
                CoreOptionsOverlay(model: session.coreOptions)
                    .transition(.opacity)
            }

            // In-game pause menu (Circle/back).
            if env.pauseMenuVisible {
                PauseMenuOverlay(model: env.pauseMenu) { item in
                    env.pauseMenuAction(item)
                }
                .transition(.opacity)
            }
        }
        // Scope animations to each overlay's insertion so the declared
        // transitions actually run (otherwise they're hard cuts).
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.spring, value: env.coreOptionsVisible)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.spring, value: env.pauseMenuVisible)
        // Screen enter/exit crossfade (4.1) — the screen value change animates
        // the whole surface fading in.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: env.screen)
    }

    private func hintPill(_ text: String) -> some View {
        Text(text)
            .font(Theme.body)
            .tracking(1.2)
            .foregroundStyle(Theme.paper.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private func toastPill(_ toast: RAToast) -> some View {
        let prefix: String
        switch toast.kind {
        case .achievement: prefix = "ACHIEVEMENT UNLOCKED"
        case .gameCompleted: prefix = "GAME COMPLETED"
        default: prefix = ""
        }
        return VStack(alignment: .trailing, spacing: 2) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font(Theme.body)
                    .tracking(1.0)
                    .foregroundStyle(Theme.signal)
            }
            Text(toast.title)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(Theme.paper)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.signal.opacity(0.4), lineWidth: 1))
        .transition(.opacity)
    }
}
