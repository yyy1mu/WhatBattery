import Testing
@testable import WhatBattery

@MainActor
struct ConfiguredHIDProtocolTests {
    @Test("A captured response byte can drive a later request and be cached")
    func capturesAndCachesProtocolVariables() async throws {
        let transport = ConfiguredTransportStub(responses: [
            .success([0x11, 0x01, 0x00, 0x01, 0x05, 0, 0, 0]),
            .success([0x11, 0x01, 0x05, 0x01, 90, 0, 0, 0]),
            .success([0x11, 0x01, 0x05, 0x01, 50, 0, 0, 0]),
        ])
        let executor = try ConfiguredHIDProtocolExecutor(
            definition: dynamicProtocol,
            transport: transport
        )

        let first = try await executor.readBattery()
        let second = try await executor.readBattery()

        #expect(first.level == 90)
        #expect(second.level == 50)
        #expect(transport.requests.count == 3)
        #expect(Array(transport.requests[0].bytes.prefix(6)) == [
            0x11, 0x01, 0x00, 0x01, 0x10, 0x00,
        ])
        #expect(Array(transport.requests[1].bytes.prefix(4)) == [
            0x11, 0x01, 0x05, 0x01,
        ])
        #expect(Array(transport.requests[2].bytes.prefix(4)) == [
            0x11, 0x01, 0x05, 0x01,
        ])
    }

    @Test("Configured requirements map an offline response to a generic state")
    func mapsConfiguredOfflineRequirement() async throws {
        let definition = HIDProtocolDefinition(
            reportID: HIDNumber(0x08),
            reportLength: 8,
            responseEchoes: [
                HIDResponseEcho(responseOffset: 0, requestOffset: 0, length: 2),
            ],
            steps: [
                HIDCommandStep(
                    id: "online",
                    request: [.literal(HIDNumber(0x08)), .literal(HIDNumber(0x03))],
                    requirements: [
                        HIDResponseRequirement(
                            offset: 6,
                            comparison: .equals,
                            value: HIDNumber(1),
                            failure: .peripheralOffline
                        ),
                    ]
                ),
            ],
            battery: HIDBatteryExtractionRule(
                levelOffset: 6,
                chargingOffset: nil,
                voltageHighOffset: nil,
                voltageLowOffset: nil
            )
        )
        let transport = ConfiguredTransportStub(responses: [
            .success([0x08, 0x03, 0, 0, 0, 0, 0, 0]),
        ])
        let executor = try ConfiguredHIDProtocolExecutor(
            definition: definition,
            transport: transport
        )

        await #expect(throws: BatterySessionError.peripheralOffline) {
            try await executor.readBattery()
        }
    }

    @Test("Checksum generation and response matching are data driven")
    func appliesChecksumAndMatchesResponse() throws {
        let checksum = HIDChecksumRule(offset: 16, target: HIDNumber(0x55))
        var bytes = [UInt8](repeating: 0, count: 17)
        bytes[0] = 0x08
        bytes[1] = 0x04
        bytes[5] = 0x80
        bytes = try ConfiguredHIDRequest.applyingChecksum(to: bytes, rule: checksum)

        let request = ConfiguredHIDRequest(
            bytes: bytes,
            checksum: checksum,
            responseEchoes: [
                HIDResponseEcho(responseOffset: 0, requestOffset: 0, length: 5),
            ],
            errorResponse: nil
        )
        var response = bytes
        response[6] = 75
        response = try ConfiguredHIDRequest.applyingChecksum(
            to: response,
            rule: checksum
        )

        #expect(ConfiguredHIDRequest.hasValidChecksum(response, rule: checksum))
        #expect(request.responseKind(for: response) == .response)
        response[16] &+= 1
        #expect(request.responseKind(for: response) == .unrelated)
    }

    @Test("Configured protocol error envelopes are recognized")
    func matchesConfiguredErrorEnvelope() {
        let errorRule = HIDErrorResponseRule(
            markerOffset: 2,
            markers: [HIDNumber(0xFF), HIDNumber(0x8F)],
            echoes: [
                HIDResponseEcho(responseOffset: 1, requestOffset: 1, length: 1),
                HIDResponseEcho(responseOffset: 3, requestOffset: 2, length: 2),
            ],
            codeOffset: 5,
            retryableCodes: [HIDNumber(0x08)]
        )
        let request = ConfiguredHIDRequest(
            bytes: [0x11, 0x01, 0x08, 0x01, 0, 0, 0, 0],
            checksum: nil,
            responseEchoes: [
                HIDResponseEcho(responseOffset: 1, requestOffset: 1, length: 3),
            ],
            errorResponse: errorRule
        )

        #expect(request.responseKind(for: [
            0x11, 0x01, 0xFF, 0x08, 0x01, 0x08, 0, 0,
        ]) == .error(0x08))
    }

    @Test("Input normalization accepts both macOS report callback forms")
    func normalizesInputReports() {
        let report = [UInt8](repeating: 0, count: 17)
            .enumerated()
            .map { index, value in index == 0 ? 0x08 : value }

        #expect(HIDReportTransport.normalizedInputReport(
            reportID: 0x08,
            bytes: Array(report.dropFirst()),
            expectedReportID: 0x08,
            expectedLength: 17
        ) == report)
        #expect(HIDReportTransport.normalizedInputReport(
            reportID: 0,
            bytes: report,
            expectedReportID: 0x08,
            expectedLength: 17
        ) == report)
    }

    private var dynamicProtocol: HIDProtocolDefinition {
        HIDProtocolDefinition(
            reportID: HIDNumber(0x11),
            reportLength: 8,
            responseEchoes: [
                HIDResponseEcho(responseOffset: 1, requestOffset: 1, length: 3),
            ],
            variables: ["deviceIndex": HIDNumber(1)],
            steps: [
                HIDCommandStep(
                    id: "resolve",
                    request: [
                        .literal(HIDNumber(0x11)),
                        .variable("deviceIndex"),
                        .literal(HIDNumber(0)),
                        .literal(HIDNumber(1)),
                        .literal(HIDNumber(0x10)),
                        .literal(HIDNumber(0)),
                    ],
                    requirements: [
                        HIDResponseRequirement(
                            offset: 4,
                            comparison: .notEquals,
                            value: HIDNumber(0),
                            failure: .unsupported
                        ),
                    ],
                    captures: [
                        HIDResponseCapture(name: "featureIndex", offset: 4),
                    ],
                    runOnce: true
                ),
                HIDCommandStep(
                    id: "battery",
                    request: [
                        .literal(HIDNumber(0x11)),
                        .variable("deviceIndex"),
                        .variable("featureIndex"),
                        .literal(HIDNumber(1)),
                    ]
                ),
            ],
            battery: HIDBatteryExtractionRule(
                levelOffset: 4,
                chargingOffset: nil,
                voltageHighOffset: nil,
                voltageLowOffset: nil
            )
        )
    }
}

@MainActor
private final class ConfiguredTransportStub: ConfiguredHIDRequesting {
    private(set) var requests: [ConfiguredHIDRequest] = []
    private var responses: [Result<[UInt8], Error>]

    init(responses: [Result<[UInt8], Error>]) {
        self.responses = responses
    }

    func request(_ request: ConfiguredHIDRequest) async throws -> [UInt8] {
        requests.append(request)
        guard !responses.isEmpty else { throw StubError.missingResponse }
        return try responses.removeFirst().get()
    }

    private enum StubError: Error {
        case missingResponse
    }
}
