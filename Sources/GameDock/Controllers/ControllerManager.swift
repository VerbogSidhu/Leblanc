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

    /// Fired on right-stick Y changes (up positive), for overlay scrolling
    /// (Discord message pane).
    var onRightStickY: ((Float) -> Void)?
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
                self?.disconnect(controller)
            }
        })

        // Already-connected controllers (e.g. paired before launch).
        for controller in GCController.controllers() {
            connect(controller)
        }

        startKeyboardMonitoring()
        Log.info("ControllerManager: started — \(GCController.controllers().count) controller(s) attached")
    }

    private func disconnect(_ controller: GCController) {
        Log.info("ControllerManager: controller disconnected")
        // Kill any in-flight auto-repeat so a mid-hold disconnect can't leave
        // a pacer firing forever, and clear stick-nav hysteresis state.
        for pacer in repeaters.values { pacer.stop() }
        repeaters.removeAll()
        stickNavState = (false, false)
        activeController = nil
        connectedControllerName = nil
        buttonInventory = []
        snapshot.reset(port: 0)
        Haptics.removeEngines(for: controller)
        // Single-pad policy: hand input to another still-connected pad.
        if let next = GCController.controllers().first {
            connect(next)
        }
    }

    // MARK: - Connection

    private func connect(_ controller: GCController) {
        // Single-pad policy: never steal input from the active pad (two pads
        // hooked at once would both write port 0 → ghost input).
        if let current = activeController, current !== controller {
            Log.info("ControllerManager: ignoring \(controller.productCategory) — \(current.productCategory) already active")
            return
        }
        guard let pad = controller.extendedGamepad else {
            Log.warn("ControllerManager: \(controller.productCategory) has no extended gamepad — ignoring")
            return
        }
        activeController = controller
        connectedControllerName = controller.productCategory
        // A key may have been held when the pad took over — clear any latched
        // keyboard state so nothing sticks.
        snapshot.reset(port: 0)

        // macOS reserves the PS/Home button by default (Launchpad Games folder /
        // app switcher). Disable that per-controller so the press routes to us.
        disableHomeSystemGesture(controller)

        hook(pad, controller: controller)
        logButtonInventory(controller)
        Log.info("ControllerManager: connected \(controller.productCategory)")
    }

    /// Frees the PS/Home button from macOS's reserved gestures. Must be called
    /// on every connect — it is a per-controller-instance setting.
    private func disableHomeSystemGesture(_ controller: GCController) {
        if let home = controller.physicalInputProfile.buttons[GCInputButtonHome] {
            home.preferredSystemGestureState = .disabled
            Log.info("ControllerManager: home button system gesture disabled (isBoundToSystemGesture=\(home.isBoundToSystemGesture))")
        } else {
            Log.warn("ControllerManager: no GCInputButtonHome element found for \(controller.productCategory)")
        }
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

        // Shoulders: L1/R1 switch launcher panels in the UI (and remain the
        // L/R buttons for cores via the snapshot).
        pad.leftShoulder.pressedChangedHandler = buttonHandler(libretroID: 10, uiAction: .previousPanel)
        pad.rightShoulder.pressedChangedHandler = buttonHandler(libretroID: 11, uiAction: .nextPanel)
        pad.leftTrigger.pressedChangedHandler = buttonHandler(libretroID: 12, uiAction: .toggleMute)
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
            // Right stick drives the Discord overlay scroll (up positive).
            if stickIndex == 1 {
                self.onRightStickY?(s.up.value - s.down.value)
            }
            self.driveStickNav(x: x, y: -y)
        }
        stick.left.valueChangedHandler = { _, _, _ in update(stick) }
        stick.right.valueChangedHandler = { _, _, _ in update(stick) }
        stick.up.valueChangedHandler = { _, _, _ in update(stick) }
        stick.down.valueChangedHandler = { _, _, _ in update(stick) }
    }

    /// Stick-based navigation with hysteresis (crosses 0.65, releases below 0.3).
    /// Held-beyond-threshold keeps auto-repeating through RepeatPacer so a long
    /// list can be scrolled without tapping.
    private static let stickActivateThreshold: Float = 0.65
    private static let stickReleaseThreshold: Float = 0.30

    private func driveStickNav(x: Float, y: Float) {
        if x > Self.stickActivateThreshold && !stickNavState.x {
            stickNavState.x = true
            uiReceiver?.gamepad(.right)
            beginRepeat(action: .right, key: Self.stickRepeatKey("right"), fireNow: false)
        } else if x < -Self.stickActivateThreshold && !stickNavState.x {
            stickNavState.x = true
            uiReceiver?.gamepad(.left)
            beginRepeat(action: .left, key: Self.stickRepeatKey("left"), fireNow: false)
        } else if abs(x) < Self.stickReleaseThreshold {
            if stickNavState.x {
                stopRepeat(Self.stickRepeatKey("right"))
                stopRepeat(Self.stickRepeatKey("left"))
            }
            stickNavState.x = false
        }
        if y > Self.stickActivateThreshold && !stickNavState.y {
            stickNavState.y = true
            uiReceiver?.gamepad(.up)
            beginRepeat(action: .up, key: Self.stickRepeatKey("up"), fireNow: false)
        } else if y < -Self.stickActivateThreshold && !stickNavState.y {
            stickNavState.y = true
            uiReceiver?.gamepad(.down)
            beginRepeat(action: .down, key: Self.stickRepeatKey("down"), fireNow: false)
        } else if abs(y) < Self.stickReleaseThreshold {
            if stickNavState.y {
                stopRepeat(Self.stickRepeatKey("up"))
                stopRepeat(Self.stickRepeatKey("down"))
            }
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
        let pad = controller.extendedGamepad

        var psButton: GCControllerButtonInput? = nil
        var shareButton: GCControllerButtonInput? = nil

        // Canonical Home element first (now that the system gesture is off).
        psButton = profile.buttons[GCInputButtonHome]

        if psButton == nil {
            if let menu = profile.buttons["Menu"] ?? profile.buttons["Button Menu"] {
                psButton = menu
            } else {
                psButton = pad?.buttonMenu
            }
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

        // The probe above can land on the same element hook() already mapped
        // to Select (buttonMenu → id 2) or Start (buttonOptions → id 3).
        // Assigning a plain system handler would REPLACE that core mapping,
        // so detect the collision and install a combined handler instead.
        let selectElement = pad?.buttonMenu     // libretro id 2
        let startElement = pad?.buttonOptions   // libretro id 3
        func install(_ button: GCControllerButtonInput?, systemAction: GamepadUIAction) {
            guard let button else { return }
            let coreID: Int? = button === selectElement ? 2 : (button === startElement ? 3 : nil)
            if let coreID {
                Log.info("ControllerManager: system button overlaps Start/Select — installing combined handler")
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    self?.snapshot.setButton(port: 0, id: coreID, pressed: pressed)
                    if pressed { self?.uiReceiver?.gamepad(systemAction) }
                }
            } else {
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    if pressed { self?.uiReceiver?.gamepad(systemAction) }
                }
            }
        }
        install(psButton, systemAction: .openQuickBar)
        install(shareButton, systemAction: .toggleDiscord)

        // DualSense touchpad click → screenshot.
        if let touchpad = profile.buttons.first(where: { ($0.key + $0.value.aliases.joined()).lowercased().contains("touchpad") })?.value {
            touchpad.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed { self?.uiReceiver?.gamepad(.captureScreenshot) }
            }
            Log.info("ControllerManager: touchpad click mapped to screenshot")
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
            let key = Self.buttonRepeatKey(libretroID)
            if pressed {
                if let action = uiAction {
                    self.beginRepeat(action: action, key: key, fireNow: true)
                }
            } else {
                self.stopRepeat(key)
            }
        }
    }

    // MARK: - Hold-to-repeat

    /// UI actions that auto-repeat while their button/stick stays held:
    /// d-pad nav, L1/R1 panel switching, quick-bar volume (left/right).
    /// Confirm/back stay edge-triggered so a held button can never
    /// double-activate a launch.
    private static let repeatableActions: Set<GamepadUIAction> = [
        .up, .down, .left, .right, .previousPanel, .nextPanel
    ]

    /// Initial hold delay + repeat cadence (standard console feel).
    private static let repeatInitialDelay: TimeInterval = 0.40
    private static let repeatInterval: TimeInterval = 0.08

    private static func buttonRepeatKey(_ id: Int) -> String { "btn-\(id)" }
    private static func stickRepeatKey(_ direction: String) -> String { "stick-\(direction)" }

    /// Active repeaters keyed by button id / stick direction.
    private var repeaters: [String: RepeatPacer] = [:]

    /// Fires `action` now (when requested) and keeps firing it at the repeat
    /// cadence until `stopRepeat` is called. Non-repeatable actions fire once.
    private func beginRepeat(action: GamepadUIAction, key: String, fireNow: Bool) {
        stopRepeat(key)
        if fireNow { uiReceiver?.gamepad(action) }
        guard Self.repeatableActions.contains(action) else { return }
        let pacer = RepeatPacer()
        pacer.start(initialDelay: Self.repeatInitialDelay, interval: Self.repeatInterval) { [weak self] in
            self?.uiReceiver?.gamepad(action)
        }
        repeaters[key] = pacer
    }

    private func stopRepeat(_ key: String) {
        repeaters.removeValue(forKey: key)?.stop()
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
        // Console-level UI keys work even while a gamepad owns the input
        // ports — they're UI shortcuts, not joypad state.
        if isDown, !event.isARepeat {
            switch event.keyCode {
            case 122: uiReceiver?.gamepad(.openQuickBar)  // F1 → PS
            case 120: uiReceiver?.gamepad(.toggleDiscord) // F2 → Share
            case 48:  // Tab → panel switch (Shift+Tab = backwards)
                if event.modifierFlags.contains(.shift) {
                    uiReceiver?.gamepad(.nextPanel)
                } else {
                    uiReceiver?.gamepad(.previousPanel)
                }
            default: break
            }
        }

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
    }
}

/// Fires `tick` on the main run loop at a fixed interval after an initial
/// delay — the standard hold-to-repeat cadence (e.g. 0.4 s hold, then every
/// 0.08 s) for d-pad/stick navigation.
private final class RepeatPacer {
    private var timer: Timer?

    func start(initialDelay: TimeInterval, interval: TimeInterval, tick: @escaping () -> Void) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        timer.tolerance = 0.01
        timer.fireDate = Date().addingTimeInterval(initialDelay)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
