import Foundation
import Observation

@MainActor
@Observable
final class BatteryMonitor {
    private(set) var devices: [BatteryDeviceController] = []
    let bluetooth: BluetoothBatteryMonitor
    let standardHID: StandardHIDBatteryMonitor
    let history: BatteryHistoryStore
    private(set) var ruleRegistrations: [DeviceRuleRegistration] = []
    private(set) var ruleIssues: [DeviceRuleIssue] = []
    private(set) var ruleFileError: String?
    private(set) var isInputMonitoringEnabled: Bool
    private(set) var inputMonitoringStatus: InputMonitoringAuthorizationStatus

    @ObservationIgnored
    private let ruleStore: DeviceRuleStore

    @ObservationIgnored
    private let inputMonitoringAccess: any InputMonitoringAccessProviding

    @ObservationIgnored
    private var isStarted = false

    init(
        ruleStore: DeviceRuleStore? = nil,
        bluetooth: BluetoothBatteryMonitor? = nil,
        standardHID: StandardHIDBatteryMonitor? = nil,
        history: BatteryHistoryStore? = nil,
        inputMonitoringAccess: (any InputMonitoringAccessProviding)? = nil
    ) {
        let ruleStore = ruleStore ?? DeviceRuleStore()
        let inputMonitoringAccess = inputMonitoringAccess
            ?? SystemInputMonitoringAccess()
        let rules = ruleStore.load()
        let history = history ?? BatteryHistoryStore()
        let inputMonitoringEnabled = ruleStore.isInputMonitoringEnabled
        self.ruleStore = ruleStore
        self.inputMonitoringAccess = inputMonitoringAccess
        isInputMonitoringEnabled = inputMonitoringEnabled
        inputMonitoringStatus = inputMonitoringEnabled
            ? inputMonitoringAccess.authorizationStatus()
            : .notChecked
        self.history = history
        self.bluetooth = bluetooth ?? BluetoothBatteryMonitor(
            accessoryRules: rules.systemAccessoryRules
        )
        self.standardHID = standardHID ?? StandardHIDBatteryMonitor(
            accessoryRules: rules.systemAccessoryRules
        )
        self.bluetooth.onDevicesRefreshed = { [weak history] devices, timestamp in
            history?.record(bluetoothDevices: devices, at: timestamp)
        }
        self.standardHID.onDevicesRefreshed = { [weak history] devices, timestamp in
            history?.record(bluetoothDevices: devices, at: timestamp)
        }
        apply(rules)
    }

    isolated deinit {
        devices.forEach { $0.stop() }
        bluetooth.stop()
        standardHID.stop()
    }

    var lowestBatteryDevice: BatteryMenuBarCandidate? {
        let usbCandidates = devices.compactMap(\.menuBarCandidate)
            + standardHID.availableDevices.map(\.menuBarCandidate)
        let bluetoothCandidates = bluetooth.availableDevices.map(\.menuBarCandidate)
        return BatteryMenuBarSelection.lowest(
            in: usbCandidates + bluetoothCandidates
        )
    }

    var batteryDevices: [BatteryDeviceController] {
        devices.filter(\.isAvailable)
    }

    var bluetoothDevices: [BluetoothBatteryDevice] {
        standardHID.availableDevices + bluetooth.availableDevices
    }

    var accessoryCount: Int {
        batteryDevices.count + bluetoothDevices.count
    }

    var isRefreshing: Bool {
        bluetooth.isRefreshing
            || standardHID.isRefreshing
            || devices.contains { $0.isRefreshing }
    }

    var lastCheckedAt: Date? {
        let dates = devices.compactMap(\.lastUpdated)
            + [standardHID.lastUpdated, bluetooth.lastUpdated].compactMap { $0 }
        return dates.max()
    }

    var needsInputMonitoringPermission: Bool {
        guard isInputMonitoringEnabled else { return false }
        let hasEnabledProtectedRule = ruleRegistrations.contains {
            $0.isEnabled && $0.rule.requiresInputMonitoring
        }
        return devices.contains(where: \.needsInputMonitoringPermission)
            || (hasEnabledProtectedRule && inputMonitoringStatus != .granted)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshInputMonitoringPermission()
        devices.forEach { $0.start() }
        standardHID.start()
        bluetooth.start()
    }

    func refreshAll() {
        devices.forEach { $0.refreshNow() }
        standardHID.refreshNow()
        bluetooth.refreshNow()
    }

    func reloadRules() {
        let shouldRestart = isStarted
        devices.forEach { $0.stop() }
        loadRules()
        if shouldRestart {
            devices.forEach { $0.start() }
            standardHID.refreshNow()
            bluetooth.refreshNow()
        }
    }

    func setRuleEnabled(_ isEnabled: Bool, ruleID: String) {
        ruleStore.setEnabled(isEnabled, for: ruleID)
        reloadRules()
    }

    func setInputMonitoringEnabled(_ isEnabled: Bool) {
        guard isInputMonitoringEnabled != isEnabled else {
            refreshInputMonitoringPermission()
            return
        }

        ruleStore.setInputMonitoringEnabled(isEnabled)
        isInputMonitoringEnabled = isEnabled
        inputMonitoringStatus = isEnabled ? .notDetermined : .notChecked

        if isEnabled {
            _ = inputMonitoringAccess.requestAccess()
            inputMonitoringStatus = inputMonitoringAccess.authorizationStatus()
        }
        reloadRules()
    }

    func requestInputMonitoringPermission() {
        guard isInputMonitoringEnabled else { return }
        _ = inputMonitoringAccess.requestAccess()
        refreshInputMonitoringPermission()
    }

    func refreshInputMonitoringPermission() {
        guard isInputMonitoringEnabled else {
            inputMonitoringStatus = .notChecked
            return
        }

        let previousStatus = inputMonitoringStatus
        inputMonitoringStatus = inputMonitoringAccess.authorizationStatus()
        let hasBlockedDevice = devices.contains(
            where: \.needsInputMonitoringPermission
        )
        if inputMonitoringStatus == .granted,
           isStarted,
           (previousStatus != .granted || hasBlockedDevice) {
            reloadRules()
        }
    }

    func prepareRulesDirectory() -> URL? {
        do {
            let url = try ruleStore.prepareRulesDirectory()
            ruleFileError = nil
            return url
        } catch {
            ruleFileError = error.localizedDescription
            return nil
        }
    }

    func clearRuleFileError() {
        ruleFileError = nil
    }

    func device(for ruleID: String) -> BatteryDeviceController? {
        devices.first { $0.id == ruleID }
    }

    private func loadRules() {
        apply(ruleStore.load())
    }

    private func apply(_ result: (
        registrations: [DeviceRuleRegistration],
        issues: [DeviceRuleIssue],
        systemAccessoryRules: SystemAccessoryRuleSet
    )) {
        ruleRegistrations = result.registrations
        ruleIssues = result.issues
        bluetooth.updateAccessoryRules(result.systemAccessoryRules)
        standardHID.updateAccessoryRules(result.systemAccessoryRules)
        devices = result.registrations
            .filter { registration in
                registration.isEnabled
                    && (isInputMonitoringEnabled
                        || !registration.rule.requiresInputMonitoring)
            }
            .map { registration in
                BatteryDeviceController(
                    rule: registration.rule,
                    onReading: { [weak history] reading, timestamp in
                        history?.record(
                            deviceID: "hid:\(registration.rule.id)",
                            name: registration.rule.displayName,
                            symbolName: registration.rule.symbolName,
                            reading: reading,
                            at: timestamp
                        )
                    }
                )
            }
    }
}
