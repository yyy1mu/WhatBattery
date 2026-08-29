import Foundation

enum ConfiguredHIDError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case missingVariable(String)
    case transportBusy
    case transportClosed
    case timeout
    case protocolError(UInt8)
    case malformedResponse
    case invalidBatteryLevel(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            String(
                localized: "Invalid HID protocol configuration: \(message)",
                comment: "Error when a JSON HID protocol rule is invalid."
            )
        case .missingVariable(let name):
            String(
                localized: "The HID protocol variable \(name) has no value.",
                comment: "Error when a configured HID request references an unavailable variable."
            )
        case .transportBusy:
            String(
                localized: "Another HID request is already waiting for a response.",
                comment: "Error when concurrent configured HID requests are attempted."
            )
        case .transportClosed:
            String(
                localized: "The HID device was disconnected.",
                comment: "Error when a configured HID device disconnects during a request."
            )
        case .timeout:
            String(
                localized: "The HID device did not respond.",
                comment: "Error when a configured HID battery request times out."
            )
        case .protocolError(let code):
            String(
                localized: "The HID device returned protocol error 0x\(String(code, radix: 16)).",
                comment: "Configured HID protocol error containing a hexadecimal code."
            )
        case .malformedResponse:
            String(
                localized: "The HID response is malformed.",
                comment: "Error when a configured HID response is too short or invalid."
            )
        case .invalidBatteryLevel(let value):
            String(
                localized: "The HID device returned an invalid battery level: \(value).",
                comment: "Error when a configured HID device reports a percentage above 100."
            )
        }
    }
}

enum HIDReportResponseKind: Equatable {
    case unrelated
    case response
    case error(UInt8)
}

struct ConfiguredHIDRequest: Equatable {
    let bytes: [UInt8]
    let checksum: HIDChecksumRule?
    let responseEchoes: [HIDResponseEcho]
    let errorResponse: HIDErrorResponseRule?

    func responseKind(for response: [UInt8]) -> HIDReportResponseKind {
        guard response.count == bytes.count,
              Self.hasValidChecksum(response, rule: checksum) else {
            return .unrelated
        }

        if let errorResponse,
           Self.matchesError(response, request: bytes, rule: errorResponse) {
            return .error(response[errorResponse.codeOffset])
        }

        guard Self.matchesEchoes(
            response,
            request: bytes,
            echoes: responseEchoes
        ) else {
            return .unrelated
        }
        return .response
    }

    static func applyingChecksum(
        to bytes: [UInt8],
        rule: HIDChecksumRule?
    ) throws -> [UInt8] {
        guard let rule else { return bytes }
        guard bytes.indices.contains(rule.offset),
              let target = UInt8(exactly: rule.target.value) else {
            throw ConfiguredHIDError.invalidConfiguration(
                "The checksum offset or target is outside the report."
            )
        }

        var result = bytes
        result[rule.offset] = 0
        let sum = result.reduce(0) { $0 + Int($1) }
        result[rule.offset] = UInt8(truncatingIfNeeded: Int(target) - sum)
        return result
    }

    static func hasValidChecksum(
        _ bytes: [UInt8],
        rule: HIDChecksumRule?
    ) -> Bool {
        guard let rule else { return true }
        guard bytes.indices.contains(rule.offset),
              let target = UInt8(exactly: rule.target.value) else {
            return false
        }
        return UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 + Int($1) })
            == target
    }

    private static func matchesError(
        _ response: [UInt8],
        request: [UInt8],
        rule: HIDErrorResponseRule
    ) -> Bool {
        guard response.indices.contains(rule.markerOffset),
              response.indices.contains(rule.codeOffset),
              rule.markers.contains(where: {
                  $0.value == response[rule.markerOffset]
              }) else {
            return false
        }
        return matchesEchoes(response, request: request, echoes: rule.echoes)
    }

    private static func matchesEchoes(
        _ response: [UInt8],
        request: [UInt8],
        echoes: [HIDResponseEcho]
    ) -> Bool {
        echoes.allSatisfy { echo in
            guard echo.length > 0,
                  echo.responseOffset >= 0,
                  echo.requestOffset >= 0,
                  echo.responseOffset + echo.length <= response.count,
                  echo.requestOffset + echo.length <= request.count else {
                return false
            }
            return response[
                echo.responseOffset..<(echo.responseOffset + echo.length)
            ].elementsEqual(
                request[echo.requestOffset..<(echo.requestOffset + echo.length)]
            )
        }
    }
}

@MainActor
protocol ConfiguredHIDRequesting: AnyObject {
    func request(_ request: ConfiguredHIDRequest) async throws -> [UInt8]
}

@MainActor
final class ConfiguredHIDProtocolExecutor {
    private let definition: HIDProtocolDefinition
    private let transport: any ConfiguredHIDRequesting
    private var variables: [String: UInt8]
    private var completedRunOnceSteps = Set<String>()

    init(
        definition: HIDProtocolDefinition,
        transport: any ConfiguredHIDRequesting
    ) throws {
        if let problem = definition.validationProblem {
            throw ConfiguredHIDError.invalidConfiguration(problem)
        }
        self.definition = definition
        self.transport = transport
        variables = try definition.variables.mapValues { number in
            guard let value = UInt8(exactly: number.value) else {
                throw ConfiguredHIDError.invalidConfiguration(
                    "A protocol variable is larger than one byte."
                )
            }
            return value
        }
    }

    func readBattery() async throws -> BatteryReading {
        var finalResponse: [UInt8]?

        for step in definition.steps {
            if step.runOnce, completedRunOnceSteps.contains(step.id) {
                continue
            }

            let bytes = try requestBytes(for: step)
            let request = ConfiguredHIDRequest(
                bytes: bytes,
                checksum: definition.checksum,
                responseEchoes: definition.responseEchoes,
                errorResponse: definition.errorResponse
            )
            let response = try await transport.request(request)
            try validate(response, requirements: step.requirements)

            for capture in step.captures {
                guard response.indices.contains(capture.offset) else {
                    throw ConfiguredHIDError.malformedResponse
                }
                variables[capture.name] = response[capture.offset]
            }

            if step.runOnce {
                completedRunOnceSteps.insert(step.id)
            }
            finalResponse = response
        }

        guard let finalResponse else {
            throw ConfiguredHIDError.malformedResponse
        }
        return try extractBattery(from: finalResponse)
    }

    private func requestBytes(for step: HIDCommandStep) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: definition.reportLength)
        for (offset, template) in step.request.enumerated() {
            switch template {
            case .literal(let number):
                guard let byte = UInt8(exactly: number.value) else {
                    throw ConfiguredHIDError.invalidConfiguration(
                        "Step \(step.id) contains a value larger than one byte."
                    )
                }
                bytes[offset] = byte
            case .variable(let name):
                guard let byte = variables[name] else {
                    throw ConfiguredHIDError.missingVariable(name)
                }
                bytes[offset] = byte
            }
        }
        return try ConfiguredHIDRequest.applyingChecksum(
            to: bytes,
            rule: definition.checksum
        )
    }

    private func validate(
        _ response: [UInt8],
        requirements: [HIDResponseRequirement]
    ) throws {
        for requirement in requirements {
            guard response.indices.contains(requirement.offset),
                  let expected = UInt8(exactly: requirement.value.value) else {
                throw ConfiguredHIDError.malformedResponse
            }

            let isEqual = response[requirement.offset] == expected
            let passed = switch requirement.comparison {
            case .equals: isEqual
            case .notEquals: !isEqual
            }
            if !passed {
                throw requirement.failure.sessionError
            }
        }
    }

    private func extractBattery(from response: [UInt8]) throws -> BatteryReading {
        let battery = definition.battery
        guard response.indices.contains(battery.levelOffset) else {
            throw ConfiguredHIDError.malformedResponse
        }
        let level = Int(response[battery.levelOffset])
        guard (0...100).contains(level) else {
            throw ConfiguredHIDError.invalidBatteryLevel(level)
        }

        let isCharging: Bool?
        if let offset = battery.chargingOffset {
            guard response.indices.contains(offset) else {
                throw ConfiguredHIDError.malformedResponse
            }
            isCharging = response[offset] != 0
        } else {
            isCharging = nil
        }

        let voltageMillivolts: Int?
        switch (battery.voltageHighOffset, battery.voltageLowOffset) {
        case (.some(let high), .some(let low)):
            guard response.indices.contains(high), response.indices.contains(low) else {
                throw ConfiguredHIDError.malformedResponse
            }
            voltageMillivolts = (Int(response[high]) << 8) | Int(response[low])
        case (.none, .none):
            voltageMillivolts = nil
        default:
            throw ConfiguredHIDError.invalidConfiguration(
                "Both voltage byte offsets must be supplied together."
            )
        }

        return BatteryReading(
            level: level,
            isCharging: isCharging,
            voltageMillivolts: voltageMillivolts
        )
    }
}

extension HIDProtocolDefinition {
    var validationProblem: String? {
        guard let reportByte = UInt8(exactly: reportID.value) else {
            return "reportID must fit in one byte."
        }
        guard reportLength > 0 else { return "reportLength must be positive." }
        guard requestTimeoutMilliseconds > 0 else {
            return "requestTimeoutMilliseconds must be positive."
        }
        guard maximumAttempts > 0 else { return "maximumAttempts must be positive." }
        guard !steps.isEmpty else { return "At least one command step is required." }
        guard steps.last?.runOnce == false else {
            return "The final battery-reading step cannot be runOnce."
        }

        if let checksum {
            guard (0..<reportLength).contains(checksum.offset),
                  UInt8(exactly: checksum.target.value) != nil else {
                return "The checksum offset or target is invalid."
            }
        }

        var stepIDs = Set<String>()
        var availableVariables = Set(variables.keys)
        for (name, value) in variables {
            guard !name.isEmpty, UInt8(exactly: value.value) != nil else {
                return "Variable \(name) must contain one byte."
            }
        }

        for step in steps {
            guard !step.id.isEmpty, stepIDs.insert(step.id).inserted else {
                return "Command step identifiers must be non-empty and unique."
            }
            guard !step.request.isEmpty, step.request.count <= reportLength else {
                return "Step \(step.id) has an invalid request length."
            }
            for template in step.request {
                if case .literal(let value) = template,
                   UInt8(exactly: value.value) == nil {
                    return "Step \(step.id) contains a value larger than one byte."
                }
                if let name = template.variableName,
                   !availableVariables.contains(name) {
                    return "Step \(step.id) references unknown variable \(name)."
                }
            }
            guard case .literal(let first) = step.request[0],
                  first.value == Int(reportByte) else {
                return "Step \(step.id) must start with the configured reportID."
            }
            for requirement in step.requirements {
                guard (0..<reportLength).contains(requirement.offset),
                      UInt8(exactly: requirement.value.value) != nil else {
                    return "Step \(step.id) contains an invalid response requirement."
                }
            }
            for capture in step.captures {
                guard !capture.name.isEmpty,
                      (0..<reportLength).contains(capture.offset) else {
                    return "Step \(step.id) contains an invalid response capture."
                }
                availableVariables.insert(capture.name)
            }
        }

        let allEchoes = responseEchoes + (errorResponse?.echoes ?? [])
        guard allEchoes.allSatisfy({ echo in
            echo.length > 0
                && echo.responseOffset >= 0
                && echo.requestOffset >= 0
                && echo.responseOffset + echo.length <= reportLength
                && echo.requestOffset + echo.length <= reportLength
        }) else {
            return "A response echo range is outside the report."
        }

        if let errorResponse {
            guard (0..<reportLength).contains(errorResponse.markerOffset),
                  (0..<reportLength).contains(errorResponse.codeOffset),
                  !errorResponse.markers.isEmpty,
                  (errorResponse.markers + errorResponse.retryableCodes).allSatisfy({
                      UInt8(exactly: $0.value) != nil
                  }) else {
                return "The error-response definition is invalid."
            }
        }

        let offsets = [
            battery.levelOffset,
            battery.chargingOffset,
            battery.voltageHighOffset,
            battery.voltageLowOffset,
        ].compactMap { $0 }
        guard offsets.allSatisfy({ (0..<reportLength).contains($0) }) else {
            return "A battery response offset is outside the report."
        }
        guard (battery.voltageHighOffset == nil) == (battery.voltageLowOffset == nil) else {
            return "Both voltage byte offsets must be supplied together."
        }
        return nil
    }
}
