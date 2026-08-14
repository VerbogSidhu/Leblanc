import SwiftUI

/// Fullscreen emulator surface: Metal view + overlay with the running game's
/// title and controller hints. Input routing happens in AppEnvironment
/// (B exits, PS opens the quick bar, Share toggles Discord).
struct EmulatorScreen: View {
    @EnvironmentObject var env: AppEnvironment
    let session: EmulatorSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EmulatorView(session: session)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Text(session.title)
                        .font(Theme.sectionFont)
                        .foregroundStyle(Theme.textPrimary)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                    Spacer()
                    hintPill("B · quit")
                }
                Spacer()
                HStack(spacing: 12) {
                    hintPill("PS · quick bar")
                    hintPill("Share · Discord")
                }
            }
            .padding(24)
            .allowsHitTesting(false)
        }
    }

    private func hintPill(_ text: String) -> some View {
        Text(text)
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }
}
