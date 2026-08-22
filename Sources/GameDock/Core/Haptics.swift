import CoreHaptics
import GameController

/// DualSense haptics. Engines cached per controller; best-effort (silently
/// no-op when unavailable). Distinct patterns per event so the launcher reads
/// as physically responsive: a light tick on selection, a firmer thump on
/// confirm, a short double for toggles, a low buzz for errors.
enum Haptics {
    enum Feedback {
        case selection   // light tick (nav)
        case confirm     // firmer (launch / activate)
        case toggle      // short double (favorite / settings flip)
        case error       // low blunt buzz
        case pause       // settle (pause menu open/close)
    }

    private static var engines: [ObjectIdentifier: CHHapticEngine] = [:]

    static func tick() { play(.selection) }

    static func play(_ feedback: Feedback) {
        // Engine cache + CHHapticEngine are main-thread state; callers are
        // usually on main already, but don't mutate off-main if not.
        if Thread.isMainThread {
            playOnMain(feedback)
        } else {
            DispatchQueue.main.async { Self.playOnMain(feedback) }
        }
    }

    private static func playOnMain(_ feedback: Feedback) {
        assert(Thread.isMainThread, "Haptics engine mutation must stay on the main thread")
        let events = Self.events(for: feedback)
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
                let pattern = try CHHapticPattern(events: events, parameters: [])
                let player = try engine.makePlayer(with: pattern)
                try player.start(atTime: 0)
            } catch {
                // Best-effort; ignore pattern/start failures.
            }
        }
    }

    /// Drops the cached engine for a controller on disconnect, so repeated
    /// connect/disconnect churn can't grow the engine cache unboundedly.
    static func removeEngines(for controller: GCController) {
        engines.removeValue(forKey: ObjectIdentifier(controller))
    }

    private static func event(intensity: Float, sharpness: Float, time: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    private static func events(for feedback: Feedback) -> [CHHapticEvent] {
        switch feedback {
        case .selection:
            return [event(intensity: 0.35, sharpness: 0.6, time: 0)]
        case .confirm:
            return [event(intensity: 0.7, sharpness: 0.4, time: 0)]
        case .toggle:
            return [event(intensity: 0.5, sharpness: 0.5, time: 0),
                    event(intensity: 0.4, sharpness: 0.5, time: 0.05)]
        case .error:
            return [event(intensity: 0.8, sharpness: 0.1, time: 0),
                    event(intensity: 0.6, sharpness: 0.1, time: 0.06)]
        case .pause:
            return [event(intensity: 0.45, sharpness: 0.8, time: 0)]
        }
    }
}
