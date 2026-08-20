import SwiftUI

/// Modal confirmation for destructive actions (ROM folder removal, resets).
/// Controller-driven: Confirm proceeds, Circle/PS dismisses (AppEnvironment
/// routes input before anything else while this is showing).
struct ConfirmationOverlay: View {
    let confirmation: PendingConfirmation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture {} // swallow clicks; controller-driven

            VStack(alignment: .leading, spacing: 16) {
                Text(confirmation.title)
                    .font(GameDockFonts.display(24, weight: .bold))
                    .foregroundStyle(Theme.paper)

                Text(confirmation.message)
                    .font(Theme.body)
                    .foregroundStyle(Theme.mist)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    actionPill(icon: "xmark", label: confirmation.confirmLabel,
                               filled: true, accent: Theme.ember)
                    actionPill(icon: "circle", label: "Cancel",
                               filled: false, accent: Theme.signal)
                }
                .padding(.top, 6)
            }
            .padding(26)
            .frame(maxWidth: 500)
            .background(Theme.ink.opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.mist.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Glyph pills mirroring the DualSense confirm/back buttons. Static (the
    /// selection is fixed): ✕ = confirm, ○ = cancel.
    private func actionPill(icon: String, label: String, filled: Bool, accent: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(filled ? Theme.void : Theme.paper)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(filled ? AnyShapeStyle(accent) : AnyShapeStyle(Theme.ink.opacity(0.6)), in: Capsule())
        .overlay(Capsule().stroke(filled ? .clear : accent.opacity(0.5), lineWidth: 1))
    }
}
