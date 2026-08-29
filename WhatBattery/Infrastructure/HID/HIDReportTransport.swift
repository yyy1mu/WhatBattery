import Foundation
import IOKit.hid
import os

@MainActor
final class HIDReportTransport: ConfiguredHIDRequesting {
    let device: IOHIDDevice
    let deviceInfo: HIDDeviceDescriptor

    private let definition: HIDProtocolDefinition
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize: Int
    private var pendingRequest: PendingRequest?
    private var isOpen = false

    private struct PendingRequest {
        let id: UUID
        let request: ConfiguredHIDRequest
        let continuation: CheckedContinuation<[UInt8], Error>
        let timeoutTask: Task<Void, Never>
    }

    init(
        device: IOHIDDevice,
        definition: HIDProtocolDefinition,
        fallbackProductName: String
    ) throws {
        self.device = device
        self.definition = definition
        deviceInfo = HIDDeviceDescriptor(
            device: device,
            fallbackProductName: fallbackProductName
        )
        inputBufferSize = max(
            Self.integerProperty(kIOHIDMaxInputReportSizeKey, from: device) ?? 64,
            definition.reportLength
        )
        inputBuffer = .allocate(capacity: inputBufferSize)
        inputBuffer.initialize(repeating: 0, count: inputBufferSize)

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            inputBuffer.deinitialize(count: inputBufferSize)
            inputBuffer.deallocate()
            throw HIDDeviceError.deviceOpenFailed(result)
        }

        isOpen = true
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            inputBufferSize,
            Self.inputReportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    isolated deinit {
        pendingRequest?.timeoutTask.cancel()
        pendingRequest?.continuation.resume(
            throwing: ConfiguredHIDError.transportClosed
        )
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            inputBufferSize,
            nil,
            nil
        )
        if isOpen {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        inputBuffer.deinitialize(count: inputBufferSize)
        inputBuffer.deallocate()
    }

    func request(_ request: ConfiguredHIDRequest) async throws -> [UInt8] {
        for attempt in 1...definition.maximumAttempts {
            try Task.checkCancellation()
            do {
                return try await requestOnce(request)
            } catch ConfiguredHIDError.timeout
                where definition.retryOnTimeout
                    && attempt < definition.maximumAttempts {
                AppLog.hid.debug("HID 请求第 \(attempt) 次超时，准备重试")
            } catch ConfiguredHIDError.protocolError(let code)
                where isRetryable(code) && attempt < definition.maximumAttempts {
                AppLog.hid.debug(
                    "HID 请求收到可重试错误 0x\(String(code, radix: 16), privacy: .public)"
                )
                try await Task.sleep(for: .milliseconds(150))
            } catch ConfiguredHIDError.protocolError(let code)
                where isRetryable(code) {
                throw ConfiguredHIDError.timeout
            }
        }
        throw ConfiguredHIDError.timeout
    }

    func represents(_ otherDevice: IOHIDDevice) -> Bool {
        CFEqual(device, otherDevice)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        finishPendingRequest(with: .failure(ConfiguredHIDError.transportClosed))
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputBuffer,
            inputBufferSize,
            nil,
            nil
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    static func normalizedInputReport(
        reportID: UInt32,
        bytes: [UInt8],
        expectedReportID: UInt8,
        expectedLength: Int
    ) -> [UInt8]? {
        if bytes.count == expectedLength, bytes.first == expectedReportID {
            return bytes
        }
        if bytes.count == expectedLength - 1,
           reportID == expectedReportID || reportID == 0 {
            return [expectedReportID] + bytes
        }
        return nil
    }

    private func requestOnce(_ request: ConfiguredHIDRequest) async throws -> [UInt8] {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard isOpen else {
                    continuation.resume(throwing: ConfiguredHIDError.transportClosed)
                    return
                }
                guard pendingRequest == nil else {
                    continuation.resume(throwing: ConfiguredHIDError.transportBusy)
                    return
                }

                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(
                            for: .milliseconds(
                                self?.definition.requestTimeoutMilliseconds ?? 2_000
                            )
                        )
                    } catch {
                        return
                    }
                    self?.timeoutRequest(id: requestID)
                }
                pendingRequest = PendingRequest(
                    id: requestID,
                    request: request,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                AppLog.hid.debug("HID TX: \(Self.hex(request.bytes), privacy: .public)")
                let result = request.bytes.withUnsafeBufferPointer { buffer in
                    IOHIDDeviceSetReport(
                        device,
                        kIOHIDReportTypeOutput,
                        CFIndex(definition.reportID.value),
                        buffer.baseAddress!,
                        buffer.count
                    )
                }
                guard result == kIOReturnSuccess else {
                    finishPendingRequest(
                        with: .failure(HIDDeviceError.reportSendFailed(result))
                    )
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id: requestID)
            }
        }
    }

    private func receive(
        result: IOReturn,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>?,
        reportLength: CFIndex
    ) {
        guard result == kIOReturnSuccess,
              let report,
              reportLength > 0,
              let pendingRequest,
              let expectedReportID = UInt8(exactly: definition.reportID.value) else {
            return
        }

        let rawBytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
        guard let bytes = Self.normalizedInputReport(
            reportID: reportID,
            bytes: rawBytes,
            expectedReportID: expectedReportID,
            expectedLength: definition.reportLength
        ) else { return }

        AppLog.hid.debug("HID RX: \(Self.hex(bytes), privacy: .public)")
        switch pendingRequest.request.responseKind(for: bytes) {
        case .unrelated:
            return
        case .response:
            finishPendingRequest(with: .success(bytes))
        case .error(let code):
            finishPendingRequest(
                with: .failure(ConfiguredHIDError.protocolError(code))
            )
        }
    }

    private func isRetryable(_ code: UInt8) -> Bool {
        definition.errorResponse?.retryableCodes.contains(where: {
            $0.value == code
        }) == true
    }

    private func cancelRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        finishPendingRequest(with: .failure(CancellationError()))
    }

    private func timeoutRequest(id: UUID) {
        guard pendingRequest?.id == id else { return }
        finishPendingRequest(with: .failure(ConfiguredHIDError.timeout))
    }

    private func finishPendingRequest(with result: Result<[UInt8], Error>) {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private static let inputReportCallback: IOHIDReportCallback = {
        context,
        result,
        _,
        _,
        reportID,
        report,
        reportLength in
        guard let context else { return }
        let transport = Unmanaged<HIDReportTransport>
            .fromOpaque(context)
            .takeUnretainedValue()

        MainActor.assumeIsolated {
            transport.receive(
                result: result,
                reportID: reportID,
                report: report,
                reportLength: reportLength
            )
        }
    }

    private nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func integerProperty(_ key: String, from device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}
