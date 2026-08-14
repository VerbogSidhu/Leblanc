import Foundation
import IOKit.hid

/// EXPERIMENTAL — system-wide controller capture via IOHIDManager.
///
/// GameController only delivers input while our app is active, so the PS
/// button can't be caught while Steam has focus through the normal API. This
/// monitor watches HID devices directly (the RetroArch approach) and can fire
/// `onPSButton` from any foreground app.
///
/// ⚠️ Status: diagnostic-first. The DualSense "PS" button lives on Sony's
/// vendor usage page (0xFF00); exact usages vary by firmware and are NOT
/// verified against hardware yet. Therefore:
///   • device/element enumeration is always available (used by
///     --diagnose-input),
///   • the capture path is opt-in (`startCapture`), off by default.
///
/// Enabling capture also requires the process to see HID devices, which it
/// does without extra permissions for a regular app (unlike keyboard taps).
final class GlobalHIDMonitor {
    static let shared = GlobalHIDMonitor()

    /// Fires when a vendor-page system button (likely PS) is pressed.
    var onPSButton: (() -> Void)?
    var isCapturing = false

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "com.gamedock.hid", qos: .userInitiated)

    // MARK: - Diagnostics (safe, always available)

    /// Human-readable summary of connected gamepads: vendor/product ids,
    /// usage pages and element names. Feeds --diagnose-input.
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
                let buttonPages = Set(elements.compactMap { el -> String? in
                    let usagePage = IOHIDElementGetUsagePage(el)
                    guard usagePage == kHIDPage_GenericDesktop || usagePage == 0xFF00 else { return nil }
                    return String(format: "0x%02x/0x%02x", usagePage, IOHIDElementGetUsage(el))
                })
                lines.append("    elements: \(buttonPages.sorted().joined(separator: " "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Capture (experimental, opt-in)

    func startCapture(onPS: @escaping () -> Void) {
        guard !isCapturing else { return }
        isCapturing = true
        onPSButton = onPS

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // Sony PlayStation controllers; also match generic gamepads.
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
            let usagePage = IOHIDElementGetUsagePage(element)
            // DualSense/DS4 put the system (PS) button on Sony's vendor page.
            guard usagePage == 0xFF00 else { return }
            let pressed = IOHIDValueGetIntegerValue(value) != 0
            if pressed {
                DispatchQueue.main.async {
                    GlobalHIDMonitor.shared.onPSButton?()
                }
            }
        }, nil)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        Log.warn("GlobalHIDMonitor: capture started (experimental — vendor-page button detection unverified on hardware)")
    }

    func stopCapture() {
        guard let mgr = manager else { return }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        isCapturing = false
        onPSButton = nil
    }
}
