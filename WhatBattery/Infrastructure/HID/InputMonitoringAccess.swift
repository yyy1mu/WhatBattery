import IOKit.hid

enum InputMonitoringAuthorizationStatus: Equatable, Sendable {
    case notChecked
    case notDetermined
    case denied
    case granted
}

@MainActor
protocol InputMonitoringAccessProviding: AnyObject {
    func authorizationStatus() -> InputMonitoringAuthorizationStatus
    @discardableResult func requestAccess() -> Bool
}

@MainActor
final class SystemInputMonitoringAccess: InputMonitoringAccessProviding {
    func authorizationStatus() -> InputMonitoringAuthorizationStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            .granted
        case kIOHIDAccessTypeDenied:
            .denied
        case kIOHIDAccessTypeUnknown:
            .notDetermined
        default:
            .denied
        }
    }

    @discardableResult
    func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
