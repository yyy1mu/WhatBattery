import AppKit
import SwiftUI

struct BatteryPopover: View {
    let monitor: BatteryMonitor

    var body: some View {
        VStack(spacing: 0) {
            BatteryPopoverHeader(
                accessoryCount: monitor.accessoryCount,
                isRefreshing: monitor.isRefreshing
            )

            BatteryAccessoryList(monitor: monitor)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            BatteryPopoverFooter(monitor: monitor)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BatteryPopoverHeader: View {
    let accessoryCount: Int
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "battery.100percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.green.gradient, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)

            Text("WhatBattery")
                .font(.headline)

            Text("\(accessoryCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: .capsule)
                .accessibilityLabel("\(accessoryCount) accessories")

            Spacer()

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reading battery levels…")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

private struct BatteryAccessoryList: View {
    let monitor: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if monitor.batteryDevices.isEmpty,
               monitor.bluetoothDevices.isEmpty {
                Label("No Battery Devices Found", systemImage: "battery.0percent")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ForEach(monitor.batteryDevices) { device in
                    HIDBatteryRow(device: device)
                }

                ForEach(monitor.bluetoothDevices) { device in
                    BluetoothBatteryRow(device: device)
                }
            }

            if monitor.needsInputMonitoringPermission {
                InputMonitoringNotice(monitor: monitor)
                    .padding(.top, 4)
            }

            if monitor.bluetooth.status != .ready {
                BluetoothStatusNotice(monitor: monitor.bluetooth)
                    .padding(.top, 4)
            }

            ForEach(monitor.ruleIssues) { issue in
                RuleIssueView(message: issue.message)
                    .padding(.top, 4)
            }
        }
    }
}

private struct AccessoryIconTile: View {
    let symbolName: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct HIDBatteryRow: View {
    let device: BatteryDeviceController

    private var tint: Color {
        BatteryLevelTint.color(for: device.reading?.level)
    }

    var body: some View {
        HStack(spacing: 10) {
            AccessoryIconTile(symbolName: device.rule.symbolName, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.rule.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if device.reading == nil {
                    Text(device.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(device.statusText)
                } else if showsLastKnownStatus {
                    Text("Last known battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            CircularBatteryGauge(
                level: device.reading?.level,
                isCharging: device.reading?.isCharging == true
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.07), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var showsLastKnownStatus: Bool {
        switch device.status {
        case .connected, .reading:
            false
        case .searching, .peripheralOffline, .sleeping, .permissionRequired,
             .unsupported, .error:
            true
        }
    }
}

private struct BluetoothBatteryRow: View {
    let device: BluetoothBatteryDevice

    private var tint: Color {
        BatteryLevelTint.color(for: device.level)
    }

    var body: some View {
        HStack(spacing: 10) {
            AccessoryIconTile(symbolName: device.symbolName, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                if device.connectionState == .lastKnown {
                    Text("Last known battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if device.components.count > 1 {
                BatteryComponentGauges(components: device.components)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                CircularBatteryGauge(
                    level: device.level,
                    isCharging: false
                )
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(.secondary.opacity(0.07), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct BluetoothStatusNotice: View {
    let monitor: BluetoothBatteryMonitor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)

            Text(monitor.statusText)
                .font(.caption)
                .lineLimit(2)

            Spacer(minLength: 8)

            if monitor.needsBluetoothPermission {
                Button("Open Settings", action: openBluetoothPrivacySettings)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(statusColor.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private var statusSymbol: String {
        switch monitor.status {
        case .permissionRequired, .error:
            "exclamationmark.triangle.fill"
        case .poweredOff, .unsupported:
            "antenna.radiowaves.left.and.right.slash"
        case .idle, .reading, .ready:
            "antenna.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        switch monitor.status {
        case .permissionRequired, .error:
            .orange
        case .idle, .reading, .ready, .poweredOff, .unsupported:
            .secondary
        }
    }

    private func openBluetoothPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct InputMonitoringNotice: View {
    let monitor: BatteryMonitor

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Lofree battery monitoring needs Input Monitoring access.",
                systemImage: "keyboard.badge.ellipsis"
            )
            .font(.caption)

            HStack {
                Button("Open Settings", action: openInputMonitoringSettings)
                Button("Check Again") {
                    monitor.refreshInputMonitoringPermission()
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) else { return }
        openURL(url)
    }

}

private struct RuleIssueView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

private struct BatteryPopoverFooter: View {
    let monitor: BatteryMonitor

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 16) {
            Button("Refresh All", systemImage: "arrow.clockwise", action: monitor.refreshAll)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh All")
                .keyboardShortcut("r", modifiers: .command)

            Button(action: openSettingsInFront) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            Spacer()

            if let lastCheckedAt = monitor.lastCheckedAt {
                Label {
                    Text(lastCheckedAt, format: .dateTime.hour().minute())
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Last checked")
            }

            Button("Quit WhatBattery", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit WhatBattery")
            .keyboardShortcut("q", modifiers: .command)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func openSettingsInFront() {
        openSettings()
        NSApplication.shared.activate()
    }
}

#Preview("Compact accessory list") {
    VStack(spacing: 0) {
        BatteryPopoverHeader(accessoryCount: 3, isRefreshing: false)

        VStack(alignment: .leading, spacing: 6) {
            BluetoothBatteryRow(
                device: BluetoothBatteryDevice(
                    id: "preview:mouse",
                    name: "Wireless Mouse",
                    kind: .mouse,
                    transport: .usb,
                    address: nil,
                    components: [
                        BatteryComponentReading(kind: .main, level: 50),
                    ],
                    isAppleAccessory: false,
                    connectionState: .connected,
                    checkedAt: Date(timeIntervalSince1970: 0)
                )
            )

            BluetoothBatteryRow(
                device: BluetoothBatteryDevice(
                    id: "preview:keyboard",
                    name: "Wireless Keyboard",
                    kind: .keyboard,
                    transport: .usb,
                    address: nil,
                    components: [
                        BatteryComponentReading(kind: .main, level: 18),
                    ],
                    isAppleAccessory: false,
                    connectionState: .connected,
                    checkedAt: Date(timeIntervalSince1970: 0)
                )
            )

            BluetoothBatteryRow(
                device: BluetoothBatteryDevice(
                    id: "preview:airpods",
                    name: "Wireless Earbuds",
                    kind: .earbuds,
                    transport: .bluetooth,
                    address: nil,
                    components: [
                        BatteryComponentReading(kind: .left, level: 100),
                        BatteryComponentReading(kind: .right, level: 96),
                        BatteryComponentReading(kind: .case, level: 67),
                    ],
                    isAppleAccessory: true,
                    connectionState: .connected,
                    checkedAt: Date(timeIntervalSince1970: 0)
                )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    .frame(width: 360)
}
