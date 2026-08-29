import Foundation
import IOKit.hid

extension HIDDeviceDescriptor {
    init(device: IOHIDDevice, fallbackProductName: String) {
        productName = Self.stringProperty(kIOHIDProductKey, from: device)
            ?? fallbackProductName
        vendorID = Self.integerProperty(kIOHIDVendorIDKey, from: device) ?? 0
        productID = Self.integerProperty(kIOHIDProductIDKey, from: device) ?? 0
        transport = Self.stringProperty(kIOHIDTransportKey, from: device)
        primaryUsagePage = Self.integerProperty(
            kIOHIDPrimaryUsagePageKey,
            from: device
        ) ?? 0
        primaryUsage = Self.integerProperty(kIOHIDPrimaryUsageKey, from: device) ?? 0
        usagePairs = Self.usagePairs(from: device)
        maximumInputReportLength = Self.integerProperty(
            kIOHIDMaxInputReportSizeKey,
            from: device
        ) ?? 0
        maximumOutputReportLength = Self.integerProperty(
            kIOHIDMaxOutputReportSizeKey,
            from: device
        ) ?? 0
        serialNumber = Self.stringProperty(kIOHIDSerialNumberKey, from: device)
        locationID = Self.integerProperty(kIOHIDLocationIDKey, from: device)
    }

    private static func integerProperty(
        _ key: String,
        from device: IOHIDDevice
    ) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(
        _ key: String,
        from device: IOHIDDevice
    ) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func usagePairs(from device: IOHIDDevice) -> [HIDUsagePair] {
        guard let values = IOHIDDeviceGetProperty(
            device,
            kIOHIDDeviceUsagePairsKey as CFString
        ) as? [[String: Any]] else {
            return []
        }

        return values.compactMap { pair in
            guard let page = (
                pair[kIOHIDDeviceUsagePageKey as String] as? NSNumber
            )?.intValue,
            let usage = (
                pair[kIOHIDDeviceUsageKey as String] as? NSNumber
            )?.intValue else {
                return nil
            }
            return HIDUsagePair(page: page, usage: usage)
        }
    }
}
