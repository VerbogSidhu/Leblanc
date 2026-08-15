import SwiftUI

/// The core-options overlay shown while an emulator is running (opened from
/// PS → Quick Bar → Options). Emulation is paused while it's open.
///
/// Interaction (PlayStation glyph conventions):
///   ▲▼ select · ◀▶ change (applies live) · CIRCLE/PS close
/// There is no separate confirm step — values apply the moment they're cycled
/// (RetroArch quick-menu semantics).
struct CoreOptionsOverlay: View {
    @ObservedObject var model: CoreOptionsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture {} // swallow clicks; controller-driven

            VStack(spacing: 18) {
                Text("Core Options")
                    .font(GameDockFonts.display(26, weight: .bold))
                    .foregroundStyle(Theme.paper)

                if model.rows.isEmpty {
                    Text("This core exposes no options.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.mist)
                        .padding(.vertical, 40)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { idx, row in
                            optionRow(row, selected: idx == model.cursor)
                        }
                    }

                    // Trailing reset row: resets THIS game's saved overrides
                    // back to the core's defaults (Confirm activates it).
                    if !model.rows.isEmpty {
                        resetRow(selected: model.cursorIsOnResetRow)
                            .padding(.top, 8)
                    }
                }

                Text("▲▼ SELECT · ◀▶ CHANGE · CIRCLE/PS CLOSE")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.mist)
                    .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 620)
            .background(Theme.ink.opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.mist.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30)
        }
        .animation(reduceMotion ? nil : Theme.spring, value: model.cursor)
    }

    /// "Reset to defaults" — clears this game's saved option overrides and
    /// reseeds from the core's defaults. Confirm activates it (any other row:
    /// confirm closes the overlay).
    private func resetRow(selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise")
            Text("Reset to defaults")
            Spacer()
            Text("CONFIRM")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Theme.void : Theme.mist)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selected ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(Theme.ink.opacity(0.6)), in: Capsule())
        }
        .font(Theme.body)
        .foregroundStyle(selected ? Theme.paper : Theme.mist)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? Theme.signal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.signal.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.activateResetRow() }
    }

    private func optionRow(_ row: CoreOptionsModel.Row, selected: Bool) -> some View {
        HStack {
            Text(row.title)
                .font(Theme.body)
                .foregroundStyle(selected ? Theme.paper : Theme.mist)
            Spacer()
            Text(row.values[row.selectedIndex])
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Theme.void : Theme.signal)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(Theme.signal) : AnyShapeStyle(Theme.ink.opacity(0.6)), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selected ? Theme.signal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.signal.opacity(0.6) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
    }
}
