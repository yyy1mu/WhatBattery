import Foundation

enum HIDUsageMatchMode: String, Codable, Sendable {
    case primary
    case any
}

struct HIDDeviceID: Codable, Equatable, Sendable {
    let vendorID: HIDNumber
    let productID: HIDNumber
}

struct HIDMatchRule: Codable, Equatable, Sendable {
    let deviceIDs: [HIDDeviceID]
    let vendorIDs: [HIDNumber]
    let productIDs: [HIDNumber]
    let transport: String?
    let usagePage: HIDNumber
    let usage: HIDNumber?
    let usageMatch: HIDUsageMatchMode
    let minimumInputReportLength: Int
    let minimumOutputReportLength: Int

    init(
        deviceIDs: [HIDDeviceID] = [],
        vendorIDs: [HIDNumber],
        productIDs: [HIDNumber],
        transport: String? = nil,
        usagePage: HIDNumber,
        usage: HIDNumber?,
        usageMatch: HIDUsageMatchMode,
        minimumInputReportLength: Int,
        minimumOutputReportLength: Int
    ) {
        self.deviceIDs = deviceIDs
        self.vendorIDs = vendorIDs
        self.productIDs = productIDs
        self.transport = transport
        self.usagePage = usagePage
        self.usage = usage
        self.usageMatch = usageMatch
        self.minimumInputReportLength = minimumInputReportLength
        self.minimumOutputReportLength = minimumOutputReportLength
    }

    func matches(_ device: HIDDeviceDescriptor) -> Bool {
        if deviceIDs.isEmpty {
            guard vendorIDs.contains(where: { $0.value == device.vendorID }) else {
                return false
            }
            guard productIDs.isEmpty
                    || productIDs.contains(where: { $0.value == device.productID }) else {
                return false
            }
        } else {
            guard deviceIDs.contains(where: {
                $0.vendorID.value == device.vendorID
                    && $0.productID.value == device.productID
            }) else {
                return false
            }
        }
        if let transport {
            guard let deviceTransport = device.transport,
                  deviceTransport.caseInsensitiveCompare(transport) == .orderedSame else {
                return false
            }
        }
        guard device.maximumInputReportLength == 0
                || device.maximumInputReportLength >= minimumInputReportLength,
              device.maximumOutputReportLength == 0
                || device.maximumOutputReportLength >= minimumOutputReportLength else {
            return false
        }

        switch usageMatch {
        case .primary:
            guard device.primaryUsagePage == usagePage.value else { return false }
            return usage == nil || device.primaryUsage == usage?.value
        case .any:
            return device.usagePairs.contains { pair in
                pair.page == usagePage.value
                    && (usage == nil || pair.usage == usage?.value)
            }
        }
    }
}

extension HIDMatchRule {
    private enum CodingKeys: String, CodingKey {
        case deviceIDs
        case vendorIDs
        case productIDs
        case transport
        case usagePage
        case usage
        case usageMatch
        case minimumInputReportLength
        case minimumOutputReportLength
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIDs = try container.decodeIfPresent(
            [HIDDeviceID].self,
            forKey: .deviceIDs
        ) ?? []
        vendorIDs = try container.decodeIfPresent(
            [HIDNumber].self,
            forKey: .vendorIDs
        ) ?? []
        productIDs = try container.decodeIfPresent(
            [HIDNumber].self,
            forKey: .productIDs
        ) ?? []
        transport = try container.decodeIfPresent(String.self, forKey: .transport)
        usagePage = try container.decode(HIDNumber.self, forKey: .usagePage)
        usage = try container.decodeIfPresent(HIDNumber.self, forKey: .usage)
        usageMatch = try container.decodeIfPresent(
            HIDUsageMatchMode.self,
            forKey: .usageMatch
        ) ?? .primary
        minimumInputReportLength = try container.decodeIfPresent(
            Int.self,
            forKey: .minimumInputReportLength
        ) ?? 0
        minimumOutputReportLength = try container.decodeIfPresent(
            Int.self,
            forKey: .minimumOutputReportLength
        ) ?? 0
    }
}
