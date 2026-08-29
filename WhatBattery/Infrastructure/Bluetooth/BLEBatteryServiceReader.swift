@preconcurrency import CoreBluetooth
import Foundation

@MainActor
protocol BLEBatteryServiceReading: AnyObject {
    func readConnectedAccessories() async throws -> [BluetoothAccessoryRecord]
    func updateRules(_ rules: SystemAccessoryRuleSet)
}

enum BLEBatteryServiceError: LocalizedError, Equatable {
    case busy
    case poweredOff
    case permissionRequired
    case unsupported
    case unavailable

    var errorDescription: String? {
        switch self {
        case .busy:
            String(
                localized: "A Bluetooth battery refresh is already running.",
                comment: "Error when two BLE battery refreshes overlap."
            )
        case .poweredOff:
            String(
                localized: "Bluetooth is turned off.",
                comment: "Status when Bluetooth is disabled on the Mac."
            )
        case .permissionRequired:
            String(
                localized: "Bluetooth permission is required to read BLE battery levels.",
                comment: "Status when Bluetooth privacy permission is denied."
            )
        case .unsupported:
            String(
                localized: "Bluetooth Low Energy is not supported on this Mac.",
                comment: "Status when the Mac cannot act as a BLE central."
            )
        case .unavailable:
            String(
                localized: "Bluetooth is temporarily unavailable.",
                comment: "Status while the Bluetooth controller is resetting or unavailable."
            )
        }
    }
}

@MainActor
final class BLEBatteryServiceReader: NSObject, BLEBatteryServiceReading {
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private let timeout: Duration
    private var rules: SystemAccessoryRuleSet

    private var centralManager: CBCentralManager?
    private var continuation: CheckedContinuation<
        [BluetoothAccessoryRecord],
        any Error
    >?
    private var timeoutTask: Task<Void, Never>?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var pendingPeripheralIDs = Set<UUID>()
    private var records: [UUID: BluetoothAccessoryRecord] = [:]
    private var didBeginRead = false

    init(
        rules: SystemAccessoryRuleSet = .empty,
        timeout: Duration = .seconds(5)
    ) {
        self.rules = rules
        self.timeout = timeout
        super.init()
    }

    func updateRules(_ rules: SystemAccessoryRuleSet) {
        self.rules = rules
    }

    func readConnectedAccessories() async throws -> [BluetoothAccessoryRecord] {
        guard continuation == nil else {
            throw BLEBatteryServiceError.busy
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            didBeginRead = false
            peripherals.removeAll(keepingCapacity: true)
            pendingPeripheralIDs.removeAll(keepingCapacity: true)
            records.removeAll(keepingCapacity: true)

            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: self?.timeout ?? .seconds(5))
                } catch {
                    return
                }
                self?.finishWithPartialResults()
            }

            if centralManager == nil {
                centralManager = CBCentralManager(
                    delegate: self,
                    queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
                )
            } else {
                beginReadIfPossible()
            }
        }
    }

    private func beginReadIfPossible() {
        guard continuation != nil,
              !didBeginRead,
              let centralManager else {
            return
        }

        switch centralManager.state {
        case .poweredOn:
            didBeginRead = true
            let connected = centralManager.retrieveConnectedPeripherals(
                withServices: [batteryService]
            )
            guard !connected.isEmpty else {
                finishWithPartialResults()
                return
            }

            for peripheral in connected {
                peripherals[peripheral.identifier] = peripheral
                pendingPeripheralIDs.insert(peripheral.identifier)
                peripheral.delegate = self

                if peripheral.state == .connected {
                    peripheral.discoverServices([batteryService])
                } else {
                    centralManager.connect(peripheral)
                }
            }

        case .unauthorized:
            finish(throwing: BLEBatteryServiceError.permissionRequired)
        case .poweredOff:
            finish(throwing: BLEBatteryServiceError.poweredOff)
        case .unsupported:
            finish(throwing: BLEBatteryServiceError.unsupported)
        case .unknown, .resetting:
            break
        @unknown default:
            finish(throwing: BLEBatteryServiceError.unavailable)
        }
    }

    private func peripheralReadCompleted(_ peripheral: CBPeripheral) {
        pendingPeripheralIDs.remove(peripheral.identifier)
        if pendingPeripheralIDs.isEmpty {
            finishWithPartialResults()
        }
    }

    private func finishWithPartialResults() {
        finish(returning: records.values.sorted { $0.id < $1.id })
    }

    private func finish(returning result: [BluetoothAccessoryRecord]) {
        guard let continuation else { return }
        cleanup()
        continuation.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        guard let continuation else { return }
        cleanup()
        continuation.resume(throwing: error)
    }

    private func cleanup() {
        timeoutTask?.cancel()
        timeoutTask = nil

        if let centralManager {
            for peripheral in peripherals.values {
                peripheral.delegate = nil
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }

        continuation = nil
        didBeginRead = false
        pendingPeripheralIDs.removeAll(keepingCapacity: true)
        peripherals.removeAll(keepingCapacity: true)
        records.removeAll(keepingCapacity: true)
    }

    private func inferredKind(for name: String) -> BluetoothBatteryDeviceKind {
        rules.kind(
            name: name,
            minorType: nil,
            usagePage: nil,
            usage: nil,
            components: [],
            isAppleAccessory: rules.identifiesApple(
                vendorID: nil,
                manufacturer: nil,
                productName: name
            )
        )
    }
}

extension BLEBatteryServiceReader: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        beginReadIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        peripheral.discoverServices([batteryService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        peripheralReadCompleted(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard continuation != nil else { return }
        peripheralReadCompleted(peripheral)
    }
}

extension BLEBatteryServiceReader: CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard error == nil,
              let service = peripheral.services?.first(where: {
                  $0.uuid == batteryService
              }) else {
            peripheralReadCompleted(peripheral)
            return
        }
        peripheral.discoverCharacteristics([batteryLevel], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: {
                  $0.uuid == batteryLevel
              }) else {
            peripheralReadCompleted(peripheral)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        defer { peripheralReadCompleted(peripheral) }

        guard error == nil,
              characteristic.uuid == batteryLevel,
              let rawLevel = characteristic.value?.first,
              rawLevel <= 100 else {
            return
        }

        let name = peripheral.name ?? String(
            localized: "Bluetooth LE Device",
            comment: "Fallback name for a BLE peripheral without a published name."
        )
        records[peripheral.identifier] = BluetoothAccessoryRecord(
            id: "ble:\(peripheral.identifier.uuidString.lowercased())",
            name: name,
            kind: inferredKind(for: name),
            transport: .bluetoothLowEnergy,
            address: nil,
            components: [
                BatteryComponentReading(kind: .main, level: Int(rawLevel)),
            ]
        )
    }
}
