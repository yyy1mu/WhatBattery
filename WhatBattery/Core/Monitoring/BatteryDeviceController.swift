import Foundation
import IOKit
import Observation
import os

@MainActor
@Observable
final class BatteryDeviceController: Identifiable {
    let rule: BatteryDeviceRule

    private(set) var reading: BatteryReading?
    private(set) var status: BatteryDeviceStatus = .searching
    private(set) var deviceInfo: HIDDeviceDescriptor?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored
    private let deviceManager: any HIDRuleDeviceManaging

    @ObservationIgnored
    private let onReading: ((BatteryReading, Date) -> Void)?

    @ObservationIgnored
    private var session: (any BatteryDeviceSession)?

    @ObservationIgnored
    private var refreshLoop: Task<Void, Never>?

    @ObservationIgnored
    private var connectionID = UUID()

    @ObservationIgnored
    private var isStarted = false

    var id: String { rule.id }

    init(
        rule: BatteryDeviceRule,
        deviceManager: any HIDRuleDeviceManaging,
        onReading: ((BatteryReading, Date) -> Void)? = nil
    ) {
        self.rule = rule
        self.deviceManager = deviceManager
        self.onReading = onReading
        deviceManager.onConnectionChanged = { [weak self] session in
            self?.connectionChanged(session)
        }
        deviceManager.onError = { [weak self] error in
            self?.deviceManagerFailed(error)
        }
    }

    convenience init(
        rule: BatteryDeviceRule,
        onReading: ((BatteryReading, Date) -> Void)? = nil
    ) {
        self.init(
            rule: rule,
            deviceManager: HIDRuleDeviceManager(rule: rule),
            onReading: onReading
        )
    }

    isolated deinit {
        refreshLoop?.cancel()
        deviceManager.stop()
    }

    var batteryText: String {
        reading.map { "\($0.level)%" } ?? "--%"
    }

    var statusText: String {
        switch status {
        case .searching:
            String(
                localized: "Searching for \(rule.displayName)…",
                comment: "Status shown while a configured USB battery device is not connected."
            )
        case .reading:
            String(
                localized: "Reading battery level…",
                comment: "Status shown while requesting a USB device battery level."
            )
        case .connected:
            String(
                localized: "Connected",
                comment: "Status shown after a successful battery reading."
            )
        case .peripheralOffline:
            String(
                localized: "The receiver is connected, but the peripheral is offline.",
                comment: "Status shown when a receiver cannot reach its wireless peripheral."
            )
        case .sleeping:
            String(
                localized: "The device did not respond. Keeping the last battery level.",
                comment: "Status shown after a USB battery request times out."
            )
        case .permissionRequired:
            String(
                localized: "Allow Input Monitoring access, then restart the app.",
                comment: "Status shown when macOS blocks a protected HID interface."
            )
        case .unsupported:
            String(
                localized: "The matched device does not expose the expected battery feature.",
                comment: "Status shown when a device matches a rule but not its battery protocol."
            )
        case .error(let message):
            message
        }
    }

    var chargingText: String? {
        guard let isCharging = reading?.isCharging else { return nil }
        return isCharging
            ? String(localized: "Charging", comment: "A peripheral battery is charging.")
            : String(localized: "Not charging", comment: "A peripheral battery is not charging.")
    }

    var canRefresh: Bool {
        session != nil && !isRefreshing
    }

    var needsInputMonitoringPermission: Bool {
        status == .permissionRequired
    }

    var isAvailable: Bool {
        guard deviceInfo != nil, reading != nil else { return false }

        switch status {
        case .connected, .sleeping:
            return true
        case .searching, .reading, .peripheralOffline, .permissionRequired,
             .unsupported, .error:
            return false
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        do {
            try deviceManager.start()
        } catch HIDRuleDeviceManagerError.inputMonitoringPermissionRequired {
            setStatus(.permissionRequired)
            AppLog.hid.notice(
                "规则 \(self.rule.id, privacy: .public) 需要输入监控权限"
            )
        } catch {
            setStatus(.error(error.localizedDescription))
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        connectionID = UUID()
        refreshLoop?.cancel()
        refreshLoop = nil
        session = nil
        isRefreshing = false
        deviceManager.stop()
    }

    func refreshNow() {
        guard let session else { return }
        let currentConnectionID = connectionID

        Task { [weak self, session] in
            await self?.refreshBattery(
                using: session,
                connectionID: currentConnectionID
            )
        }
    }

    private func connectionChanged(_ newSession: (any BatteryDeviceSession)?) {
        connectionID = UUID()
        let currentConnectionID = connectionID

        refreshLoop?.cancel()
        refreshLoop = nil
        session = nil
        isRefreshing = false

        guard let newSession else {
            deviceInfo = nil
            setStatus(.searching)
            return
        }

        session = newSession
        deviceInfo = newSession.deviceInfo
        setStatus(.reading)

        let pollingInterval = Duration.seconds(rule.pollingIntervalSeconds)
        refreshLoop = Task { [weak self, newSession] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshBattery(
                    using: newSession,
                    connectionID: currentConnectionID
                )

                do {
                    try await Task.sleep(for: pollingInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func deviceManagerFailed(_ error: Error) {
        if case HIDDeviceError.deviceOpenFailed(let code) = error,
           code == kIOReturnNotPermitted {
            setStatus(.permissionRequired)
            return
        }
        setStatus(.error(error.localizedDescription))
    }

    private func refreshBattery(
        using session: any BatteryDeviceSession,
        connectionID: UUID
    ) async {
        guard connectionID == self.connectionID, !isRefreshing else { return }

        isRefreshing = true
        if reading == nil {
            setStatus(.reading)
        }

        defer {
            if connectionID == self.connectionID {
                isRefreshing = false
            }
        }

        do {
            let newReading = try await session.readBattery()
            guard connectionID == self.connectionID, !Task.isCancelled else {
                return
            }

            if reading != newReading {
                reading = newReading
            }
            let updatedAt = Date()
            lastUpdated = updatedAt
            setStatus(.connected)
            onReading?(newReading, updatedAt)
            AppLog.battery.info(
                "\(self.rule.displayName, privacy: .public) 电量：\(newReading.level)%"
            )
        } catch is CancellationError {
            return
        } catch BatterySessionError.unresponsive {
            guard connectionID == self.connectionID else { return }
            setStatus(.sleeping)
        } catch BatterySessionError.peripheralOffline {
            guard connectionID == self.connectionID else { return }
            setStatus(.peripheralOffline)
        } catch BatterySessionError.unsupported {
            guard connectionID == self.connectionID else { return }
            setStatus(.unsupported)
        } catch BatterySessionError.permissionRequired {
            guard connectionID == self.connectionID else { return }
            setStatus(.permissionRequired)
        } catch {
            guard connectionID == self.connectionID else { return }
            setStatus(.error(error.localizedDescription))
            AppLog.battery.error(
                "读取 \(self.rule.displayName, privacy: .public) 电量失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func setStatus(_ newValue: BatteryDeviceStatus) {
        guard status != newValue else { return }
        status = newValue
    }
}
