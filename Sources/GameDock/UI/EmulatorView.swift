import SwiftUI

/// SwiftUI wrapper around the Metal-based emulator view, plus controller
/// overlay hints. Session wiring (steam/rom launcher integration) lands in a
/// later milestone; this view is driven by an explicitly-provided session.
struct EmulatorView: NSViewRepresentable {
    var session: EmulatorSession?

    func makeNSView(context: Context) -> EmulatorMetalView {
        let view = EmulatorMetalView(frame: .zero)
        view.frameSlot = session?.frameSlot
        return view
    }

    func updateNSView(_ nsView: EmulatorMetalView, context: Context) {
        nsView.frameSlot = session?.frameSlot
    }
}

/// Lightweight overlay hint bar (pure SwiftUI); wired to gamepad UI actions
/// by the surrounding screen in a later milestone.
struct EmulatorOverlay: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Button("PS") {}
                Spacer()
                Button("Share") {}
                Spacer()
                Button("Back") {}
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }
}
