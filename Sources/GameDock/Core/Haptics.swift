import CoreHaptics
import GameController

/// DualSense haptics — a short transient tick on category/item change.
/// Engines are cached per controller; best-effort (silently no-op when
/// unavailable).
enum Haptics {
    private static var engines: [ObjectIdentifier: CHHapticEngine] = [:]

    static func tick() {
        for controller in GCController.controllers() {
            let id = ObjectIdentifier(controller)
            let engine: CHHapticEngine
            if let cached = engines[id] {
                engine = cached
            } else {
                guard let created = controller.haptics?.createEngine(withLocality: GCHapticsLocality.default) else { continue }
                engines[id] = created
                engine = created
            }

            do {
                try engine.start()
                let event = CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
                    ],
                    relativeTime: 0
                )
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: 0)
            } catch {
                // Best-effort; ignore pattern/start failures.
            }
        }
    }
}
