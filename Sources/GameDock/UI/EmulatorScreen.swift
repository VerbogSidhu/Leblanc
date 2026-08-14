import SwiftUI

/// Fullscreen emulator surface: Metal view + a minimal brand-styled overlay
/// (mono hint pills on a black scrim). B exits, PS opens the quick bar,
/// Share toggles Discord — routed by AppEnvironment.
struct EmulatorScreen: View {
    @EnvironmentObject var env: AppEnvironment
    let session: EmulatorSession

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
                    hintPill("B · QUIT")
                        .padding(20)
                }
                Spacer()
                HStack(spacing: 10) {
                    hintPill("PS · QUICK BAR")
                    hintPill("SHARE · DISCORD")
                }
                .padding(.bottom, 22)
            }
            .allowsHitTesting(false)
        }
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
}
