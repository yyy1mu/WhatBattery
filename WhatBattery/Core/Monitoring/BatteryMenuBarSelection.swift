import Foundation

struct BatteryMenuBarCandidate: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let symbolName: String
    let level: Int
}

enum BatteryMenuBarSelection {
    static func lowest(
        in candidates: [BatteryMenuBarCandidate]
    ) -> BatteryMenuBarCandidate? {
        candidates
            .filter { (0...100).contains($0.level) }
            .min { lhs, rhs in
                if lhs.level != rhs.level {
                    return lhs.level < rhs.level
                }

                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
    }
}

extension BatteryDeviceController {
    var menuBarCandidate: BatteryMenuBarCandidate? {
        guard isAvailable, let reading else { return nil }

        return BatteryMenuBarCandidate(
            id: "usb:\(id)",
            name: rule.displayName,
            symbolName: rule.symbolName,
            level: reading.level
        )
    }
}

extension BluetoothBatteryDevice {
    var menuBarCandidate: BatteryMenuBarCandidate {
        BatteryMenuBarCandidate(
            id: id,
            name: name,
            symbolName: symbolName,
            level: level
        )
    }
}
