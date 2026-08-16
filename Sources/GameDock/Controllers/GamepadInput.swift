import Foundation

/// Discrete UI actions derived from gamepad (or keyboard) input.
/// These drive navigation; the emulator reads the continuous InputSnapshot.
enum GamepadUIAction: Equatable, Hashable {
    case up
    case down
    case left
    case right
    case confirm
    case back
    case openQuickBar     // PS button
    case toggleDiscord    // Share button
    case previousPanel    // L1
    case nextPanel        // R1
    case toggleMute       // L2 (while quick bar open)
    case captureScreenshot // DualSense touchpad click
}

/// Receives discrete UI actions (navigation, PS, Share).
protocol GamepadUIReceiver: AnyObject {
    func gamepad(_ action: GamepadUIAction)
}

/// Thread-safe snapshot of controller state, written on the main thread by
/// ControllerManager and read on the emulator's core thread by the libretro
/// input callbacks.
final class InputSnapshot {
    static let maxPorts = 4

    private let lock = NSLock()

    /// Per-port bitmask of libretro joypad button ids (RETRO_DEVICE_ID_JOYPAD_*).
    private var buttons: [UInt32] = Array(repeating: 0, count: maxPorts)

    /// Per-port analog state, indexed [stick][axis]:
    /// stick: 0 = left, 1 = right; axis: 0 = X, 1 = Y. Range [-1, 1].
    private var analog: [[(x: Float, y: Float)]] = Array(
        repeating: [(0, 0), (0, 0)],
        count: maxPorts
    )

    // MARK: - Writers (main thread)

    func setButton(port: Int, id: Int, pressed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard port < buttons.count, (0...31).contains(id) else { return }
        if pressed {
            buttons[port] |= 1 << UInt32(id)
        } else {
            buttons[port] &= ~(1 << UInt32(id))
        }
    }

    /// value in [-1, 1]. stick: 0 = left, 1 = right. axis: 0 = X, 1 = Y.
    func setStick(port: Int, stick: Int, axis: Int, value: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard port < analog.count, (0...1).contains(stick), (0...1).contains(axis) else { return }
        let clamped = min(max(value, -1), 1)
        if axis == 0 {
            analog[port][stick].x = clamped
        } else {
            analog[port][stick].y = clamped
        }
    }

    func reset(port: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard port < buttons.count else { return }
        buttons[port] = 0
        analog[port][0] = (0, 0)
        analog[port][1] = (0, 0)
    }

    // MARK: - Readers (core thread)

    /// Returns 1 when the given joypad button is held, else 0.
    func readButton(port: Int, id: Int) -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        guard port < buttons.count, (0...31).contains(id) else { return 0 }
        return (buttons[port] & (1 << UInt32(id))) != 0 ? 1 : 0
    }

    /// Returns the analog value scaled to libretro's [-0x8000, 0x7FFF] range.
    func readAnalog(port: Int, stick: Int, axis: Int) -> Int16 {
        lock.lock()
        defer { lock.unlock() }
        guard port < analog.count, (0...1).contains(stick), (0...1).contains(axis) else { return 0 }
        let v = axis == 0 ? analog[port][stick].x : analog[port][stick].y
        return Int16(clamping: Int(v * 0x7FFF))
    }
}
