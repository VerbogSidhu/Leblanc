import AppKit
import Combine
import GameController

/// Bridges GameController (DualSense first-class, others via the same
/// abstraction) and a keyboard fallback into:
///   • InputSnapshot (continuous state → libretro cores)
///   • GamepadUIAction stream (discrete nav → UI)
///
/// The GamepadInput protocol layer lives in GamepadInput.swift; this class is
/// the concrete GameController implementation. Adding e.g. an Xbox profile
/// means hooking the same InputSnapshot/UIAction sink, not rewriting the app.
final class ControllerManager {
    weak var uiReceiver: GamepadUIReceiver?
    let snapshot = InputSnapshot()

    @Published private(set) var connectedControllerName: String?
    @Published private(set) var buttonInventory: [String] = []

    private var observers: [Any] = []
    private var activeController: GCController?

    /// Keyboard fallback only drives input while no physical controller is
    /// connected (prevents double input on the shared port 0).
    private var keyboardDrivesInput: Bool { activeController == nil }

    private var stickNavState = (x: Bool, y: Bool)(false, false)

    // MARK: - Lifecycle

    func start() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            if let controller = note.object as? GCController {
                self?.connect(controller)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            if let controller = note.object as? GCController, controller == self?.activeController {
                self?.disconnect()
            }
        })

        // Already-connected controllers (e.g. paired before launch).
        for controller in GCController.controllers() {
            connect(controller)
        }

        startKeyboardMonitoring()
        Log.info("ControllerManager: started — \(GCController.controllers().count) controller(s) attached")
    }

    private func disconnect() {
        Log.info("ControllerManager: controller disconnected")
        activeController = nil
        connectedControllerName = nil
        buttonInventory = []
        snapshot.reset(port: 0)
    }

    // MARK: - Connection

    private func connect(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else {
            Log.warn("ControllerManager: \(controller.productCategory) has no extended gamepad — ignoring")
            return
        }
        controller.playerIndex = .index1
        activeController = controller
        connectedControllerName = controller.productCategory
        hook(pad, controller: controller)
        logButtonInventory(controller)
        Log.info("ControllerManager: connected \(controller.productCategory)")
    }

    private func hook(_ pad: GCExtendedGamepad, controller: GCController) {
        // Face buttons: DualSense Cross/Circle/Square/Triangle → A/B/X/Y.
        pad.buttonA.pressedChangedHandler = buttonHandler(libretroID: 8, uiAction: .confirm)
        pad.buttonB.pressedChangedHandler = buttonHandler(libretroID: 0, uiAction: .back)
        pad.buttonX.pressedChangedHandler = buttonHandler(libretroID: 9, uiAction: nil)
        pad.buttonY.pressedChangedHandler = buttonHandler(libretroID: 1, uiAction: nil)

        // D-pad → joypad + nav.
        pad.dpad.up.pressedChangedHandler = buttonHandler(libretroID: 4, uiAction: .up)
        pad.dpad.down.pressedChangedHandler = buttonHandler(libretroID: 5, uiAction: .down)
        pad.dpad.left.pressedChangedHandler = buttonHandler(libretroID: 6, uiAction: .left)
        pad.dpad.right.pressedChangedHandler = buttonHandler(libretroID: 7, uiAction: .right)

        // Shoulders / triggers.
        pad.leftShoulder.pressedChangedHandler = buttonHandler(libretroID: 10, uiAction: nil)
        pad.rightShoulder.pressedChangedHandler = buttonHandler(libretroID: 11, uiAction: nil)
        pad.leftTrigger.pressedChangedHandler = buttonHandler(libretroID: 12, uiAction: nil)
        pad.rightTrigger.pressedChangedHandler = buttonHandler(libretroID: 13, uiAction: nil)

        // Thumbstick clicks.
        pad.leftThumbstickButton?.pressedChangedHandler = buttonHandler(libretroID: 14, uiAction: nil)
        pad.rightThumbstickButton?.pressedChangedHandler = buttonHandler(libretroID: 15, uiAction: nil)

        // Sticks → analog snapshot + secondary nav (with hysteresis).
        hookStick(pad.leftThumbstick, port: 0, stickIndex: 0)
        hookStick(pad.rightThumbstick, port: 0, stickIndex: 1)

        // Start/Select.
        pad.buttonOptions?.pressedChangedHandler = buttonHandler(libretroID: 3, uiAction: nil) // Options → Start
        pad.buttonMenu.pressedChangedHandler = buttonHandler(libretroID: 2, uiAction: nil)      // Menu → Select

        // PS button (quick bar) and Share button (Discord). These aren't part
        // of the standard extended-gamepad surface; probe the physical profile.
        hookSystemButtons(controller: controller)
    }

    private func hookStick(_ stick: GCControllerDirectionPad, port: Int, stickIndex: Int) {
        let update: (GCControllerDirectionPad) -> Void = { s in
            // Use the directional buttons (0...1) to derive X/Y — this sidesteps
            // GameController's axis sign conventions entirely.
            let x = s.right.value - s.left.value
            // libretro analog Y: UP is negative (DirectInput convention), so
            // snapshot Y is inverted relative to the raw up/down delta.
            let y = s.down.value - s.up.value
            self.snapshot.setStick(port: port, stick: stickIndex, axis: 0, value: x)
            self.snapshot.setStick(port: port, stick: stickIndex, axis: 1, value: y)
            self.driveStickNav(x: x, y: -y)
        }
        stick.left.valueChangedHandler = { _, _, _ in update(stick) }
        stick.right.valueChangedHandler = { _, _, _ in update(stick) }
        stick.up.valueChangedHandler = { _, _, _ in update(stick) }
        stick.down.valueChangedHandler = { _, _, _ in update(stick) }
    }

    /// Stick-based navigation with hysteresis (crosses 0.65, releases below 0.3).
    private func driveStickNav(x: Float, y: Float) {
        if x > 0.65 && !stickNavState.x {
            stickNavState.x = true
            uiReceiver?.gamepad(.right)
        } else if x < -0.65 && !stickNavState.x {
            stickNavState.x = true
            uiReceiver?.gamepad(.left)
        } else if abs(x) < 0.3 {
            stickNavState.x = false
        }
        if y > 0.65 && !stickNavState.y {
            stickNavState.y = true
            uiReceiver?.gamepad(.up)
        } else if y < -0.65 && !stickNavState.y {
            stickNavState.y = true
            uiReceiver?.gamepad(.down)
        } else if abs(y) < 0.3 {
            stickNavState.y = false
        }
    }

    // MARK: - PS / Share probing

    /// GameController does not reliably expose the DualSense PS/Share buttons
    /// as typed properties, so we probe the physical input profile by name and
    /// fall back to buttonMenu/buttonOptions. Logs the full inventory so a
    /// specific device's layout can be diagnosed (--diagnose-input).
    private func hookSystemButtons(controller: GCController) {
        let profile = controller.physicalInputProfile

        var psButton: GCControllerButtonInput? = nil
        var shareButton: GCControllerButtonInput? = nil

        if let menu = profile.buttons["Menu"] ?? profile.buttons["Button Menu"] {
            psButton = menu
        } else {
            psButton = controller.extendedGamepad?.buttonMenu
        }

        // Name-based probing across aliases.
        let buttons = profile.buttons
        for (name, element) in buttons {
            let haystack = ([name] + element.aliases).joined(separator: " ").lowercased()
            if psButton == nil, haystack.contains("ps"), haystack.contains("menu") || haystack.contains("home") || haystack.contains("system") {
                psButton = element
            }
            if shareButton == nil, haystack.contains("share") || haystack.contains("create") {
                shareButton = element
            }
        }

        psButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.uiReceiver?.gamepad(.openQuickBar) }
        }
        shareButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.uiReceiver?.gamepad(.toggleDiscord) }
        }
    }

    private func logButtonInventory(_ controller: GCController) {
        var names: [String] = []
        let buttons = controller.physicalInputProfile.buttons
        names = buttons.keys.sorted()
        buttonInventory = names
        Log.info("ControllerManager: button inventory: \(names.joined(separator: ", "))")
    }

    // MARK: - Shared handler

    private func buttonHandler(libretroID: Int, uiAction: GamepadUIAction?) -> (GCControllerButtonInput, Float, Bool) -> Void {
        { [weak self] _, _, pressed in
            guard let self else { return }
            self.snapshot.setButton(port: 0, id: libretroID, pressed: pressed)
            if pressed, let action = uiAction {
                self.uiReceiver?.gamepad(action)
            }
        }
    }

    // MARK: - Keyboard fallback

    private func startKeyboardMonitoring() {
        let down = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event, isDown: true)
            return event
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKey(event, isDown: false)
            return event
        }
        if let down { observers.append(down) }
        if let up { observers.append(up) }
    }

    private func handleKey(_ event: NSEvent, isDown: Bool) {
        guard keyboardDrivesInput else { return }
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return }
        let repeats = event.isARepeat

        // Map key → (libretro id, ui action). Keyboard drives port 0.
        func send(_ id: Int, _ action: GamepadUIAction?) {
            snapshot.setButton(port: 0, id: id, pressed: isDown)
            if isDown, !repeats, let action { uiReceiver?.gamepad(action) }
        }

        switch chars {
        case "\u{1B}": // Esc → back
            if isDown, !repeats { uiReceiver?.gamepad(.back) }
        case "\r", "\n": send(8, .confirm)              // Enter → A
        case "z": send(8, .confirm)                     // Z → A
        case "x": send(0, .back)                        // X → B
        case "a": send(9, nil)                          // A → X
        case "s": send(1, nil)                          // S → Y
        case "q": send(10, nil)                         // Q → L
        case "e": send(11, nil)                         // E → R
        case "1": send(12, nil)                         // 1 → L2
        case "3": send(13, nil)                         // 3 → R2
        case "\u{7F}", "\u{08}": send(2, nil)         // Backspace → Select
        default: break
        }

        // Arrow keys & WASD → dpad.
        switch event.keyCode {
        case 123: send(6, .left)
        case 124: send(7, .right)
        case 125: send(5, .down)
        case 126: send(4, .up)
        default:
            switch chars {
            case "w": send(4, .up)
            case "s": send(5, .down)
            case "a": send(6, .left)
            case "d": send(7, .right)
            default: break
            }
        }

        // F-keys for the console buttons.
        if isDown, !repeats {
            switch event.keyCode {
            case 122: uiReceiver?.gamepad(.openQuickBar)  // F1 → PS
            case 120: uiReceiver?.gamepad(.toggleDiscord) // F2 → Share
            default: break
            }
        }
    }
}
