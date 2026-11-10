// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// This device's battery, passed to the Mac while a session runs. The Mac sees it as a UPS on its USB bus
/// (devices/xhci.c, port 3), so macOS shows the charge in its menu bar and Battery settings.
final class BatteryReport {
    static let shared = BatteryReport()

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var logged = false

    func start() {
        guard observers.isEmpty else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.send() })
        }
        // Also now and then: the Mac may still be booting when the first change comes, and the engine
        // drops calls until it runs.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.send() }
        send()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func send() {
        let device = UIDevice.current
        guard device.batteryLevel >= 0 else { return } // unknown (the simulator)
        let percent = Int32((device.batteryLevel * 100).rounded())
        let charging = device.batteryState == .charging
        let ac = device.batteryState == .charging || device.batteryState == .full
        henge_vm_battery(percent, charging ? 1 : 0, ac ? 1 : 0)
        if !logged {
            logged = true
            HengeLog.log("battery", "to the Mac: \(percent)%, \(charging ? "charging" : ac ? "full, on power" : "on battery")")
        }
    }
}
