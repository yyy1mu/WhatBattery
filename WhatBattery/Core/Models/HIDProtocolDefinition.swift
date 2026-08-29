import Foundation

/// One byte in a configured request. JSON accepts a byte literal (`"0x11"` or
/// `17`) or a variable reference such as `"$featureIndex"`.
enum HIDByteTemplate: Codable, Equatable, Sendable {
    case literal(HIDNumber)
    case variable(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            guard (0...0xFF).contains(number) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "A HID request byte must be between 0 and 255."
                )
            }
            self = .literal(HIDNumber(number))
            return
        }

        let text = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$") {
            let name = String(text.dropFirst())
            guard !name.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "A HID variable reference must include a name."
                )
            }
            self = .variable(name)
            return
        }

        let radix = text.lowercased().hasPrefix("0x") ? 16 : 10
        let digits = radix == 16 ? text.dropFirst(2) : Substring(text)
        guard let number = Int(digits, radix: radix), (0...0xFF).contains(number) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a byte, a hexadecimal byte, or a $variable reference."
            )
        }
        self = .literal(HIDNumber(number))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .literal(let number):
            try container.encode(String(format: "0x%02X", number.value))
        case .variable(let name):
            try container.encode("$\(name)")
        }
    }

    var variableName: String? {
        guard case .variable(let name) = self else { return nil }
        return name
    }
}

struct HIDResponseEcho: Codable, Equatable, Sendable {
    let responseOffset: Int
    let requestOffset: Int
    let length: Int
}

struct HIDChecksumRule: Codable, Equatable, Sendable {
    let offset: Int
    let target: HIDNumber
}

struct HIDErrorResponseRule: Codable, Equatable, Sendable {
    let markerOffset: Int
    let markers: [HIDNumber]
    let echoes: [HIDResponseEcho]
    let codeOffset: Int
    let retryableCodes: [HIDNumber]
}

enum HIDResponseComparison: String, Codable, Sendable {
    case equals
    case notEquals
}

enum HIDResponseFailure: String, Codable, Sendable {
    case peripheralOffline
    case unsupported

    var sessionError: BatterySessionError {
        switch self {
        case .peripheralOffline:
            .peripheralOffline
        case .unsupported:
            .unsupported
        }
    }
}

struct HIDResponseRequirement: Codable, Equatable, Sendable {
    let offset: Int
    let comparison: HIDResponseComparison
    let value: HIDNumber
    let failure: HIDResponseFailure
}

struct HIDResponseCapture: Codable, Equatable, Sendable {
    let name: String
    let offset: Int
}

struct HIDCommandStep: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let request: [HIDByteTemplate]
    let requirements: [HIDResponseRequirement]
    let captures: [HIDResponseCapture]
    let runOnce: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case request
        case requirements
        case captures
        case runOnce
    }

    init(
        id: String,
        request: [HIDByteTemplate],
        requirements: [HIDResponseRequirement] = [],
        captures: [HIDResponseCapture] = [],
        runOnce: Bool = false
    ) {
        self.id = id
        self.request = request
        self.requirements = requirements
        self.captures = captures
        self.runOnce = runOnce
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        request = try container.decode([HIDByteTemplate].self, forKey: .request)
        requirements = try container.decodeIfPresent(
            [HIDResponseRequirement].self,
            forKey: .requirements
        ) ?? []
        captures = try container.decodeIfPresent(
            [HIDResponseCapture].self,
            forKey: .captures
        ) ?? []
        runOnce = try container.decodeIfPresent(Bool.self, forKey: .runOnce) ?? false
    }
}

struct HIDBatteryExtractionRule: Codable, Equatable, Sendable {
    let levelOffset: Int
    let chargingOffset: Int?
    let voltageHighOffset: Int?
    let voltageLowOffset: Int?
}

/// A complete request/response protocol described by JSON. The Swift runtime
/// has no product-specific knowledge; it only executes these generic rules.
struct HIDProtocolDefinition: Codable, Equatable, Sendable {
    let reportID: HIDNumber
    let reportLength: Int
    let requestTimeoutMilliseconds: Int
    let maximumAttempts: Int
    let retryOnTimeout: Bool
    let checksum: HIDChecksumRule?
    let responseEchoes: [HIDResponseEcho]
    let errorResponse: HIDErrorResponseRule?
    let variables: [String: HIDNumber]
    let steps: [HIDCommandStep]
    let battery: HIDBatteryExtractionRule

    private enum CodingKeys: String, CodingKey {
        case reportID
        case reportLength
        case requestTimeoutMilliseconds
        case maximumAttempts
        case retryOnTimeout
        case checksum
        case responseEchoes
        case errorResponse
        case variables
        case steps
        case battery
    }

    init(
        reportID: HIDNumber,
        reportLength: Int,
        requestTimeoutMilliseconds: Int = 2_000,
        maximumAttempts: Int = 1,
        retryOnTimeout: Bool = false,
        checksum: HIDChecksumRule? = nil,
        responseEchoes: [HIDResponseEcho],
        errorResponse: HIDErrorResponseRule? = nil,
        variables: [String: HIDNumber] = [:],
        steps: [HIDCommandStep],
        battery: HIDBatteryExtractionRule
    ) {
        self.reportID = reportID
        self.reportLength = reportLength
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.maximumAttempts = maximumAttempts
        self.retryOnTimeout = retryOnTimeout
        self.checksum = checksum
        self.responseEchoes = responseEchoes
        self.errorResponse = errorResponse
        self.variables = variables
        self.steps = steps
        self.battery = battery
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reportID = try container.decode(HIDNumber.self, forKey: .reportID)
        reportLength = try container.decode(Int.self, forKey: .reportLength)
        requestTimeoutMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .requestTimeoutMilliseconds
        ) ?? 2_000
        maximumAttempts = try container.decodeIfPresent(
            Int.self,
            forKey: .maximumAttempts
        ) ?? 1
        retryOnTimeout = try container.decodeIfPresent(
            Bool.self,
            forKey: .retryOnTimeout
        ) ?? false
        checksum = try container.decodeIfPresent(
            HIDChecksumRule.self,
            forKey: .checksum
        )
        responseEchoes = try container.decodeIfPresent(
            [HIDResponseEcho].self,
            forKey: .responseEchoes
        ) ?? []
        errorResponse = try container.decodeIfPresent(
            HIDErrorResponseRule.self,
            forKey: .errorResponse
        )
        variables = try container.decodeIfPresent(
            [String: HIDNumber].self,
            forKey: .variables
        ) ?? [:]
        steps = try container.decode([HIDCommandStep].self, forKey: .steps)
        battery = try container.decode(HIDBatteryExtractionRule.self, forKey: .battery)
    }
}
