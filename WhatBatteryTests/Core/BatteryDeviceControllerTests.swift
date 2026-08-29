import IOKit.hid
import Testing
@testable import WhatBattery

@MainActor
struct BatteryDeviceControllerTests {
    @Test("A timeout keeps the last successful generic battery reading")
    func timeoutKeepsLastReading() async {
        let manager = HIDRuleDeviceManagerStub()
        let session = BatteryDeviceSessionStub(results: [
            .success(BatteryReading(level: 64)),
            .failure(BatterySessionError.unresponsive),
        ])
        let controller = BatteryDeviceController(
            rule: testRule,
            deviceManager: manager
        )

        controller.start()
        manager.connect(session)
        #expect(await waitUntil { controller.status == .connected })
        #expect(controller.reading?.level == 64)

        controller.refreshNow()
        #expect(await waitUntil { controller.status == .sleeping })
        #expect(controller.reading?.level == 64)
    }

    @Test("An offline peripheral keeps its previous battery metadata")
    func offlineKeepsLastReading() async {
        let manager = HIDRuleDeviceManagerStub()
        let initial = BatteryReading(
            level: 82,
            isCharging: true,
            voltageMillivolts: 4_150
        )
        let session = BatteryDeviceSessionStub(results: [
            .success(initial),
            .failure(BatterySessionError.peripheralOffline),
        ])
        let controller = BatteryDeviceController(
            rule: testRule,
            deviceManager: manager
        )

        controller.start()
        manager.connect(session)
        #expect(await waitUntil { controller.status == .connected })
        controller.refreshNow()
        #expect(await waitUntil { controller.status == .peripheralOffline })
        #expect(controller.reading == initial)
    }

    @Test("A USB battery is available only while its matching device is connected")
    func availabilityTracksPhysicalConnection() async {
        let manager = HIDRuleDeviceManagerStub()
        let session = BatteryDeviceSessionStub(results: [
            .success(BatteryReading(level: 71)),
        ])
        let controller = BatteryDeviceController(
            rule: testRule,
            deviceManager: manager
        )

        controller.start()
        #expect(!controller.isAvailable)

        manager.connect(session)
        #expect(await waitUntil { controller.status == .connected })
        #expect(controller.isAvailable)

        manager.disconnect()
        #expect(!controller.isAvailable)
        #expect(controller.reading?.level == 71)
    }

    @Test("A protected rule surfaces Input Monitoring permission state")
    func permissionFailureBecomesStatus() {
        let manager = HIDRuleDeviceManagerStub(
            startError: HIDRuleDeviceManagerError.inputMonitoringPermissionRequired
        )
        let controller = BatteryDeviceController(
            rule: testRule,
            deviceManager: manager
        )

        controller.start()

        #expect(controller.status == .permissionRequired)
        #expect(controller.needsInputMonitoringPermission)
    }

    private var testRule: BatteryDeviceRule {
        BatteryDeviceRule(
            id: "test.device",
            displayName: "Test Device",
            symbolName: "battery.100percent",
            match: HIDMatchRule(
                vendorIDs: [HIDNumber(1)],
                productIDs: [],
                usagePage: HIDNumber(0xFF00),
                usage: nil,
                usageMatch: .primary,
                minimumInputReportLength: 1,
                minimumOutputReportLength: 1
            ),
            protocolDefinition: HIDProtocolDefinition(
                reportID: HIDNumber(1),
                reportLength: 2,
                responseEchoes: [
                    HIDResponseEcho(
                        responseOffset: 0,
                        requestOffset: 0,
                        length: 1
                    ),
                ],
                steps: [
                    HIDCommandStep(
                        id: "battery",
                        request: [.literal(HIDNumber(1))]
                    ),
                ],
                battery: HIDBatteryExtractionRule(
                    levelOffset: 1,
                    chargingOffset: nil,
                    voltageHighOffset: nil,
                    voltageLowOffset: nil
                )
            ),
            pollingIntervalSeconds: 3_600,
            requiresInputMonitoring: false
        )
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

@MainActor
private final class HIDRuleDeviceManagerStub: HIDRuleDeviceManaging {
    var onConnectionChanged: (((any BatteryDeviceSession)?) -> Void)?
    var onError: ((Error) -> Void)?
    private let startError: Error?

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start() throws {
        if let startError { throw startError }
    }

    func stop() {}

    func connect(_ session: any BatteryDeviceSession) {
        onConnectionChanged?(session)
    }

    func disconnect() {
        onConnectionChanged?(nil)
    }
}

@MainActor
private final class BatteryDeviceSessionStub: BatteryDeviceSession {
    let deviceInfo = HIDDeviceDescriptor(
        productName: "Test Receiver",
        vendorID: 1,
        productID: 2,
        primaryUsagePage: 0xFF00,
        primaryUsage: 1,
        usagePairs: [],
        maximumInputReportLength: 20,
        maximumOutputReportLength: 20,
        serialNumber: nil,
        locationID: nil
    )

    private var results: [Result<BatteryReading, Error>]

    init(results: [Result<BatteryReading, Error>]) {
        self.results = results
    }

    func readBattery() async throws -> BatteryReading {
        guard !results.isEmpty else { throw StubError.missingResult }
        return try results.removeFirst().get()
    }

    func represents(_ device: IOHIDDevice) -> Bool { false }
    func close() {}

    private enum StubError: Error {
        case missingResult
    }
}
