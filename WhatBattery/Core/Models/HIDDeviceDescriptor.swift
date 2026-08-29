import Foundation

struct HIDUsagePair: Equatable, Sendable {
    let page: Int
    let usage: Int
}

struct HIDDeviceDescriptor: Equatable, Sendable {
    let productName: String
    let vendorID: Int
    let productID: Int
    let transport: String?
    let primaryUsagePage: Int
    let primaryUsage: Int
    let usagePairs: [HIDUsagePair]
    let maximumInputReportLength: Int
    let maximumOutputReportLength: Int
    let serialNumber: String?
    let locationID: Int?

    init(
        productName: String,
        vendorID: Int,
        productID: Int,
        transport: String? = nil,
        primaryUsagePage: Int,
        primaryUsage: Int,
        usagePairs: [HIDUsagePair],
        maximumInputReportLength: Int,
        maximumOutputReportLength: Int,
        serialNumber: String?,
        locationID: Int?
    ) {
        self.productName = productName
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
        self.usagePairs = usagePairs
        self.maximumInputReportLength = maximumInputReportLength
        self.maximumOutputReportLength = maximumOutputReportLength
        self.serialNumber = serialNumber
        self.locationID = locationID
    }

    var description: String {
        "\(productName) (VID \(Self.hex(vendorID)), PID \(Self.hex(productID)))"
    }

    private static func hex(_ value: Int) -> String {
        String(format: "0x%04X", value)
    }
}
