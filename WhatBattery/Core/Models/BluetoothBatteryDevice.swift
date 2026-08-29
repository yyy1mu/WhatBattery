import Foundation

enum BluetoothBatteryTransport: String, Equatable, Sendable {
    case usb
    case bluetooth
    case bluetoothLowEnergy

    var displayName: LocalizedStringResource {
        switch self {
        case .usb:
            "USB"
        case .bluetooth:
            "Bluetooth"
        case .bluetoothLowEnergy:
            "Bluetooth Low Energy"
        }
    }

    var symbolName: String {
        switch self {
        case .usb:
            "cable.connector"
        case .bluetooth, .bluetoothLowEnergy:
            "antenna.radiowaves.left.and.right"
        }
    }
}

enum BluetoothBatteryDeviceKind: String, Codable, Equatable, Sendable {
    case keyboard
    case mouse
    case trackpad
    case earbuds
    case headphones
    case other

    var symbolName: String {
        switch self {
        case .keyboard:
            "keyboard"
        case .mouse:
            "computermouse"
        case .trackpad:
            "rectangle.and.hand.point.up.left"
        case .earbuds:
            "airpods"
        case .headphones:
            "headphones"
        case .other:
            "antenna.radiowaves.left.and.right"
        }
    }
}

enum BluetoothBatteryConnectionState: String, Equatable, Sendable {
    case connected
    case lastKnown

    var displayName: LocalizedStringResource {
        switch self {
        case .connected:
            "Connected"
        case .lastKnown:
            "Last known battery"
        }
    }

    var symbolName: String {
        switch self {
        case .connected:
            "link"
        case .lastKnown:
            "clock.arrow.circlepath"
        }
    }
}

enum BatteryComponentKind: String, Codable, Equatable, Hashable, Sendable {
    case main
    case left
    case right
    case `case`

    var displayName: LocalizedStringResource {
        switch self {
        case .main:
            "Battery"
        case .left:
            "Left"
        case .right:
            "Right"
        case .case:
            "Case"
        }
    }
}

struct BatteryComponentReading: Equatable, Identifiable, Sendable {
    let kind: BatteryComponentKind
    let level: Int

    var id: BatteryComponentKind { kind }
}

struct BluetoothBatteryDevice: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: BluetoothBatteryDeviceKind
    let transport: BluetoothBatteryTransport
    let address: String?
    let components: [BatteryComponentReading]
    let isAppleAccessory: Bool
    let connectionState: BluetoothBatteryConnectionState
    let checkedAt: Date

    var level: Int {
        components.map(\.level).min() ?? 0
    }

    var batteryText: String {
        "\(level)%"
    }

    var symbolName: String {
        kind.symbolName
    }

    /// macOS frequently publishes Apple accessory battery cells in the system
    /// snapshot without a reliable connected flag. Keep those system-reported
    /// readings visible, while still rejecting cached third-party devices.
    var isAvailable: Bool {
        connectionState == .connected
            || (isAppleAccessory && !components.isEmpty)
    }
}

enum BluetoothBatteryStatus: Equatable {
    case idle
    case reading
    case ready
    case poweredOff
    case permissionRequired
    case unsupported
    case error(String)
}
