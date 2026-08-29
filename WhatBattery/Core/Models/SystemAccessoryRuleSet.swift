import Foundation

struct SystemAccessoryKindRule: Codable, Equatable, Sendable {
    let kind: BluetoothBatteryDeviceKind
    let nameContains: [String]
    let minorTypeContains: [String]
    let usagePage: HIDNumber?
    let usage: HIDNumber?
    let componentKindsAny: [BatteryComponentKind]
    let requiresAppleAccessory: Bool

    nonisolated func matches(
        name: String?,
        minorType: String?,
        usagePage actualUsagePage: Int?,
        usage actualUsage: Int?,
        componentKinds: Set<BatteryComponentKind>,
        isAppleAccessory: Bool
    ) -> Bool {
        if requiresAppleAccessory, !isAppleAccessory { return false }

        let normalizedName = name?.lowercased() ?? ""
        let normalizedMinorType = minorType?.lowercased() ?? ""
        let matchesName = nameContains.contains {
            normalizedName.contains($0.lowercased())
        }
        let matchesMinorType = minorTypeContains.contains {
            normalizedMinorType.contains($0.lowercased())
        }
        let matchesUsage: Bool
        if let configuredPage = usagePage?.value {
            matchesUsage = configuredPage == actualUsagePage
                && (usage.map { $0.value == actualUsage } ?? true)
        } else {
            matchesUsage = false
        }
        let matchesComponents = !componentKindsAny.isEmpty
            && !componentKinds.isDisjoint(with: componentKindsAny)

        return matchesName || matchesMinorType || matchesUsage || matchesComponents
    }
}

struct SystemAccessoryRuleSet: Codable, Equatable, Sendable {
    let appleVendorIDs: [HIDNumber]
    let appleNameContains: [String]
    let kindRules: [SystemAccessoryKindRule]

    nonisolated static let empty = Self(
        appleVendorIDs: [],
        appleNameContains: [],
        kindRules: []
    )

    nonisolated func identifiesApple(
        vendorID: Int?,
        manufacturer: String?,
        productName: String?
    ) -> Bool {
        if let vendorID,
           appleVendorIDs.contains(where: { $0.value == vendorID }) {
            return true
        }

        let names = [manufacturer, productName]
            .compactMap { $0?.lowercased() }
        return appleNameContains.contains { keyword in
            names.contains { $0.contains(keyword.lowercased()) }
        }
    }

    nonisolated func kind(
        name: String?,
        minorType: String?,
        usagePage: Int?,
        usage: Int?,
        components: [BatteryComponentReading],
        isAppleAccessory: Bool
    ) -> BluetoothBatteryDeviceKind {
        let componentKinds = Set(components.map(\.kind))
        return kindRules.first {
            $0.matches(
                name: name,
                minorType: minorType,
                usagePage: usagePage,
                usage: usage,
                componentKinds: componentKinds,
                isAppleAccessory: isAppleAccessory
            )
        }?.kind ?? .other
    }

    nonisolated var validationProblem: String? {
        if appleVendorIDs.contains(where: { $0.value > 0xFFFF }) {
            return "An Apple vendor ID is larger than 0xFFFF."
        }
        if appleNameContains.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return "Apple product-name keywords cannot be empty."
        }
        if kindRules.isEmpty {
            return "At least one system accessory kind rule is required."
        }

        for rule in kindRules {
            if case (nil, .some) = (rule.usagePage, rule.usage) {
                return "A system accessory usage requires a usagePage."
            }
            if [rule.usagePage, rule.usage]
                .compactMap({ $0?.value })
                .contains(where: { $0 > 0xFFFF }) {
                return "A system accessory usage is larger than 0xFFFF."
            }
            let hasTextMatch = !(rule.nameContains + rule.minorTypeContains)
                .allSatisfy {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            let hasUsagePage: Bool
            if case .some = rule.usagePage {
                hasUsagePage = true
            } else {
                hasUsagePage = false
            }
            let hasMatch = hasTextMatch
                || hasUsagePage
                || !rule.componentKindsAny.isEmpty
            if !hasMatch {
                return "Each system accessory kind rule needs a matching condition."
            }
        }
        return nil
    }
}
