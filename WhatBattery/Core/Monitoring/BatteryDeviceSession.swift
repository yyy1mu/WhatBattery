import IOKit.hid

@MainActor
protocol BatteryDeviceSession: AnyObject {
    var deviceInfo: HIDDeviceDescriptor { get }

    func readBattery() async throws -> BatteryReading
    func represents(_ device: IOHIDDevice) -> Bool
    func close()
}
