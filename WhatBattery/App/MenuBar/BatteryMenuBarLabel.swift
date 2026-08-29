import SwiftUI

struct BatteryMenuBarLabel: View {
    let device: BatteryMenuBarCandidate?

    var body: some View {
        Label {
            Text(device.map { "\($0.level)%" } ?? "--%")
                .monospacedDigit()
        } icon: {
            Image(systemName: batterySymbolName)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel(accessibilityLabel)
    }

    private var batterySymbolName: String {
        guard let device else { return "battery.0percent" }
        switch device.level {
        case ...25:
            return "battery.25"
        case 26...50:
            return "battery.50"
        case 51...75:
            return "battery.75"
        default:
            return "battery.100percent"
        }
    }

    private var accessibilityLabel: String {
        guard let device else {
            return String(
                localized: "No readable peripheral battery is available.",
                comment: "Menu bar accessibility label when no device has a battery reading."
            )
        }
        return String(
            localized: "Lowest battery is \(device.name) at \(device.level) percent.",
            comment: "Menu bar accessibility label naming the peripheral with the lowest battery."
        )
    }
}
