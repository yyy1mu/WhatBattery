import SwiftUI

@main
struct WhatBatteryApp: App {
    @State private var monitor = BatteryMonitor()

    var body: some Scene {
        MenuBarExtra {
            BatteryPopover(monitor: monitor)
        } label: {
            BatteryMenuBarLabel(device: monitor.lowestBatteryDevice)
                .task {
                    monitor.start()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            WhatBatterySettingsView(monitor: monitor)
        }
    }
}
