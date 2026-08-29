import Foundation
import Testing
@testable import WhatBattery

@MainActor
struct BluetoothBatteryTests {
    @Test("The menu bar selects exactly the lowest valid battery")
    func selectsLowestMenuBarBattery() throws {
        let selected = try #require(
            BatteryMenuBarSelection.lowest(in: [
                BatteryMenuBarCandidate(
                    id: "usb:mouse",
                    name: "Mouse",
                    symbolName: "computermouse",
                    level: 65
                ),
                BatteryMenuBarCandidate(
                    id: "bluetooth:keyboard",
                    name: "Keyboard",
                    symbolName: "keyboard",
                    level: 24
                ),
                BatteryMenuBarCandidate(
                    id: "invalid",
                    name: "Invalid",
                    symbolName: "battery.0percent",
                    level: 255
                ),
            ])
        )

        #expect(selected.id == "bluetooth:keyboard")
        #expect(selected.level == 24)
    }

    @Test("Equal battery levels have deterministic ordering")
    func menuBarTieBreakIsStable() {
        let selected = BatteryMenuBarSelection.lowest(in: [
            BatteryMenuBarCandidate(
                id: "z",
                name: "Mouse",
                symbolName: "computermouse",
                level: 40
            ),
            BatteryMenuBarCandidate(
                id: "a",
                name: "Keyboard",
                symbolName: "keyboard",
                level: 40
            ),
        ])

        #expect(selected?.id == "a")
    }

    @Test("A standard BLE battery fills a matching system accessory")
    func mergesBLEBatteryIntoSystemAccessory() throws {
        let system = BluetoothAccessoryRecord(
            id: "bluetooth:001122",
            name: "Example Keyboard",
            kind: .keyboard,
            transport: .bluetoothLowEnergy,
            address: "00:11:22",
            components: []
        )
        let ble = BluetoothAccessoryRecord(
            id: "ble:uuid",
            name: "Example Keyboard",
            kind: .other,
            transport: .bluetoothLowEnergy,
            address: nil,
            components: [BatteryComponentReading(kind: .main, level: 73)]
        )

        let merged = BluetoothAccessoryMerger.merge(
            system: [system],
            ble: [ble],
            checkedAt: .distantPast
        )
        let device = try #require(merged.first)

        #expect(merged.count == 1)
        #expect(device.id == system.id)
        #expect(device.kind == .keyboard)
        #expect(device.level == 73)
    }

    @Test("Richer system battery cells are not overwritten by BLE")
    func preservesSystemBatteryComponents() throws {
        let system = BluetoothAccessoryRecord(
            id: "bluetooth:airpods",
            name: "Headphones",
            kind: .headphones,
            transport: .bluetooth,
            address: "00:11:22",
            components: [
                BatteryComponentReading(kind: .left, level: 80),
                BatteryComponentReading(kind: .right, level: 75),
                BatteryComponentReading(kind: .case, level: 50),
            ]
        )
        let ble = BluetoothAccessoryRecord(
            id: "ble:airpods",
            name: "Headphones",
            kind: .headphones,
            transport: .bluetoothLowEnergy,
            address: nil,
            components: [BatteryComponentReading(kind: .main, level: 99)]
        )

        let merged = BluetoothAccessoryMerger.merge(
            system: [system],
            ble: [ble],
            checkedAt: .distantPast
        )
        let device = try #require(merged.first)

        #expect(device.components == system.components)
        #expect(device.level == 50)
    }

    @Test("system_profiler connected accessory cells are parsed")
    func parsesSystemProfilerBluetoothCells() throws {
        let fixture: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "device_connected": [
                        [
                            "Test Buds": [
                                "device_address": "AA:BB:CC:DD:EE:FF",
                                "device_minorType": "Headphones",
                                "device_batteryLevelLeft": "91%",
                                "device_batteryLevelRight": "87%",
                                "device_batteryLevelCase": "42%",
                            ],
                        ],
                    ],
                    "device_not_connected": [
                        [
                            "Old Mouse": [
                                "device_address": "11:22:33:44:55:66",
                                "device_minorType": "Mouse",
                                "device_batteryLevelMain": "5%",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let records = SystemBluetoothBatteryReader.parseSystemProfiler(
            fixture,
            rules: try accessoryRules
        )
        let record = try #require(records.first)

        #expect(records.count == 1)
        #expect(record.id == "bluetooth:aabbccddeeff")
        #expect(record.components.map(\.level) == [91, 87, 42])
        #expect(record.connectionState == .connected)
    }

    @Test("system_profiler keeps cached Apple accessory battery cells")
    func parsesLastKnownAppleBatteryCells() throws {
        let fixture: [String: Any] = [
            "SPBluetoothDataType": [
                [
                    "device_not_connected": [
                        [
                            "My AirPods": [
                                "device_address": "AA:BB:CC:DD:EE:FF",
                                "device_vendorID": "0x004C (Apple)",
                                "device_minorType": "Headphones",
                                "device_batteryLevelLeft": "100%",
                                "device_batteryLevelRight": "96%",
                                "device_batteryLevelCase": "67%",
                            ],
                        ],
                        [
                            "Third-party Mouse": [
                                "device_address": "11:22:33:44:55:66",
                                "device_minorType": "Mouse",
                                "device_batteryLevelMain": "5%",
                            ],
                        ],
                    ],
                ],
            ],
        ]

        let records = SystemBluetoothBatteryReader.parseSystemProfiler(
            fixture,
            rules: try accessoryRules
        )
        let record = try #require(records.first)

        #expect(records.count == 1)
        #expect(record.name == "My AirPods")
        #expect(record.kind == .earbuds)
        #expect(record.components.map(\.level) == [100, 96, 67])
        #expect(record.isAppleAccessory)
        #expect(record.connectionState == .lastKnown)
    }

    @Test("A live BLE reading marks matching cached Apple data connected")
    func liveBLEUpgradesCachedAppleConnection() throws {
        let cachedApple = BluetoothAccessoryRecord(
            id: "bluetooth:airpods",
            name: "My AirPods",
            kind: .earbuds,
            transport: .bluetooth,
            address: "AA:BB:CC:DD:EE:FF",
            components: [
                BatteryComponentReading(kind: .left, level: 80),
                BatteryComponentReading(kind: .right, level: 75),
                BatteryComponentReading(kind: .case, level: 50),
            ],
            isAppleAccessory: true,
            connectionState: .lastKnown
        )
        let liveBLE = BluetoothAccessoryRecord(
            id: "ble:airpods",
            name: "My AirPods",
            kind: .earbuds,
            transport: .bluetoothLowEnergy,
            address: nil,
            components: [BatteryComponentReading(kind: .main, level: 79)]
        )

        let merged = BluetoothAccessoryMerger.merge(
            system: [cachedApple],
            ble: [liveBLE],
            checkedAt: .distantPast
        )
        let device = try #require(merged.first)

        #expect(merged.count == 1)
        #expect(device.connectionState == .connected)
        #expect(device.isAppleAccessory)
        #expect(device.components == cachedApple.components)
    }

    @Test("Apple system battery snapshots remain visible without a connection flag")
    func appleSystemBatterySnapshotsRemainAvailable() async {
        let cachedDevice = BluetoothAccessoryRecord(
            id: "bluetooth:cached-keyboard",
            name: "Disconnected Keyboard",
            kind: .keyboard,
            transport: .bluetooth,
            address: "00:11:22:33:44:55",
            components: [BatteryComponentReading(kind: .main, level: 42)],
            isAppleAccessory: true,
            connectionState: .lastKnown
        )
        let monitor = BluetoothBatteryMonitor(
            systemReader: SystemBluetoothReaderStub(records: [cachedDevice]),
            bleReader: BLEBatteryReaderStub(result: .success([]))
        )

        await monitor.refresh()

        #expect(monitor.devices.count == 1)
        #expect(monitor.availableDevices.map(\.name) == ["Disconnected Keyboard"])
    }

    @Test("Cached third-party batteries are not exposed as available")
    func cachedThirdPartyDevicesAreNotAvailable() async {
        let cachedDevice = BluetoothAccessoryRecord(
            id: "bluetooth:cached-mouse",
            name: "Disconnected Mouse",
            kind: .mouse,
            transport: .bluetooth,
            address: "00:11:22:33:44:66",
            components: [BatteryComponentReading(kind: .main, level: 12)],
            connectionState: .lastKnown
        )
        let monitor = BluetoothBatteryMonitor(
            systemReader: SystemBluetoothReaderStub(records: [cachedDevice]),
            bleReader: BLEBatteryReaderStub(result: .success([]))
        )

        await monitor.refresh()

        #expect(monitor.devices.count == 1)
        #expect(monitor.availableDevices.isEmpty)
    }

    @Test("The Bluetooth monitor keeps system batteries when BLE permission is denied")
    func permissionFailureStillKeepsSystemDevices() async throws {
        let systemRecord = BluetoothAccessoryRecord(
            id: "bluetooth:keyboard",
            name: "Keyboard",
            kind: .keyboard,
            transport: .bluetooth,
            address: "00:11:22",
            components: [BatteryComponentReading(kind: .main, level: 60)]
        )
        let monitor = BluetoothBatteryMonitor(
            systemReader: SystemBluetoothReaderStub(records: [systemRecord]),
            bleReader: BLEBatteryReaderStub(
                result: .failure(BLEBatteryServiceError.permissionRequired)
            )
        )

        await monitor.refresh()

        #expect(monitor.status == .permissionRequired)
        #expect(monitor.devices.map(\.level) == [60])
    }

    @Test("Reloading the rule file updates both Bluetooth rule readers")
    func reloadUpdatesBluetoothRules() throws {
        let systemReader = SystemBluetoothReaderStub(records: [])
        let bleReader = BLEBatteryReaderStub(result: .success([]))
        let monitor = BluetoothBatteryMonitor(
            systemReader: systemReader,
            bleReader: bleReader
        )
        let rules = try accessoryRules

        monitor.updateAccessoryRules(rules)

        #expect(systemReader.updatedRules == rules)
        #expect(bleReader.updatedRules == rules)
    }

    private var accessoryRules: SystemAccessoryRuleSet {
        get throws {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let data = try Data(
                contentsOf: projectRoot
                    .appendingPathComponent("WhatBattery")
                    .appendingPathComponent("DeviceRules.json")
            )
            let catalog = try DeviceRuleStore.decodeCatalog(data)
            return try #require(catalog.systemAccessoryRules)
        }
    }
}

@MainActor
private final class SystemBluetoothReaderStub: SystemBluetoothBatteryReading {
    let records: [BluetoothAccessoryRecord]
    private(set) var updatedRules: SystemAccessoryRuleSet?

    init(records: [BluetoothAccessoryRecord]) {
        self.records = records
    }

    func readAccessories() async -> [BluetoothAccessoryRecord] {
        records
    }

    func updateRules(_ rules: SystemAccessoryRuleSet) {
        updatedRules = rules
    }
}

@MainActor
private final class BLEBatteryReaderStub: BLEBatteryServiceReading {
    let result: Result<[BluetoothAccessoryRecord], Error>
    private(set) var updatedRules: SystemAccessoryRuleSet?

    init(result: Result<[BluetoothAccessoryRecord], Error>) {
        self.result = result
    }

    func readConnectedAccessories() async throws -> [BluetoothAccessoryRecord] {
        try result.get()
    }

    func updateRules(_ rules: SystemAccessoryRuleSet) {
        updatedRules = rules
    }
}
