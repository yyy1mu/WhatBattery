import Foundation

@MainActor
final class DeviceRuleStore {
    static let supportedSchemaVersion = 2

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let templateFileURL: URL?
    private let configuredRulesFileURL: URL?
    private let disabledRulesKey = "disabledDeviceRuleIDs"
    private let inputMonitoringEnabledKey = "inputMonitoringEnabled"

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        rulesFileURL: URL? = nil,
        templateFileURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        configuredRulesFileURL = rulesFileURL
        self.templateFileURL = templateFileURL
            ?? bundle.url(forResource: "DeviceRules", withExtension: "json")
    }

    func load() -> (
        registrations: [DeviceRuleRegistration],
        issues: [DeviceRuleIssue],
        systemAccessoryRules: SystemAccessoryRuleSet
    ) {
        var issues: [DeviceRuleIssue] = []

        do {
            try prepareRulesFileIfNeeded()
        } catch {
            issues.append(
                DeviceRuleIssue(
                    message: "Unable to prepare the rules file: \(error.localizedDescription)"
                )
            )
            return ([], issues, .empty)
        }

        var systemAccessoryRules = SystemAccessoryRuleSet.empty
        let disabledIDs = Set(userDefaults.stringArray(forKey: disabledRulesKey) ?? [])
        var registrations: [DeviceRuleRegistration] = []
        var loadedRuleIDs = Set<String>()
        var systemRulesSource: String?

        for sourceURL in catalogFileURLs() {
            let catalog: DeviceRuleCatalog
            do {
                catalog = try Self.decodeCatalog(Data(contentsOf: sourceURL))
            } catch {
                issues.append(
                    DeviceRuleIssue(
                        message: "\(sourceURL.lastPathComponent): \(error.localizedDescription)"
                    )
                )
                continue
            }

            if let configuredRules = catalog.systemAccessoryRules {
                if let problem = configuredRules.validationProblem {
                    issues.append(
                        DeviceRuleIssue(
                            message: "\(sourceURL.lastPathComponent): \(problem)"
                        )
                    )
                } else if let systemRulesSource {
                    issues.append(
                        DeviceRuleIssue(
                            message: "\(sourceURL.lastPathComponent): systemAccessoryRules is already defined by \(systemRulesSource); the later definition was ignored."
                        )
                    )
                } else {
                    systemAccessoryRules = configuredRules
                    systemRulesSource = sourceURL.lastPathComponent
                }
            }

            for rule in catalog.rules {
                if !loadedRuleIDs.insert(rule.id).inserted {
                    issues.append(
                        DeviceRuleIssue(
                            message: "\(sourceURL.lastPathComponent): Duplicate device-rule id: \(rule.id). The later rule was ignored."
                        )
                    )
                    continue
                }
                if let problem = validationProblem(for: rule) {
                    issues.append(
                        DeviceRuleIssue(
                            message: "\(sourceURL.lastPathComponent): \(problem)"
                        )
                    )
                    continue
                }
                registrations.append(
                    DeviceRuleRegistration(
                        rule: rule,
                        isEnabled: !disabledIDs.contains(rule.id)
                    )
                )
            }
        }
        return (registrations, issues, systemAccessoryRules)
    }

    func setEnabled(_ isEnabled: Bool, for ruleID: String) {
        var disabledIDs = Set(userDefaults.stringArray(forKey: disabledRulesKey) ?? [])
        if isEnabled {
            disabledIDs.remove(ruleID)
        } else {
            disabledIDs.insert(ruleID)
        }
        userDefaults.set(disabledIDs.sorted(), forKey: disabledRulesKey)
    }

    var isInputMonitoringEnabled: Bool {
        guard userDefaults.object(forKey: inputMonitoringEnabledKey) != nil else {
            return true
        }
        return userDefaults.bool(forKey: inputMonitoringEnabledKey)
    }

    func setInputMonitoringEnabled(_ isEnabled: Bool) {
        userDefaults.set(isEnabled, forKey: inputMonitoringEnabledKey)
    }

    func prepareRulesFile() throws -> URL {
        try prepareRulesFileIfNeeded()
        return rulesFileURL
    }

    func prepareRulesDirectory() throws -> URL {
        try prepareRulesFileIfNeeded()
        return rulesFileURL.deletingLastPathComponent()
    }

    var rulesFileURL: URL {
        if let configuredRulesFileURL {
            return configuredRulesFileURL
        }
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("WhatBattery", isDirectory: true)
            .appendingPathComponent("device-rules.json", isDirectory: false)
    }

    var additionalRulesDirectoryURL: URL {
        rulesFileURL.deletingLastPathComponent()
            .appendingPathComponent("device-rules.d", isDirectory: true)
    }

    private var legacyRulesFileURL: URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("USB Battery", isDirectory: true)
            .appendingPathComponent("device-rules.json", isDirectory: false)
    }

    private func prepareRulesFileIfNeeded() throws {
        if fileManager.fileExists(atPath: rulesFileURL.path) {
            try createAdditionalRulesDirectory()
            try migrateLegacyCatalogIfNeeded()
            return
        }

        if configuredRulesFileURL == nil,
           fileManager.fileExists(atPath: legacyRulesFileURL.path) {
            try createRulesDirectory()
            try fileManager.copyItem(
                at: legacyRulesFileURL,
                to: rulesFileURL
            )
            try createAdditionalRulesDirectory()
            try migrateLegacyCatalogIfNeeded()
            return
        }

        try createRulesDirectory()
        try createAdditionalRulesDirectory()
        if let templateFileURL {
            try fileManager.copyItem(at: templateFileURL, to: rulesFileURL)
            try migrateLegacyCatalogIfNeeded()
            return
        }

        let emptyCatalog = DeviceRuleCatalog(
            schemaVersion: Self.supportedSchemaVersion,
            catalogMode: .complete,
            systemAccessoryRules: nil,
            rules: []
        )
        try writeCatalog(emptyCatalog)
    }

    private func migrateLegacyCatalogIfNeeded() throws {
        guard let templateFileURL else { return }

        let existingCatalog = try Self.decodeCatalog(
            Data(contentsOf: rulesFileURL)
        )
        guard existingCatalog.catalogMode != .complete else { return }

        let templateCatalog = try Self.decodeCatalog(
            Data(contentsOf: templateFileURL)
        )
        var mergedRules = templateCatalog.rules
        for existingRule in existingCatalog.rules {
            if let index = mergedRules.firstIndex(where: {
                $0.id == existingRule.id
            }) {
                mergedRules[index] = existingRule
            } else {
                mergedRules.append(existingRule)
            }
        }

        try writeCatalog(
            DeviceRuleCatalog(
                schemaVersion: Self.supportedSchemaVersion,
                catalogMode: .complete,
                systemAccessoryRules: existingCatalog.systemAccessoryRules
                    ?? templateCatalog.systemAccessoryRules,
                rules: mergedRules
            )
        )
    }

    private func writeCatalog(_ catalog: DeviceRuleCatalog) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try encoder.encode(catalog).write(to: rulesFileURL, options: .atomic)
    }

    private func createRulesDirectory() throws {
        try fileManager.createDirectory(
            at: rulesFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func createAdditionalRulesDirectory() throws {
        try fileManager.createDirectory(
            at: additionalRulesDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func catalogFileURLs() -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        let additionalURLs = (try? fileManager.contentsOfDirectory(
            at: additionalRulesDirectoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let jsonFiles = additionalURLs.filter { url in
            guard url.pathExtension.caseInsensitiveCompare("json") == .orderedSame,
                  let values = try? url.resourceValues(forKeys: resourceKeys) else {
                return false
            }
            return values.isRegularFile == true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
        return [rulesFileURL] + jsonFiles
    }

    static func decodeCatalog(_ data: Data) throws -> DeviceRuleCatalog {
        struct CatalogHeader: Decodable {
            let schemaVersion: Int
        }

        let decoder = JSONDecoder()
        let header = try decoder.decode(CatalogHeader.self, from: data)
        guard header.schemaVersion == supportedSchemaVersion else {
            if header.schemaVersion == 1,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rules = object["rules"] as? [Any],
               rules.isEmpty {
                return DeviceRuleCatalog(
                    schemaVersion: supportedSchemaVersion,
                    catalogMode: nil,
                    systemAccessoryRules: nil,
                    rules: []
                )
            }
            throw DeviceRuleStoreError.unsupportedSchema(header.schemaVersion)
        }

        let catalog = try decoder.decode(DeviceRuleCatalog.self, from: data)

        var ids = Set<String>()
        for rule in catalog.rules where !ids.insert(rule.id).inserted {
            throw DeviceRuleStoreError.duplicateRuleID(rule.id)
        }
        return catalog
    }

    private func validationProblem(for rule: BatteryDeviceRule) -> String? {
        if rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "A rule has an empty id."
        }
        if rule.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Rule \(rule.id) has an empty displayName."
        }
        if rule.match.deviceIDs.isEmpty && rule.match.vendorIDs.isEmpty {
            return "Rule \(rule.id) must contain at least one device ID or vendor ID."
        }
        if rule.pollingIntervalSeconds < 10 {
            return "Rule \(rule.id) must poll no more frequently than every 10 seconds."
        }
        if rule.match.minimumInputReportLength < 0
            || rule.match.minimumOutputReportLength < 0 {
            return "Rule \(rule.id) has a negative report length."
        }
        let exactDeviceValues = rule.match.deviceIDs.flatMap {
            [$0.vendorID, $0.productID]
        }
        let usbValues = exactDeviceValues
            + rule.match.vendorIDs
            + rule.match.productIDs
            + [rule.match.usagePage]
        if usbValues.contains(where: { $0.value > 0xFFFF }) {
            return "Rule \(rule.id) contains a value larger than 0xFFFF."
        }
        if let usage = rule.match.usage, usage.value > 0xFFFF {
            return "Rule \(rule.id) contains a usage larger than 0xFFFF."
        }
        if let problem = rule.protocolDefinition.validationProblem {
            return "Rule \(rule.id) has an invalid protocol: \(problem)"
        }
        return nil
    }
}

enum DeviceRuleStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case duplicateRuleID(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "Unsupported device-rule schema version \(version)."
        case .duplicateRuleID(let id):
            "Duplicate device-rule id: \(id)."
        }
    }
}
