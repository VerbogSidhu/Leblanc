---
name: leblanc-controller-input
description: DualSense/GameController input wiring in Leblanc — InputSnapshot, GamepadUIAction routing, PS/Share/touchpad probing, keyboard fallback, stick navigation, and haptics. Use when adding, debugging, or remapping controller features.
---

# Leblanc — Controller Input

Two layers (see `Sources/GameDock/Controllers/GamepadInput.swift` and
`ControllerManager.swift`):

- **InputSnapshot** — continuous state the libretro core reads on the core
  thread (NSLock-protected; written on main).
- **GamepadUIAction** — discrete nav events routed to `AppEnvironment.gamepad(_:)`
  (the single UI router; see the router in `AppEnvironment.swift`).

## Mapping table (DualSense → libretro id → UI action)

| Button | libretro id | UI action |
|---|---|---|
| Cross (A) | 8 | `.confirm` |
| Circle (B) | 0 | `.back` |
| Square (X) | 9 | — |
| Triangle (Y) | 1 | — |
| D-pad | 4-7 | `.up/.down/.left/.right` |
| L1 / R1 | 10 / 11 | `.previousPanel` / `.nextPanel` |
| L2 / R2 | 12 / 13 | `.toggleMute` (quick bar) / — |
| L3 / R3 | 14 / 15 | — |
| Options | 3 | — (Start) |
| Menu (buttonMenu) | 2 | — (Select) |
| PS (home) | — | `.openQuickBar` |
| Share (create) | — | `.toggleDiscord` |
| Touchpad click | — | `.captureScreenshot` |

## PS / Share / touchpad probing

`hookSystemButtons(controller:)` — GameController does NOT reliably expose PS/
Share as typed properties, so the code probes `physicalInputProfile.buttons`:
canonical `GCInputButtonHome` first, then "Menu"/"Button Menu" aliases, then
name-based fuzzy match (`ps` + menu/home/system). Share matches
`share`/`create`; touchpad matches any button whose key/aliases contain
"touchpad".

The home button's **system gesture must be disabled on every connect**:

```swift
home.preferredSystemGestureState = .disabled
```

Without this, macOS reserves the PS button (Launchpad). It is per-controller-
instance — re-apply on every `GCControllerDidConnect`.

## Stick navigation (hysteresis)

`driveStickNav(x:y:)` — crosses ±0.65 to fire, releases below ±0.3. Right stick
additionally drives the Discord overlay scroll (`onRightStickY`).
Stick axes are derived from directional buttons (`right.value - left.value`,
`down.value - up.value`) to sidestep GameController axis sign conventions;
snapshot Y is inverted (libretro analog Y is DirectInput: up negative).

## Keyboard fallback

Active only when no controller is connected (`keyboardDrivesInput`). Local
NSEvent monitors (`addLocalMonitorForEvents` — in-app only, never global):
Enter/Z→A, X→B, A→X, S→Y, Q/E→L1/R1, 1/3→L2/R2, arrows/WASD→dpad,
Backspace→Select, **F1→PS (quick bar)**, **F2→Share (Discord)**, Tab/Shift+Tab→
panel switch, Esc→back.

## Haptics

`Haptics.tick()` on every selection change — caches a `CHHapticEngine` per
controller; `Haptics.removeEngines(for:)` is called on disconnect (eviction).
Best-effort; never throws to the UI.

## Thread-safety rules

- All `valueChangedHandler`/`pressedChangedHandler` closures write the
  snapshot under its lock and fire UI actions on the main thread (GameController
  delivers on main — keep it that way; never call `uiReceiver?.gamepad(...)`
  from a background queue).
- `--diagnose-input` prints the live button inventory + raw HID element dump —
  the first tool to reach for when a button seems missing on a specific device.

## Adding a new button mapping

1. Add the action case in `GamepadUIAction` (if it's a UI action).
2. Wire it in `hook(_:controller:)` (or `hookSystemButtons` for exotic buttons).
3. Route it in `AppEnvironment.gamepad(_:)` (and the keyboard fallback if
   desired).
4. Verify with `--diagnose-input` and `--selftest` (input path asserted by the
   mock core).
