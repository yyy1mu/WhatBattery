import Foundation
import Observation
import os

@MainActor
@Observable
final class BluetoothBatteryMonitor {
    private(set) var devices: [BluetoothBatteryDevice] = []
    private(set) var status: BluetoothBatteryStatus = .idle
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored
    private let systemReader: any SystemBluetoothBatteryReading

    @ObservationIgnored
    private let bleReader: any BLEBatteryServiceReading

    @ObservationIgnored
    private let pollingInterval: Duration

    @ObservationIgnored
    private var refreshLoop: Task<Void, Never>?

    @ObservationIgnored
    private var isStarted = false

    @ObservationIgnored
    var onDevicesRefreshed: (([BluetoothBatteryDevice], Date) -> Void)?

    init(
        accessoryRules: SystemAccessoryRuleSet = .empty,
        systemReader: (any SystemBluetoothBatteryReading)? = nil,
        bleReader: (any BLEBatteryServiceReading)? = nil,
        pollingInterval: Duration = .seconds(300)
    ) {
        self.systemReader = systemReader ?? SystemBluetoothBatteryReader(
            rules: accessoryRules
        )
        self.bleReader = bleReader ?? BLEBatteryServiceReader(
            rules: accessoryRules
        )
        self.pollingInterval = pollingInterval
    }

    isolated deinit {
        refreshLoop?.cancel()
    }

    var statusText: String {
        switch status {
        case .idle:
            String(
                localized: "Waiting to check Apple and Bluetooth accessories…",
                comment: "Initial Apple and Bluetooth battery monitor status."
            )
        case .reading:
            String(
                localized: "Reading Apple and Bluetooth battery levels…",
                comment: "Status while Apple and Bluetooth accessory batteries are being read."
            )
        case .ready:
            devices.isEmpty
                ? String(
                    localized: "No Apple or Bluetooth accessory battery information was found.",
                    comment: "Status after a wireless refresh found no readable accessory battery."
                )
                : String(
                    localized: "Apple and Bluetooth devices are up to date.",
                    comment: "Status after Apple and Bluetooth battery devices were refreshed."
                )
        case .poweredOff:
            String(
                localized: "Bluetooth is turned off.",
                comment: "Status when Bluetooth is disabled on the Mac."
            )
        case .permissionRequired:
            String(
                localized: "Allow Bluetooth access to read BLE battery levels.",
                comment: "Status when Bluetooth privacy permission is denied."
            )
        case .unsupported:
            String(
                localized: "Bluetooth Low Energy is not supported on this Mac.",
                comment: "Status when the Mac cannot act as a BLE central."
            )
        case .error(let message):
            message
        }
    }

    var needsBluetoothPermission: Bool {
        status == .permissionRequired
    }

    var canRefresh: Bool {
        !isRefreshing
    }

    var availableDevices: [BluetoothBatteryDevice] {
        devices.filter(\.isAvailable)
    }

    func updateAccessoryRules(_ rules: SystemAccessoryRuleSet) {
        systemReader.updateRules(rules)
        bleReader.updateRules(rules)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        refreshLoop = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.refresh()
                do {
                    try await Task.sleep(for: self.pollingInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        refreshLoop?.cancel()
        refreshLoop = nil
        isRefreshing = false
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        setStatus(.reading)

        async let systemRecordsTask = systemReader.readAccessories()

        let bleResult: Result<[BluetoothAccessoryRecord], Error>
        do {
            bleResult = .success(try await bleReader.readConnectedAccessories())
        } catch {
            bleResult = .failure(error)
        }

        let systemRecords = await systemRecordsTask
        guard !Task.isCancelled else {
            isRefreshing = false
            return
        }

        let bleRecords: [BluetoothAccessoryRecord]
        switch bleResult {
        case .success(let records):
            bleRecords = records
            setStatus(.ready)
        case .failure(BLEBatteryServiceError.permissionRequired):
            bleRecords = []
            setStatus(.permissionRequired)
        case .failure(BLEBatteryServiceError.poweredOff):
            bleRecords = []
            setStatus(.poweredOff)
        case .failure(BLEBatteryServiceError.unsupported):
            bleRecords = []
            setStatus(.unsupported)
        case .failure(let error):
            bleRecords = []
            setStatus(.error(error.localizedDescription))
        }

        let updatedAt = Date()
        let newDevices = BluetoothAccessoryMerger.merge(
            system: systemRecords,
            ble: bleRecords,
            checkedAt: updatedAt
        )
        if devices != newDevices {
            devices = newDevices
        }
        lastUpdated = updatedAt
        isRefreshing = false
        onDevicesRefreshed?(newDevices.filter(\.isAvailable), updatedAt)

        AppLog.bluetooth.info(
            "蓝牙电量刷新完成：system=\(systemRecords.count)，BLE=\(bleRecords.count)，可用=\(self.availableDevices.count)"
        )
        for device in newDevices {
            AppLog.bluetooth.info(
                "\(device.name, privacy: .public) 电量：\(device.level)%"
            )
        }
    }

    private func setStatus(_ newStatus: BluetoothBatteryStatus) {
        guard status != newStatus else { return }
        status = newStatus
    }
}
