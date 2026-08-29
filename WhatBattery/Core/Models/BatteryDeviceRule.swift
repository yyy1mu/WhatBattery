import Foundation

struct BatteryDeviceRule: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let symbolName: String
    let match: HIDMatchRule
    let protocolDefinition: HIDProtocolDefinition
    let pollingIntervalSeconds: Double
    let requiresInputMonitoring: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case symbolName
        case match
        case protocolDefinition = "protocol"
        case pollingIntervalSeconds
        case requiresInputMonitoring
    }

    init(
        id: String,
        displayName: String,
        symbolName: String,
        match: HIDMatchRule,
        protocolDefinition: HIDProtocolDefinition,
        pollingIntervalSeconds: Double,
        requiresInputMonitoring: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.match = match
        self.protocolDefinition = protocolDefinition
        self.pollingIntervalSeconds = pollingIntervalSeconds
        self.requiresInputMonitoring = requiresInputMonitoring
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        symbolName = try container.decodeIfPresent(
            String.self,
            forKey: .symbolName
        ) ?? "battery.100percent"
        match = try container.decode(HIDMatchRule.self, forKey: .match)
        protocolDefinition = try container.decode(
            HIDProtocolDefinition.self,
            forKey: .protocolDefinition
        )
        pollingIntervalSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .pollingIntervalSeconds
        ) ?? 300
        requiresInputMonitoring = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresInputMonitoring
        ) ?? false
    }
}

enum DeviceRuleCatalogMode: String, Codable, Equatable, Sendable {
    case complete
}

struct DeviceRuleCatalog: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let catalogMode: DeviceRuleCatalogMode?
    let systemAccessoryRules: SystemAccessoryRuleSet?
    let rules: [BatteryDeviceRule]
}

struct DeviceRuleRegistration: Equatable, Identifiable, Sendable {
    let rule: BatteryDeviceRule
    let isEnabled: Bool

    var id: String { rule.id }
}

struct DeviceRuleIssue: Equatable, Identifiable, Sendable {
    let id = UUID()
    let message: String
}
