import Foundation

/// A JSON integer that accepts either decimal numbers or hexadecimal strings.
/// Rules are encoded as hexadecimal strings because USB identifiers are normally
/// documented in that form.
struct HIDNumber: Codable, Hashable, Sendable {
    let value: Int

    init(_ value: Int) {
        precondition(value >= 0, "HID values cannot be negative")
        self.value = value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let number = try? container.decode(Int.self), number >= 0 {
            value = number
            return
        }

        let text = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let radix: Int
        let digits: Substring

        if text.lowercased().hasPrefix("0x") {
            radix = 16
            digits = text.dropFirst(2)
        } else {
            radix = 10
            digits = Substring(text)
        }

        guard !digits.isEmpty, let number = Int(digits, radix: radix), number >= 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a non-negative decimal value or 0x-prefixed hexadecimal value."
            )
        }
        value = number
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "0x%04X", value))
    }
}
