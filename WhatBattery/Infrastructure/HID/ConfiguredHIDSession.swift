import IOKit.hid

@MainActor
final class ConfiguredHIDSession: BatteryDeviceSession {
    let deviceInfo: HIDDeviceDescriptor

    private let transport: HIDReportTransport
    private let executor: ConfiguredHIDProtocolExecutor

    init(device: IOHIDDevice, rule: BatteryDeviceRule) throws {
        let transport = try HIDReportTransport(
            device: device,
            definition: rule.protocolDefinition,
            fallbackProductName: rule.displayName
        )
        self.transport = transport
        deviceInfo = transport.deviceInfo
        executor = try ConfiguredHIDProtocolExecutor(
            definition: rule.protocolDefinition,
            transport: transport
        )
    }

    func readBattery() async throws -> BatteryReading {
        do {
            return try await executor.readBattery()
        } catch ConfiguredHIDError.timeout {
            throw BatterySessionError.unresponsive
        } catch ConfiguredHIDError.transportClosed {
            throw BatterySessionError.unresponsive
        } catch HIDDeviceError.reportSendFailed(let code)
            where code == kIOReturnNotPermitted {
            throw BatterySessionError.permissionRequired
        }
    }

    func represents(_ device: IOHIDDevice) -> Bool {
        transport.represents(device)
    }

    func close() {
        transport.close()
    }
}
