import Foundation
import IOKit

@MainActor
protocol SystemBluetoothBatteryReading {
    func readAccessories() async -> [BluetoothAccessoryRecord]
    func updateRules(_ rules: SystemAccessoryRuleSet)
}

@MainActor
final class SystemBluetoothBatteryReader: SystemBluetoothBatteryReading {
    private var rules: SystemAccessoryRuleSet

    init(rules: SystemAccessoryRuleSet) {
        self.rules = rules
    }

    func updateRules(_ rules: SystemAccessoryRuleSet) {
        self.rules = rules
    }

    func readAccessories() async -> [BluetoothAccessoryRecord] {
        let rules = rules
        return await Task.detached(priority: .utility) {
            Self.readSynchronously(rules: rules)
        }.value
    }

    private nonisolated static func readSynchronously(
        rules: SystemAccessoryRuleSet
    ) -> [BluetoothAccessoryRecord] {
        merge(
            ioRegistry: readIORegistry(rules: rules),
            systemProfiler: readSystemProfiler(rules: rules)
        )
    }

    private nonisolated static func merge(
        ioRegistry: [BluetoothAccessoryRecord],
        systemProfiler: [BluetoothAccessoryRecord]
    ) -> [BluetoothAccessoryRecord] {
        var recordsByID = Dictionary(
            uniqueKeysWithValues: systemProfiler.map { ($0.id, $0) }
        )

        for record in ioRegistry {
            if let existing = recordsByID[record.id] {
                recordsByID[record.id] = BluetoothAccessoryRecord(
                    id: existing.id,
                    name: existing.name,
                    kind: existing.kind == .other ? record.kind : existing.kind,
                    transport: existing.transport,
                    address: existing.address ?? record.address,
                    components: existing.hasBattery
                        ? existing.components
                        : record.components,
                    isAppleAccessory: existing.isAppleAccessory
                        || record.isAppleAccessory,
                    connectionState: .connected
                )
            } else {
                recordsByID[record.id] = record
            }
        }

        return Array(recordsByID.values)
    }

    private nonisolated static func readSystemProfiler(
        rules: SystemAccessoryRuleSet
    ) -> [BluetoothAccessoryRecord] {
        guard let root = runSystemProfiler() else {
            return []
        }
        return parseSystemProfiler(root, rules: rules)
    }

    nonisolated static func parseSystemProfiler(
        _ root: [String: Any],
        rules: SystemAccessoryRuleSet
    ) -> [BluetoothAccessoryRecord] {
        guard let blocks = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return []
        }

        var recordsByID: [String: BluetoothAccessoryRecord] = [:]

        for block in blocks {
            for (key, value) in block {
                guard let connectionState = profilerConnectionState(for: key),
                      let devices = value as? [[String: Any]] else {
                    continue
                }

                for wrapper in devices {
                    for (name, rawInfo) in wrapper {
                        guard let info = rawInfo as? [String: Any],
                              let rawAddress = info["device_address"] as? String else {
                            continue
                        }

                        let components = profilerComponents(info)
                        let isAppleAccessory = profilerIdentifiesApple(
                            info,
                            rules: rules
                        )
                        guard connectionState == .connected
                                || (isAppleAccessory && !components.isEmpty) else {
                            continue
                        }

                        let kind = rules.kind(
                            name: name,
                            minorType: info["device_minorType"] as? String,
                            usagePage: nil,
                            usage: nil,
                            components: components,
                            isAppleAccessory: isAppleAccessory
                        )
                        guard !components.isEmpty || kind != .other else { continue }

                        let services = (info["device_services"] as? String) ?? ""
                        let transport: BluetoothBatteryTransport = services
                            .localizedCaseInsensitiveContains("BLE")
                            ? .bluetoothLowEnergy
                            : .bluetooth

                        let id = "bluetooth:\(normalizeAddress(rawAddress))"
                        let record = BluetoothAccessoryRecord(
                            id: id,
                            name: name,
                            kind: kind,
                            transport: transport,
                            address: rawAddress,
                            components: components,
                            isAppleAccessory: isAppleAccessory,
                            connectionState: connectionState
                        )

                        if recordsByID[id]?.connectionState != .connected
                            || connectionState == .connected {
                            recordsByID[id] = record
                        }
                    }
                }
            }
        }

        return recordsByID.values.sorted { $0.id < $1.id }
    }

    private nonisolated static func profilerConnectionState(
        for key: String
    ) -> BluetoothBatteryConnectionState? {
        switch key.lowercased() {
        case "device_connected":
            .connected
        case "device_not_connected":
            .lastKnown
        default:
            nil
        }
    }

    private nonisolated static func profilerIdentifiesApple(
        _ info: [String: Any],
        rules: SystemAccessoryRuleSet
    ) -> Bool {
        let rawVendor = info["device_vendorID"]
        return rules.identifiesApple(
            vendorID: hardwareIdentifier(rawVendor),
            manufacturer: String(describing: rawVendor ?? ""),
            productName: nil
        )
    }

    private nonisolated static func profilerComponents(
        _ info: [String: Any]
    ) -> [BatteryComponentReading] {
        let fields: [(BatteryComponentKind, String)] = [
            (.main, "device_batteryLevelMain"),
            (.left, "device_batteryLevelLeft"),
            (.right, "device_batteryLevelRight"),
            (.case, "device_batteryLevelCase"),
        ]

        return fields.compactMap { kind, key in
            guard let rawValue = info[key] as? String,
                  let level = parsePercent(rawValue) else {
                return nil
            }
            return BatteryComponentReading(kind: kind, level: level)
        }
    }

    private nonisolated static func parsePercent(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "% ")
        )
        guard let level = Int(trimmed), (0...100).contains(level) else {
            return nil
        }
        return level
    }

    private nonisolated static func runSystemProfiler() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let dataBox = BluetoothProfilerDataBox()
        let readFinished = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            dataBox.data = handle.readDataToEndOfFile()
            readFinished.signal()
        }

        guard readFinished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: dataBox.data) else {
            return nil
        }
        return object as? [String: Any]
    }

    private nonisolated static func readIORegistry(
        rules: SystemAccessoryRuleSet
    ) -> [BluetoothAccessoryRecord] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return [] }
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var records: [BluetoothAccessoryRecord] = []
        var seen = Set<String>()
        var entry = IOIteratorNext(iterator)

        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }

            guard let properties = properties(of: entry),
                  let level = integer(properties["BatteryPercent"]),
                  (0...100).contains(level) else {
                continue
            }

            let transportValue = (properties["Transport"] as? String) ?? ""
            let address = properties["DeviceAddress"] as? String
            let isAppleAccessory = ioRegistryIdentifiesApple(
                properties,
                rules: rules
            )
            guard address != nil
                    || transportValue.localizedCaseInsensitiveContains("Bluetooth")
                    || isAppleAccessory else {
                continue
            }

            let id: String
            if let address {
                id = "bluetooth:\(normalizeAddress(address))"
            } else {
                var registryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else {
                    continue
                }
                id = "bluetooth:ioreg-\(registryID)"
            }
            guard seen.insert(id).inserted else { continue }

            let transport: BluetoothBatteryTransport
            if transportValue.localizedCaseInsensitiveContains("LowEnergy") {
                transport = .bluetoothLowEnergy
            } else if address != nil
                        || transportValue.localizedCaseInsensitiveContains("Bluetooth") {
                transport = .bluetooth
            } else {
                transport = .usb
            }
            let kind = rules.kind(
                name: properties["Product"] as? String,
                minorType: nil,
                usagePage: integer(properties["PrimaryUsagePage"]),
                usage: integer(properties["PrimaryUsage"]),
                components: [
                    BatteryComponentReading(kind: .main, level: level),
                ],
                isAppleAccessory: isAppleAccessory
            )

            records.append(
                BluetoothAccessoryRecord(
                    id: id,
                    name: (properties["Product"] as? String)
                        ?? String(localized: "Bluetooth Device"),
                    kind: kind,
                    transport: transport,
                    address: address,
                    components: [
                        BatteryComponentReading(kind: .main, level: level),
                    ],
                    isAppleAccessory: isAppleAccessory
                )
            )
        }

        return records
    }

    private nonisolated static func properties(
        of entry: io_registry_entry_t
    ) -> [String: Any]? {
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            entry,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else {
            return nil
        }
        return unmanagedProperties?.takeRetainedValue() as? [String: Any]
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private nonisolated static func hardwareIdentifier(_ value: Any?) -> Int? {
        if let value = integer(value) { return value }
        guard let value = value as? String else { return nil }
        let lowercaseValue = value.lowercased()
        let normalized = lowercaseValue
            .replacingOccurrences(of: "0x", with: "")
            .split(whereSeparator: { !$0.isHexDigit })
            .first
        guard let normalized else { return nil }
        return Int(normalized, radix: lowercaseValue.contains("0x") ? 16 : 10)
    }

    private nonisolated static func ioRegistryIdentifiesApple(
        _ properties: [String: Any],
        rules: SystemAccessoryRuleSet
    ) -> Bool {
        let vendorIDs = [
            hardwareIdentifier(properties["VendorID"]),
            hardwareIdentifier(properties["idVendor"]),
        ]
        return rules.identifiesApple(
            vendorID: vendorIDs.compactMap { $0 }.first,
            manufacturer: properties["Manufacturer"] as? String,
            productName: properties["Product"] as? String
        )
    }

    private nonisolated static func normalizeAddress(_ address: String) -> String {
        address
            .lowercased()
            .filter { $0.isHexDigit }
    }

}

private final class BluetoothProfilerDataBox: @unchecked Sendable {
    nonisolated(unsafe) var data = Data()

    nonisolated init() {}
}
