import Foundation
import IOKit.hid
import Observation
import os

@MainActor
@Observable
final class StandardHIDBatteryMonitor {
    private(set) var devices: [BluetoothBatteryDevice] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    @ObservationIgnored
    private let manager: IOHIDManager

    @ObservationIgnored
    private let pollingInterval: Duration

    @ObservationIgnored
    private var accessoryRules: SystemAccessoryRuleSet

    @ObservationIgnored
    private var refreshLoop: Task<Void, Never>?

    @ObservationIgnored
    private var isStarted = false

    @ObservationIgnored
    var onDevicesRefreshed: (([BluetoothBatteryDevice], Date) -> Void)?

    init(
        accessoryRules: SystemAccessoryRuleSet = .empty,
        pollingInterval: Duration = .seconds(300)
    ) {
        self.accessoryRules = accessoryRules
        self.pollingInterval = pollingInterval
        manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
    }

    isolated deinit {
        refreshLoop?.cancel()
        if isStarted {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    var availableDevices: [BluetoothBatteryDevice] {
        devices.filter(\.isAvailable)
    }

    func updateAccessoryRules(_ rules: SystemAccessoryRuleSet) {
        accessoryRules = rules
    }

    func start() {
        guard !isStarted else { return }

        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDTransportKey as String: "USB"] as CFDictionary
        )
        let result = IOHIDManagerOpen(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        guard result == kIOReturnSuccess else {
            AppLog.hid.error(
                "无法启动标准 HID 电量监控器：IOKit 0x\(String(result, radix: 16), privacy: .public)"
            )
            return
        }

        isStarted = true
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refresh()
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
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func refreshNow() {
        refresh()
    }

    func refresh() {
        guard isStarted, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let checkedAt = Date()
        let hidDevices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
            ?? []
        let newDevices = hidDevices.compactMap { device in
            readDevice(device, checkedAt: checkedAt)
        }.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        if devices != newDevices {
            devices = newDevices
        }
        lastUpdated = checkedAt
        onDevicesRefreshed?(newDevices, checkedAt)

        if !newDevices.isEmpty {
            AppLog.hid.info(
                "标准 HID 电量刷新完成：可用=\(newDevices.count)"
            )
        }
    }

    private func readDevice(
        _ device: IOHIDDevice,
        checkedAt: Date
    ) -> BluetoothBatteryDevice? {
        guard let element = preferredBatteryElement(in: device) else {
            return nil
        }

        let valuePointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>
            .allocate(capacity: 1)
        defer { valuePointer.deallocate() }
        let result = IOHIDDeviceGetValue(device, element, valuePointer)
        guard result == kIOReturnSuccess else { return nil }
        let value = valuePointer.pointee.takeUnretainedValue()

        let rawValue = IOHIDValueGetIntegerValue(value)
        guard let level = StandardHIDBatteryScale.percentage(
            rawValue: rawValue,
            logicalMinimum: IOHIDElementGetLogicalMin(element),
            logicalMaximum: IOHIDElementGetLogicalMax(element)
        ) else { return nil }

        let descriptor = HIDDeviceDescriptor(
            device: device,
            fallbackProductName: "USB HID Device"
        )
        let isAppleAccessory = accessoryRules.identifiesApple(
            vendorID: descriptor.vendorID,
            manufacturer: nil,
            productName: descriptor.productName
        )
        let kind = accessoryRules.kind(
            name: descriptor.productName,
            minorType: nil,
            usagePage: descriptor.primaryUsagePage,
            usage: descriptor.primaryUsage,
            components: [],
            isAppleAccessory: isAppleAccessory
        )

        AppLog.hid.info(
            "标准 HID：\(descriptor.description, privacy: .public) 电量：\(level)%"
        )
        return BluetoothBatteryDevice(
            id: standardDeviceID(for: descriptor),
            name: descriptor.productName,
            kind: kind,
            transport: .usb,
            address: nil,
            components: [BatteryComponentReading(kind: .main, level: level)],
            isAppleAccessory: isAppleAccessory,
            connectionState: .connected,
            checkedAt: checkedAt
        )
    }

    private func preferredBatteryElement(
        in device: IOHIDDevice
    ) -> IOHIDElement? {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return nil }

        let preferences: [(page: UInt32, usage: UInt32)] = [
            (0x06, 0x20), // Generic Device Controls / Battery Strength
            (0x85, 0x64), // Battery System / Relative State of Charge
            (0x85, 0x65), // Battery System / Absolute State of Charge
        ]
        for preference in preferences {
            if let element = elements.first(where: {
                IOHIDElementGetUsagePage($0) == preference.page
                    && IOHIDElementGetUsage($0) == preference.usage
                    && IOHIDElementGetLogicalMax($0)
                        > IOHIDElementGetLogicalMin($0)
            }) {
                return element
            }
        }
        return nil
    }

    private func standardDeviceID(for descriptor: HIDDeviceDescriptor) -> String {
        let identity = descriptor.serialNumber
            ?? descriptor.locationID.map(String.init)
            ?? descriptor.productName
        return String(
            format: "hid-standard:%04X:%04X:%@",
            descriptor.vendorID,
            descriptor.productID,
            identity
        )
    }
}

enum StandardHIDBatteryScale {
    nonisolated static func percentage(
        rawValue: Int,
        logicalMinimum: Int,
        logicalMaximum: Int
    ) -> Int? {
        guard logicalMaximum > logicalMinimum,
              rawValue >= logicalMinimum,
              rawValue <= logicalMaximum else { return nil }

        let fraction = Double(rawValue - logicalMinimum)
            / Double(logicalMaximum - logicalMinimum)
        return min(max(Int((fraction * 100).rounded()), 0), 100)
    }
}
