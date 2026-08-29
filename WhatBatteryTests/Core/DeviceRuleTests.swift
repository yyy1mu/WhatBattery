import Foundation
import Testing
@testable import WhatBattery

@MainActor
struct DeviceRuleTests {
    @Test("The packaged rule-file template decodes and validates")
    func ruleFileTemplateIsValid() throws {
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

        #expect(catalog.catalogMode == .complete)
        #expect(catalog.rules.count == 2)
        #expect(catalog.rules.allSatisfy {
            $0.protocolDefinition.validationProblem == nil
        })
        let logitechRule = try #require(
            catalog.rules.first { $0.id == "logitech.g304-g305" }
        )
        #expect(logitechRule.match.deviceIDs == [
            HIDDeviceID(
                vendorID: HIDNumber(0x046D),
                productID: HIDNumber(0xC53F)
            ),
        ])
        #expect(logitechRule.match.transport == "USB")
        let accessoryRules = try #require(catalog.systemAccessoryRules)
        #expect(accessoryRules.validationProblem == nil)
        #expect(accessoryRules.appleVendorIDs.map(\.value) == [0x004C, 0x05AC])
        #expect(accessoryRules.kind(
            name: "Desk Mouse",
            minorType: nil,
            usagePage: nil,
            usage: nil,
            components: [],
            isAppleAccessory: false
        ) == .mouse)
        #expect(accessoryRules.kind(
            name: "Unknown Accessory",
            minorType: nil,
            usagePage: nil,
            usage: nil,
            components: [],
            isAppleAccessory: false
        ) == .other)
    }

    @Test("First load creates the main rules file and extension directory")
    func firstLoadSeedsRulesFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let templateFileURL = projectRuleTemplateURL
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: templateFileURL
        )
        let result = store.load()

        #expect(result.issues.isEmpty)
        #expect(result.registrations.map(\.id) == [
            "logitech.g304-g305",
            "lofree.compx-keyboard",
        ])
        #expect(result.systemAccessoryRules != .empty)
        #expect(try Data(contentsOf: rulesFileURL) == Data(contentsOf: templateFileURL))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("device-rules.d").path
        ))
    }

    @Test("Input Monitoring checks default on and persist when disabled")
    func inputMonitoringPreferencePersists() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: directory.appendingPathComponent("device-rules.json"),
            templateFileURL: projectRuleTemplateURL
        )

        #expect(store.isInputMonitoringEnabled)

        store.setInputMonitoringEnabled(false)

        #expect(!store.isInputMonitoringEnabled)
    }

    @Test("Disabling Input Monitoring skips protected device rules")
    func disablingInputMonitoringSkipsProtectedRules() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: directory.appendingPathComponent("device-rules.json"),
            templateFileURL: projectRuleTemplateURL
        )
        let access = InputMonitoringAccessStub(status: .denied)
        let monitor = BatteryMonitor(
            ruleStore: store,
            inputMonitoringAccess: access
        )

        #expect(monitor.isInputMonitoringEnabled)
        #expect(monitor.inputMonitoringStatus == .denied)
        #expect(monitor.devices.map(\.id) == [
            "logitech.g304-g305",
            "lofree.compx-keyboard",
        ])

        monitor.setInputMonitoringEnabled(false)
        let statusChecksAfterDisabling = access.authorizationStatusCallCount
        monitor.refreshInputMonitoringPermission()

        #expect(!monitor.isInputMonitoringEnabled)
        #expect(monitor.inputMonitoringStatus == .notChecked)
        #expect(monitor.devices.map(\.id) == ["logitech.g304-g305"])
        #expect(access.authorizationStatusCallCount == statusChecksAfterDisabling)

        monitor.setInputMonitoringEnabled(true)

        #expect(monitor.isInputMonitoringEnabled)
        #expect(monitor.inputMonitoringStatus == .denied)
        #expect(access.requestAccessCallCount == 1)
        #expect(monitor.devices.map(\.id) == [
            "logitech.g304-g305",
            "lofree.compx-keyboard",
        ])
    }

    @Test("Additional rule files load in filename order")
    func loadsAdditionalRuleFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let fragmentsURL = directory.appendingPathComponent("device-rules.d")
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try writeCatalog(ruleIDs: ["main"], to: rulesFileURL)
        try FileManager.default.createDirectory(
            at: fragmentsURL,
            withIntermediateDirectories: true
        )
        try writeCatalog(
            ruleIDs: ["second"],
            to: fragmentsURL.appendingPathComponent("20-second.json")
        )
        try writeCatalog(
            ruleIDs: ["first"],
            to: fragmentsURL.appendingPathComponent("10-first.JSON")
        )
        try Data("ignored".utf8).write(
            to: fragmentsURL.appendingPathComponent("notes.txt")
        )

        let result = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: nil
        ).load()

        #expect(result.issues.isEmpty)
        #expect(result.registrations.map(\.id) == ["main", "first", "second"])
    }

    @Test("A broken extension file does not prevent other catalogs from loading")
    func isolatesBrokenAdditionalRuleFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let fragmentsURL = directory.appendingPathComponent("device-rules.d")
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try writeCatalog(ruleIDs: ["main"], to: rulesFileURL)
        try FileManager.default.createDirectory(
            at: fragmentsURL,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: fragmentsURL.appendingPathComponent("10-broken.json")
        )
        try writeCatalog(
            ruleIDs: ["working"],
            to: fragmentsURL.appendingPathComponent("20-working.json")
        )

        let result = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: nil
        ).load()

        #expect(result.registrations.map(\.id) == ["main", "working"])
        #expect(result.issues.count == 1)
        #expect(result.issues[0].message.contains("10-broken.json"))
    }

    @Test("The first rule wins when IDs are duplicated across files")
    func rejectsCrossFileDuplicateIDs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let fragmentsURL = directory.appendingPathComponent("device-rules.d")
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try writeCatalog(ruleIDs: ["same"], to: rulesFileURL)
        try FileManager.default.createDirectory(
            at: fragmentsURL,
            withIntermediateDirectories: true
        )
        try writeCatalog(
            ruleIDs: ["same", "additional"],
            to: fragmentsURL.appendingPathComponent("brand.json")
        )

        let result = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: nil
        ).load()

        #expect(result.registrations.map(\.id) == ["same", "additional"])
        #expect(result.issues.count == 1)
        #expect(result.issues[0].message.contains("Duplicate device-rule id: same"))
    }

    @Test("An old empty rules file is upgraded to the complete rule catalog")
    func legacyEmptyFileIsUpgraded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try Data(
            """
            {
              "rules": [],
              "schemaVersion": 1
            }
            """.utf8
        ).write(to: rulesFileURL)

        let store = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: projectRuleTemplateURL
        )
        let result = store.load()
        let migratedCatalog = try DeviceRuleStore.decodeCatalog(
            Data(contentsOf: rulesFileURL)
        )

        #expect(result.issues.isEmpty)
        #expect(result.registrations.map(\.id) == [
            "logitech.g304-g305",
            "lofree.compx-keyboard",
        ])
        #expect(result.systemAccessoryRules != .empty)
        #expect(migratedCatalog.catalogMode == .complete)
    }

    @Test("Old override rules are merged into the complete rule catalog once")
    func legacyOverridesArePreserved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try Data(
            """
            {
              "schemaVersion": 2,
              "rules": [{
                "id": "custom.device",
                "displayName": "Custom Device",
                "match": {
                  "vendorIDs": ["0x1234"],
                  "usagePage": "0xFF00"
                },
                "protocol": \(protocolJSON)
              }]
            }
            """.utf8
        ).write(to: rulesFileURL)

        let store = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: projectRuleTemplateURL
        )
        let result = store.load()

        #expect(result.issues.isEmpty)
        #expect(result.registrations.map(\.id) == [
            "logitech.g304-g305",
            "lofree.compx-keyboard",
            "custom.device",
        ])
        #expect(result.systemAccessoryRules != .empty)
    }

    @Test("A complete rules file is loaded without merging the packaged template")
    func existingRulesFileIsTheOnlySource() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rulesFileURL = directory.appendingPathComponent("device-rules.json")
        let (defaults, suiteName) = try makeUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try Data(
            """
            {
              "schemaVersion": 2,
              "catalogMode": "complete",
              "rules": [{
                "id": "file.only",
                "displayName": "File Only Device",
                "match": {
                  "vendorIDs": ["0x1234"],
                  "usagePage": "0xFF00"
                },
                "protocol": \(protocolJSON)
              }]
            }
            """.utf8
        ).write(to: rulesFileURL)

        let store = DeviceRuleStore(
            userDefaults: defaults,
            rulesFileURL: rulesFileURL,
            templateFileURL: projectRuleTemplateURL
        )
        let result = store.load()

        #expect(result.issues.isEmpty)
        #expect(result.registrations.map(\.id) == ["file.only"])
        #expect(result.systemAccessoryRules == .empty)
    }

    @Test("Rule catalogs decode the complete HID protocol from JSON")
    func decodesConfiguredProtocol() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "rules": [{
                "id": "example.mouse",
                "displayName": "Example Mouse",
                "symbolName": "computermouse",
                "match": {
                  "vendorIDs": ["0x046D"],
                  "productIDs": ["0xC53F"],
                  "usagePage": "0xFF00",
                  "usage": null,
                  "usageMatch": "primary",
                  "minimumInputReportLength": 20,
                  "minimumOutputReportLength": 20
                },
                "protocol": \(protocolJSON),
                "pollingIntervalSeconds": 300,
                "requiresInputMonitoring": false
              }]
            }
            """.utf8
        )

        let catalog = try DeviceRuleStore.decodeCatalog(data)
        let rule = try #require(catalog.rules.first)

        #expect(rule.match.vendorIDs.map(\.value) == [0x046D])
        #expect(rule.match.productIDs.map(\.value) == [0xC53F])
        #expect(rule.protocolDefinition.reportID.value == 0x11)
        #expect(rule.protocolDefinition.variables["slot"]?.value == 1)
        #expect(rule.protocolDefinition.steps[0].request[1] == .variable("slot"))
    }

    @Test("Duplicate rule identifiers are rejected")
    func rejectsDuplicateIDs() {
        let ruleJSON = """
        {
          "id": "duplicate",
          "displayName": "Duplicate",
          "match": {
            "vendorIDs": [1],
            "productIDs": [],
            "usagePage": 65280
          },
          "protocol": \(protocolJSON)
        }
        """
        let data = Data(
            "{\"schemaVersion\":2,\"rules\":[\(ruleJSON),\(ruleJSON)]}".utf8
        )

        #expect(throws: DeviceRuleStoreError.duplicateRuleID("duplicate")) {
            try DeviceRuleStore.decodeCatalog(data)
        }
    }

    @Test("Optional rule fields have safe defaults")
    func decodesRuleDefaults() throws {
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "rules": [{
                "id": "minimal",
                "displayName": "Minimal Device",
                "match": {
                  "vendorIDs": ["0x046D"],
                  "usagePage": "0xFF00"
                },
                "protocol": \(protocolJSON)
              }]
            }
            """.utf8
        )

        let rule = try #require(DeviceRuleStore.decodeCatalog(data).rules.first)
        #expect(rule.symbolName == "battery.100percent")
        #expect(rule.match.productIDs.isEmpty)
        #expect(rule.match.usageMatch == .primary)
        #expect(rule.pollingIntervalSeconds == 300)
        #expect(!rule.requiresInputMonitoring)
    }

    @Test("Primary and usage-pair matching stay distinct")
    func matchesTheConfiguredUsageMode() {
        let descriptor = HIDDeviceDescriptor(
            productName: "Receiver",
            vendorID: 0x05AC,
            productID: 0x024F,
            primaryUsagePage: 0x0001,
            primaryUsage: 0x0006,
            usagePairs: [HIDUsagePair(page: 0xFF02, usage: 0x0002)],
            maximumInputReportLength: 17,
            maximumOutputReportLength: 17,
            serialNumber: nil,
            locationID: nil
        )
        let pairRule = HIDMatchRule(
            vendorIDs: [HIDNumber(0x05AC)],
            productIDs: [HIDNumber(0x024F)],
            usagePage: HIDNumber(0xFF02),
            usage: HIDNumber(0x0002),
            usageMatch: .any,
            minimumInputReportLength: 17,
            minimumOutputReportLength: 17
        )
        let primaryRule = HIDMatchRule(
            vendorIDs: pairRule.vendorIDs,
            productIDs: pairRule.productIDs,
            usagePage: pairRule.usagePage,
            usage: pairRule.usage,
            usageMatch: .primary,
            minimumInputReportLength: 17,
            minimumOutputReportLength: 17
        )

        #expect(pairRule.matches(descriptor))
        #expect(!primaryRule.matches(descriptor))
    }

    @Test("Exact device IDs and transport reject lookalike devices")
    func matchesOnlyAnExactPhysicalInterface() {
        let rule = HIDMatchRule(
            deviceIDs: [
                HIDDeviceID(
                    vendorID: HIDNumber(0x05AC),
                    productID: HIDNumber(0x024F)
                ),
                HIDDeviceID(
                    vendorID: HIDNumber(0x3554),
                    productID: HIDNumber(0xFA0A)
                ),
            ],
            vendorIDs: [],
            productIDs: [],
            transport: "USB",
            usagePage: HIDNumber(0xFF02),
            usage: HIDNumber(0x0002),
            usageMatch: .any,
            minimumInputReportLength: 17,
            minimumOutputReportLength: 17
        )
        let validUSBDevice = HIDDeviceDescriptor(
            productName: "Receiver",
            vendorID: 0x05AC,
            productID: 0x024F,
            transport: "USB",
            primaryUsagePage: 0x0001,
            primaryUsage: 0x0006,
            usagePairs: [HIDUsagePair(page: 0xFF02, usage: 0x0002)],
            maximumInputReportLength: 17,
            maximumOutputReportLength: 17,
            serialNumber: nil,
            locationID: nil
        )
        let bluetoothDevice = HIDDeviceDescriptor(
            productName: "Flow100-L@Lofree",
            vendorID: 0x05AC,
            productID: 0x024F,
            transport: "Bluetooth Low Energy",
            primaryUsagePage: validUSBDevice.primaryUsagePage,
            primaryUsage: validUSBDevice.primaryUsage,
            usagePairs: validUSBDevice.usagePairs,
            maximumInputReportLength: 17,
            maximumOutputReportLength: 17,
            serialNumber: nil,
            locationID: nil
        )
        let mixedIdentifierDevice = HIDDeviceDescriptor(
            productName: "Unrelated Device",
            vendorID: 0x05AC,
            productID: 0xFA0A,
            transport: "USB",
            primaryUsagePage: validUSBDevice.primaryUsagePage,
            primaryUsage: validUSBDevice.primaryUsage,
            usagePairs: validUSBDevice.usagePairs,
            maximumInputReportLength: 17,
            maximumOutputReportLength: 17,
            serialNumber: nil,
            locationID: nil
        )

        #expect(rule.matches(validUSBDevice))
        #expect(!rule.matches(bluetoothDevice))
        #expect(!rule.matches(mixedIdentifierDevice))
    }

    private var protocolJSON: String {
        """
        {
          "reportID": "0x11",
          "reportLength": 5,
          "responseEchoes": [
            { "responseOffset": 1, "requestOffset": 1, "length": 2 }
          ],
          "variables": { "slot": "0x01" },
          "steps": [{
            "id": "battery",
            "request": ["0x11", "$slot", "0x00"]
          }],
          "battery": {
            "levelOffset": 4,
            "chargingOffset": null,
            "voltageHighOffset": null,
            "voltageLowOffset": null
          }
        }
        """
    }

    private var projectRuleTemplateURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("WhatBattery")
            .appendingPathComponent("DeviceRules.json")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatBattery-DeviceRuleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "WhatBattery.DeviceRuleTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func writeCatalog(ruleIDs: [String], to url: URL) throws {
        let rules = ruleIDs.map { id in
            """
            {
              "id": "\(id)",
              "displayName": "\(id)",
              "match": {
                "vendorIDs": ["0x1234"],
                "usagePage": "0xFF00"
              },
              "protocol": \(protocolJSON)
            }
            """
        }.joined(separator: ",")
        try Data(
            "{\"schemaVersion\":2,\"catalogMode\":\"complete\",\"rules\":[\(rules)]}".utf8
        ).write(to: url)
    }
}

@MainActor
private final class InputMonitoringAccessStub: InputMonitoringAccessProviding {
    private let status: InputMonitoringAuthorizationStatus
    private(set) var authorizationStatusCallCount = 0
    private(set) var requestAccessCallCount = 0

    init(status: InputMonitoringAuthorizationStatus) {
        self.status = status
    }

    func authorizationStatus() -> InputMonitoringAuthorizationStatus {
        authorizationStatusCallCount += 1
        return status
    }

    @discardableResult
    func requestAccess() -> Bool {
        requestAccessCallCount += 1
        return status == .granted
    }
}
