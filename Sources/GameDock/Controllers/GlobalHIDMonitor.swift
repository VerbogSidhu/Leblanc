import Foundation
import IOKit.hid

/// System-wide controller capture via IOHIDManager.
///
/// RE-ENABLED as of the macOS 27 beta test: Apple DTS confirmed IOHIDManager
/// global input monitoring was broken/unreliable on macOS 14/15, but newer
/// macOS may have fixed it. Capture now attempts at launch with detailed
/// logging (device match + open result + button presses) so a test can tell
/// exactly where it breaks. macOS may require Input Monitoring permission
/// (System Settings → Privacy & Security → Input Monitoring → Leblanc). The
/// Cmd+Shift+Home hotkey remains the fallback restore path.
final class GlobalHIDMonitor {
    static let shared = GlobalHIDMonitor()

    /// Fires when the PS button is pressed, regardless of the frontmost app.
    var onPSButton: (() -> Void)?
    var isCapturing = false

    private var manager: IOHIDManager?

    // MARK: - Diagnostics

    func describeDevices() -> String {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Don't leak the diagnostic manager: unschedule + close on every exit.
        defer {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? []
        guard !set.isEmpty else { return "No HID gamepad devices found." }

        var lines: [String] = []
        for device in set {
            let vendor = Int(truncatingIfNeeded: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0)
            let product = Int(truncatingIfNeeded: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0)
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
            lines.append("  \(name) (vendor=0x\(String(format: "%04x", vendor)) product=0x\(String(format: "%04x", product)))")

            if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
                // Include the button page (0x09) — that's where the PS button lives.
                let pages = Set(elements.compactMap { el -> String? in
                    let page = IOHIDElementGetUsagePage(el)
                    guard page == kHIDPage_GenericDesktop || page == kHIDPage_Button || page == 0xFF00 else { return nil }
                    return String(format: "0x%02x/0x%02x", page, IOHIDElementGetUsage(el))
                })
                lines.append("    elements: \(pages.sorted().joined(separator: " "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Capture

    func startCapture(onPS: @escaping () -> Void) {
        guard !isCapturing else { return }
        onPSButton = onPS

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        let match: [[String: Any]] = [
            // Sony, constrained to the GenericDesktop/GamePad usage so we
            // don't open every HID device Sony makes (audio, etc.).
            [
                kIOHIDVendorIDKey: 0x054C,
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, match as CFArray)

        // Log devices as they match, so a test run shows whether the monitor
        // even sees the controller (and whether it arrives over USB/BT).
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { context, result, sender, device in
            guard result == kIOReturnSuccess else { return }
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
            let vendor = Int(truncatingIfNeeded: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0)
            let product = Int(truncatingIfNeeded: IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0)
            Log.info("GlobalHIDMonitor: matched HID device \(name) (0x\(String(format: "%04x", vendor))/0x\(String(format: "%04x", product)))")
        }, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, result, sender, device in
            Log.info("GlobalHIDMonitor: HID device removed")
        }, nil)

        IOHIDManagerRegisterInputValueCallback(mgr, { context, result, sender, value in
            guard result == kIOReturnSuccess else { return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            // System-ish buttons: PS (0x0d), touchpad (0x0e), mute (0x0f).
            // Over Bluetooth these live in reportID 49; some macOS versions
            // deliver them, some don't — treat any of them as "bring Leblanc
            // back" when another app is frontmost.
            let isSystemButton = page == kHIDPage_Button && usage >= 0x0d && usage <= 0x0f
            if pressed && isSystemButton {
                Log.info("GlobalHIDMonitor: system button 0x09/\(String(format: "0x%02x", usage))")
                DispatchQueue.main.async {
                    GlobalHIDMonitor.shared.onPSButton?()
                }
            } else if pressed {
                Log.debug("GlobalHIDMonitor: input \(String(format: "0x%02x/0x%02x", page, usage))")
            }
        }, nil)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult == kIOReturnSuccess {
            isCapturing = true
            Log.info("GlobalHIDMonitor: capture started (IOHIDManagerOpen=\(openResult))")
        } else {
            // Usually missing Input Monitoring permission. Tear down so the
            // Settings toggle can retry later instead of latching failure.
            Log.error("GlobalHIDMonitor: IOHIDManagerOpen failed (\(openResult)) — grant Input Monitoring in System Settings, then retry")
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            manager = nil
            onPSButton = nil
        }
    }

    func stopCapture() {
        guard let mgr = manager else { return }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        isCapturing = false
        onPSButton = nil
    }
}
