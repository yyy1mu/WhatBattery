import Foundation
import IOKit

/// Errors shared by all IOHID-backed battery drivers.
enum HIDDeviceError: LocalizedError, Equatable {
    case managerOpenFailed(IOReturn)
    case deviceOpenFailed(IOReturn)
    case reportSendFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .managerOpenFailed(let code):
            String(
                localized: "Unable to start the HID device manager: \(Self.hex(code))",
                comment: "Error shown when IOHIDManagerOpen fails."
            )
        case .deviceOpenFailed(let code):
            String(
                localized: "Unable to open the HID interface: \(Self.hex(code))",
                comment: "Error shown when IOHIDDeviceOpen fails."
            )
        case .reportSendFailed(let code):
            String(
                localized: "Unable to send the HID report: \(Self.hex(code))",
                comment: "Error shown when IOHIDDeviceSetReport fails."
            )
        }
    }

    private static func hex(_ code: IOReturn) -> String {
        "0x\(String(UInt32(bitPattern: code), radix: 16))"
    }
}
