import Foundation
import IOKit.hid
import os

@MainActor
protocol HIDRuleDeviceManaging: AnyObject {
    var onConnectionChanged: (((any BatteryDeviceSession)?) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start() throws
    func stop()
}

@MainActor
final class HIDRuleDeviceManager: HIDRuleDeviceManaging {
    var onConnectionChanged: (((any BatteryDeviceSession)?) -> Void)?
    var onError: ((Error) -> Void)?

    private let rule: BatteryDeviceRule
    private let manager: IOHIDManager
    private var session: (any BatteryDeviceSession)?
    private var permissionBlockedDevice: IOHIDDevice?
    private var isRunning = false

    init(rule: BatteryDeviceRule) {
        self.rule = rule
        manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
    }

    isolated deinit {
        stop()
    }

    func start() throws {
        guard !isRunning else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatchingMultiple(
            manager,
            matchingDictionaries as CFArray
        )
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            Self.deviceMatchedCallback,
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            Self.deviceRemovedCallback,
            context
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            throw HIDDeviceError.managerOpenFailed(result)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning || session != nil else { return }
        isRunning = false

        session?.close()
        session = nil
        permissionBlockedDevice = nil
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private var matchingDictionaries: [[String: Any]] {
        let identifiers: [(vendorID: HIDNumber, productID: HIDNumber?)]
        if rule.match.deviceIDs.isEmpty {
            let productIDs: [HIDNumber?] = rule.match.productIDs.isEmpty
                ? [nil]
                : rule.match.productIDs.map(Optional.some)
            identifiers = rule.match.vendorIDs.flatMap { vendorID in
                productIDs.map { (vendorID, $0) }
            }
        } else {
            identifiers = rule.match.deviceIDs.map {
                ($0.vendorID, Optional($0.productID))
            }
        }

        return identifiers.map { identifier in
            var matching: [String: Any] = [
                kIOHIDVendorIDKey as String: identifier.vendorID.value,
            ]
            if let productID = identifier.productID {
                matching[kIOHIDProductIDKey as String] = productID.value
            }
            if let transport = rule.match.transport {
                matching[kIOHIDTransportKey as String] = transport
            }

            switch rule.match.usageMatch {
            case .primary:
                matching[kIOHIDPrimaryUsagePageKey as String] = rule.match.usagePage.value
                if let usage = rule.match.usage {
                    matching[kIOHIDPrimaryUsageKey as String] = usage.value
                }
            case .any:
                matching[kIOHIDDeviceUsagePageKey as String] = rule.match.usagePage.value
                if let usage = rule.match.usage {
                    matching[kIOHIDDeviceUsageKey as String] = usage.value
                }
            }
            return matching
        }
    }

    private func ensureInputMonitoringAccess() throws {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return
        case kIOHIDAccessTypeUnknown:
            guard IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) else {
                throw HIDRuleDeviceManagerError.inputMonitoringPermissionRequired
            }
        case kIOHIDAccessTypeDenied:
            throw HIDRuleDeviceManagerError.inputMonitoringPermissionRequired
        default:
            throw HIDRuleDeviceManagerError.inputMonitoringPermissionRequired
        }
    }

    private func didMatch(_ device: IOHIDDevice) {
        let descriptor = HIDDeviceDescriptor(
            device: device,
            fallbackProductName: rule.displayName
        )
        guard rule.match.matches(descriptor),
              session == nil,
              permissionBlockedDevice == nil else { return }

        AppLog.hid.info(
            "规则 \(self.rule.id, privacy: .public) 匹配 HID：\(descriptor.description, privacy: .public)，input=\(descriptor.maximumInputReportLength)，output=\(descriptor.maximumOutputReportLength)"
        )

        do {
            if rule.requiresInputMonitoring {
                try ensureInputMonitoringAccess()
            }

            let newSession = try ConfiguredHIDSession(device: device, rule: rule)
            session = newSession
            onConnectionChanged?(newSession)
        } catch {
            if let managerError = error as? HIDRuleDeviceManagerError,
               managerError == .inputMonitoringPermissionRequired {
                permissionBlockedDevice = device
            }
            onError?(error)
            AppLog.hid.error(
                "规则 \(self.rule.id, privacy: .public) 无法打开 HID interface：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func didRemove(_ device: IOHIDDevice) {
        if let permissionBlockedDevice,
           CFEqual(permissionBlockedDevice, device) {
            self.permissionBlockedDevice = nil
            onConnectionChanged?(nil)
            return
        }

        guard let session, session.represents(device) else { return }

        AppLog.hid.info("规则 \(self.rule.id, privacy: .public) 的 HID interface 已断开")
        session.close()
        self.session = nil
        onConnectionChanged?(nil)
    }

    private static let deviceMatchedCallback: IOHIDDeviceCallback = {
        context,
        _,
        _,
        device in
        guard let context else { return }
        let manager = Unmanaged<HIDRuleDeviceManager>
            .fromOpaque(context)
            .takeUnretainedValue()

        // This manager is scheduled on the main run loop in start().
        MainActor.assumeIsolated {
            manager.didMatch(device)
        }
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = {
        context,
        _,
        _,
        device in
        guard let context else { return }
        let manager = Unmanaged<HIDRuleDeviceManager>
            .fromOpaque(context)
            .takeUnretainedValue()

        MainActor.assumeIsolated {
            manager.didRemove(device)
        }
    }
}

enum HIDRuleDeviceManagerError: LocalizedError, Equatable {
    case inputMonitoringPermissionRequired

    var errorDescription: String? {
        switch self {
        case .inputMonitoringPermissionRequired:
            String(
                localized: "Input Monitoring permission is required for this device rule.",
                comment: "Error shown when a rule needs access to a protected keyboard HID interface."
            )
        }
    }
}
