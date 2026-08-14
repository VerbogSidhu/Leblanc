import Foundation
import IOKit.hid

/// System-wide controller capture via IOHIDManager.
///
/// GameController only delivers input while our app is active, so the PS
/// button can't be caught while Steam/PPSSPP has focus through the normal API.
/// This monitor watches the DualSense at the HID level (the RetroArch
/// approach) and can fire `onPSButton` from any foreground app.
///
/// DualSense button mapping (usage page 0x09, per hid-playstation):
///   0x0D = PS button, 0x0E = touchpad click.
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
        isCapturing = true
        onPSButton = onPS

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        let match: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x054C], // Sony
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad
            ],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, match as CFArray)

        IOHIDManagerRegisterInputValueCallback(mgr, { context, result, sender, value in
            guard result == kIOReturnSuccess else { return }
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            // PS button = button page (0x09) usage 0x0D.
            if page == kHIDPage_Button && usage == 0x0D && pressed {
                DispatchQueue.main.async {
                    GlobalHIDMonitor.shared.onPSButton?()
                }
            } else if page == kHIDPage_Button && pressed {
                Log.debug("GlobalHIDMonitor: button \(String(format: "0x%02x/0x%02x", page, usage))")
            }
        }, nil)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.info("GlobalHIDMonitor: PS-button capture started")
    }

    func stopCapture() {
        guard let mgr = manager else { return }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        isCapturing = false
        onPSButton = nil
    }
}
