# Report: Global DualSense PS-button capture on macOS

> **Status (macOS 27 beta):** the capture is RE-ENABLED as an experiment — see
> the commit "re-enable global PS-button capture as a macOS 27 beta experiment".
> Test with `swift run Leblanc --watch-hid 15` (headless: prints every HID
> button press) or the GUI + Console (look for `GlobalHIDMonitor: matched HID
> device`, `system button 0x09/0x0d`, and `AppEnvironment: HID system button`).
> macOS may require Input Monitoring permission (System Settings → Privacy &
> Security → Input Monitoring → Leblanc; the app requests it once at launch).


## Goal

In a fullscreen macOS gaming launcher ("Leblanc", SwiftUI + AppKit, Apple Silicon,
macOS 14+), pressing the **PS button on a DualSense** should bring the launcher's
"quick bar" back to the foreground **at any time** — including while a standalone
game (PPSSPP, launched as a separate process via handoff; or Steam) is the
frontmost app.

In-app (launcher frontmost) this **works**. The failure is specifically when
another process is frontmost.

## Hardware / connection

- Sony DualSense Wireless Controller, vendor `0x054c`, product `0x0ce6`.
- Connected over **Bluetooth**.
- Host: 15-inch MacBook Air M2.

## What already works

1. **In-app PS button** (launcher frontmost): GameController framework. On
   `GCControllerDidConnect` we set
   `home.preferredSystemGestureState = .disabled` on the `GCInputButtonHome`
   element, then wire its `pressedChangedHandler` to open the quick bar. Works.

2. **Global keyboard hotkey**: Carbon `RegisterEventHotKey` (Cmd+Shift+Home)
   restores the launcher while *any* app is frontmost. This proves the process
   receives global events fine; only the controller path fails.

3. **The game controller itself** works for actual gameplay in PPSSPP (PPSSPP
   uses SDL2, which on macOS reads the controller via IOKit HID directly).

## The failing path (IOHIDManager)

We attempt system-wide capture via `IOHIDManager` (the RetroArch approach):

```swift
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(mgr, [
    [kIOHIDVendorIDKey: 0x054C],              // Sony
    [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
     kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
] as CFArray)

IOHIDManagerRegisterInputValueCallback(mgr, { ctx, result, sender, value in
    guard result == kIOReturnSuccess else { return }
    let element = IOHIDValueGetElement(value)
    let page   = IOHIDElementGetUsagePage(element)
    let usage  = IOHIDElementGetUsage(element)
    let pressed = IOHIDValueGetIntegerValue(value) != 0
    let isSystemButton = page == kHIDPage_Button && usage >= 0x0d && usage <= 0x0f
    if pressed && isSystemButton {
        // bring launcher back + show quick bar
    }
}, nil)

IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
```

The "bring launcher back" handler:

```swift
if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier {
    return // already frontmost; GameController handles it
}
NSApp.activate()
makeFrontendFullscreen()
quickBarVisible = true
```

## Result

While PPSSPP is frontmost, pressing the **PS button (and also touchpad click and
the mute button)** does nothing — the launcher's quick bar never appears.

## Real device data (from `IOHIDManagerCopyDevices` + element dump)

The DualSense exposes, among others, these HID elements:

```
Generic Desktop (0x01): 0x05, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x39
Button page (0x09):     0x01 … 0x0e   (14 buttons)
Vendor page (0xff00):   0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3b
```

Per the Linux `hid-playstation` driver and community docs, the DualSense button
usage mapping (usage page 0x09) is:

- 0x01–0x04 face buttons (Square/Cross/Circle/Triangle)
- 0x05–0x08 L1/R1/L2/R2
- 0x09 Create (Share), 0x0a Options
- 0x0b L3, 0x0c R3
- **0x0d PS button**
- 0x0e touchpad click
- 0x0f mute button

## Key hypothesis: Bluetooth report 49

`hid-playstation.c` states: *"DualSense in USB uses the full HID report for
reportID 1, but Bluetooth uses a minimal HID report for reportID 1 and reports
the full report using reportID 49."*

The PS / touchpad / mute buttons live in **reportID 49** (0x31) on Bluetooth.
The vendor-page elements `0xff00/0x31…0x3b` we see are consistent with report 49
data. So the question is whether macOS's `IOHIDManager` delivers report-49
input elements to a normal client's input-value callback, or whether the OS /
GameController daemon reserves/filters those "system" buttons.

## Questions for research

1. **Does `IOHIDManagerRegisterInputValueCallback` on macOS receive DualSense
   Bluetooth reportID 49 input elements (PS/touchpad/mute)?** Is there a known
   OS-level filter, or are those buttons only delivered to the GameController
   daemon and not to generic IOHIDManager clients?

2. **Does GameController deliver input to a backgrounded app when the frontmost
   app is NOT a GameController client** (e.g. an SDL2/IOKit app like PPSSPP)?
   i.e. could we skip IOHIDManager entirely and rely on GameController's home
   button while PPSSPP is frontmost? (Empirically it does not reach us, but
   confirm the expected behavior.)

3. **What is the sanctioned way to receive the DualSense PS/home button
   system-wide on macOS?** Candidates: IOHIDManager (tried), CGEventTap
   (keyboard/mouse only), the GameController daemon, or an HID "system" report
   that requires special open options.

4. **Does `preferredSystemGestureState = .disabled` remain in effect while the
   app is backgrounded**, or does the OS re-claim the PS button (Launchpad) the
   moment another app becomes frontmost?

5. Any **macOS-version-specific bugs** with DualSense report 49 delivery or
   `preferredSystemGestureState` (there was a documented macOS 14.2 regression
   where it silently failed to take effect)?

6. Is there a working open-source example of catching the DualSense PS button
   globally on macOS (RetroArch, Dolphin, moonlight-qt, etc.)? Which API do
   they use and does it work over Bluetooth?

## What we need from the answer

A concrete, testable mechanism (specific API calls) that fires when the DualSense
PS button is pressed while another app is frontmost, over Bluetooth — or a
definitive statement that it is not possible via public APIs, in which case the
fallback is the working Cmd+Shift+Home hotkey.
