import Combine
import Foundation
import GameController
import IOKit.ps
import Network

/// Status HUD data: MacBook battery, DualSense battery, and network
/// connectivity. Clock is rendered in the view via TimelineView.
final class StatusMonitor: ObservableObject {
    @Published private(set) var macBattery = "—"
    @Published private(set) var macCharging = false
    @Published private(set) var controllerBattery = "—"
    @Published private(set) var network = "—"
    /// True when there is no network connection at all.
    @Published private(set) var isOffline = false

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.leblanc.network")

    func start() {
        updateMacBattery()
        updateControllerBattery()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let text: String
            if path.status == .satisfied {
                if path.usesInterfaceType(.wifi) { text = "Wi-Fi" }
                else if path.usesInterfaceType(.wiredEthernet) { text = "Ethernet" }
                else { text = "Online" }
            } else {
                text = "Offline"
            }
            DispatchQueue.main.async {
                self?.network = text
                self?.isOffline = (text == "Offline")
            }
        }
        pathMonitor.start(queue: pathQueue)

        timer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.updateMacBattery()
            self?.updateControllerBattery()
        }
    }

    // MARK: - MacBook battery (IOKit power sources)

    func updateMacBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any] else { return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let type = desc[kIOPSTypeKey as String] as? String, type != kIOPSInternalBatteryType { continue }
            if let cap = desc[kIOPSCurrentCapacityKey as String] as? Int {
                let text = "\(cap)%"
                // Publish only on change — the timer repolls every 25 s and
                // unchanged writes would churn SwiftUI.
                if text != macBattery { macBattery = text }
            }
            if let state = desc[kIOPSPowerSourceStateKey as String] as? String {
                let charging = (state == kIOPSACPowerValue)
                if charging != macCharging { macCharging = charging }
            }
        }
    }

    // MARK: - DualSense battery (GCDeviceBattery)

    func updateControllerBattery() {
        guard let controller = GCController.controllers().first,
              let battery = controller.battery else {
            if controllerBattery != "—" { controllerBattery = "—" }
            return
        }
        let level = battery.batteryLevel
        // -1 (and 0 in some wired/macOS combinations) means unknown — never
        // show a misleading number.
        let text: String
        if level < 0 || battery.batteryState == .unknown {
            text = "—"
        } else {
            text = "\(Int(level * 100))%"
        }
        if text != controllerBattery { controllerBattery = text }
    }
}
