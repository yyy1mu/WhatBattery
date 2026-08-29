import SwiftUI

struct WhatBatterySettingsView: View {
    let monitor: BatteryMonitor

    var body: some View {
        if #available(macOS 15.0, *) {
            TabView {
                Tab("General", systemImage: "gearshape") {
                    GeneralSettingsView(monitor: monitor)
                }

                Tab("History", systemImage: "chart.xyaxis.line") {
                    BatteryHistorySettingsView(history: monitor.history)
                }
            }
            .frame(width: 720, height: 540)
        } else {
            TabView {
                GeneralSettingsView(monitor: monitor)
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }

                BatteryHistorySettingsView(history: monitor.history)
                    .tabItem {
                        Label("History", systemImage: "chart.xyaxis.line")
                    }
            }
            .frame(width: 720, height: 540)
        }
    }
}
