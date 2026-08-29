import Foundation

struct BatteryReading: Equatable, Sendable {
    let level: Int
    let isCharging: Bool?
    let voltageMillivolts: Int?

    init(
        level: Int,
        isCharging: Bool? = nil,
        voltageMillivolts: Int? = nil
    ) {
        self.level = level
        self.isCharging = isCharging
        self.voltageMillivolts = voltageMillivolts
    }
}

enum BatteryDeviceStatus: Equatable {
    case searching
    case reading
    case connected
    case peripheralOffline
    case sleeping
    case permissionRequired
    case unsupported
    case error(String)
}

enum BatterySessionError: LocalizedError, Equatable {
    case peripheralOffline
    case unresponsive
    case unsupported
    case permissionRequired

    var errorDescription: String? {
        switch self {
        case .peripheralOffline:
            String(
                localized: "The receiver is connected, but the peripheral is offline.",
                comment: "Generic status when a USB receiver cannot reach its wireless peripheral."
            )
        case .unresponsive:
            String(
                localized: "The device did not respond and may be sleeping.",
                comment: "Generic status when a battery request times out."
            )
        case .unsupported:
            String(
                localized: "The device does not expose a supported battery feature.",
                comment: "Generic status when a matched device lacks the expected battery feature."
            )
        case .permissionRequired:
            String(
                localized: "Input Monitoring permission is required for this device.",
                comment: "Generic error when macOS denies HID reports for a protected input device."
            )
        }
    }
}
