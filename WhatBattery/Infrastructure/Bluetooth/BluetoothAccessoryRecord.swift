import Foundation

struct BluetoothAccessoryRecord: Equatable, Sendable {
    let id: String
    let name: String
    let kind: BluetoothBatteryDeviceKind
    let transport: BluetoothBatteryTransport
    let address: String?
    let components: [BatteryComponentReading]
    let isAppleAccessory: Bool
    let connectionState: BluetoothBatteryConnectionState

    nonisolated init(
        id: String,
        name: String,
        kind: BluetoothBatteryDeviceKind,
        transport: BluetoothBatteryTransport,
        address: String?,
        components: [BatteryComponentReading],
        isAppleAccessory: Bool = false,
        connectionState: BluetoothBatteryConnectionState = .connected
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.transport = transport
        self.address = address
        self.components = components
        self.isAppleAccessory = isAppleAccessory
        self.connectionState = connectionState
    }

    nonisolated var hasBattery: Bool {
        !components.isEmpty
    }
}

enum BluetoothAccessoryMerger {
    static func merge(
        system: [BluetoothAccessoryRecord],
        ble: [BluetoothAccessoryRecord],
        checkedAt: Date
    ) -> [BluetoothBatteryDevice] {
        var recordsByID = Dictionary(
            uniqueKeysWithValues: system.map { ($0.id, $0) }
        )

        let systemNameCounts = Dictionary(
            grouping: system,
            by: { normalizedName($0.name) }
        ).mapValues(\.count)
        let bleNameCounts = Dictionary(
            grouping: ble,
            by: { normalizedName($0.name) }
        ).mapValues(\.count)

        for bleRecord in ble {
            let normalized = normalizedName(bleRecord.name)
            let matchingSystem = system.first {
                normalizedName($0.name) == normalized
            }

            if let matchingSystem,
               systemNameCounts[normalized] == 1,
               bleNameCounts[normalized] == 1 {
                if !matchingSystem.hasBattery {
                    recordsByID[matchingSystem.id] = BluetoothAccessoryRecord(
                        id: matchingSystem.id,
                        name: matchingSystem.name,
                        kind: matchingSystem.kind == .other
                            ? bleRecord.kind
                            : matchingSystem.kind,
                        transport: .bluetoothLowEnergy,
                        address: matchingSystem.address,
                        components: bleRecord.components,
                        isAppleAccessory: matchingSystem.isAppleAccessory
                    )
                } else if matchingSystem.connectionState == .lastKnown {
                    recordsByID[matchingSystem.id] = BluetoothAccessoryRecord(
                        id: matchingSystem.id,
                        name: matchingSystem.name,
                        kind: matchingSystem.kind == .other
                            ? bleRecord.kind
                            : matchingSystem.kind,
                        transport: .bluetoothLowEnergy,
                        address: matchingSystem.address,
                        components: matchingSystem.components,
                        isAppleAccessory: matchingSystem.isAppleAccessory,
                        connectionState: .connected
                    )
                }
            } else {
                recordsByID[bleRecord.id] = bleRecord
            }
        }

        return recordsByID.values
            .filter(\.hasBattery)
            .map { record in
                BluetoothBatteryDevice(
                    id: record.id,
                    name: record.name,
                    kind: record.kind,
                    transport: record.transport,
                    address: record.address,
                    components: record.components,
                    isAppleAccessory: record.isAppleAccessory,
                    connectionState: record.connectionState,
                    checkedAt: checkedAt
                )
            }
            .sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
