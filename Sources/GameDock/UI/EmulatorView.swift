import SwiftUI

/// SwiftUI wrapper around the Metal-based emulator view. Session wiring lives
/// in AppEnvironment; this view just hosts the Metal surface for a session.
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
