import Foundation
import Observation
import os

@MainActor
@Observable
final class BatteryHistoryStore {
    private(set) var devices: [BatteryHistoryDevice]

    @ObservationIgnored
    private let fileURL: URL

    @ObservationIgnored
    private let fileManager: FileManager

    private static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private static let unchangedSampleInterval: TimeInterval = 6 * 60 * 60
    private static let maximumSamplesPerSeries = 10_000

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        referenceDate: Date = Date()
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        devices = Self.load(
            from: self.fileURL,
            fileManager: fileManager,
            referenceDate: referenceDate
        )
    }

    func record(
        deviceID: String,
        name: String,
        symbolName: String,
        reading: BatteryReading,
        at timestamp: Date
    ) {
        record(
            observations: [
                HistoryObservation(
                    deviceID: deviceID,
                    name: name,
                    symbolName: symbolName,
                    components: [
                        BatteryComponentReading(
                            kind: .main,
                            level: reading.level
                        ),
                    ],
                    isCharging: reading.isCharging
                ),
            ],
            at: timestamp
        )
    }

    func record(
        bluetoothDevices: [BluetoothBatteryDevice],
        at timestamp: Date
    ) {
        let observations = bluetoothDevices.map { device in
            HistoryObservation(
                deviceID: "bluetooth:\(device.id)",
                name: device.name,
                symbolName: device.symbolName,
                components: device.components,
                isCharging: nil
            )
        }
        record(observations: observations, at: timestamp)
    }

    func presentation(
        for deviceID: String,
        range: BatteryHistoryRange,
        now: Date = Date()
    ) -> BatteryHistoryPresentation {
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            return .empty
        }

        let startDate = now.addingTimeInterval(-range.duration)
        let hasMultipleSeries = device.series.count > 1
        var points: [BatteryHistoryChartPoint] = []

        for series in device.series {
            let seriesName = hasMultipleSeries
                ? String(localized: series.component.displayName)
                : String(
                    localized: "Battery",
                    comment: "Name of the only series in a battery history chart."
                )
            let precedingSample = series.samples.last { $0.timestamp < startDate }
            if let precedingSample {
                points.append(
                    BatteryHistoryChartPoint(
                        id: "boundary:\(device.id):\(series.component.rawValue):\(startDate.timeIntervalSinceReferenceDate)",
                        timestamp: startDate,
                        level: precedingSample.level,
                        seriesName: seriesName,
                        component: series.component
                    )
                )
            }

            points.append(contentsOf: series.samples
                .filter { $0.timestamp >= startDate && $0.timestamp <= now }
                .map { sample in
                    BatteryHistoryChartPoint(
                        id: sample.id.uuidString,
                        timestamp: sample.timestamp,
                        level: sample.level,
                        seriesName: seriesName,
                        component: series.component
                    )
                })
        }

        points.sort {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return componentOrder($0.component) < componentOrder($1.component)
        }

        guard !points.isEmpty else { return .empty }

        let levels = points.map(\.level)
        let latestBySeries = Dictionary(grouping: points, by: \.component)
            .compactMap { $0.value.last?.level }
        let earliestBySeries = Dictionary(grouping: points, by: \.component)
            .compactMap { $0.value.first?.level }
        let latestLevel = latestBySeries.min()
        let earliestLevel = earliestBySeries.min()
        let change: Int?
        if let latestLevel, let earliestLevel {
            change = latestLevel - earliestLevel
        } else {
            change = nil
        }

        return BatteryHistoryPresentation(
            points: points,
            latestLevel: latestLevel,
            change: change,
            minimumLevel: levels.min(),
            maximumLevel: levels.max()
        )
    }

    func clear() {
        guard !devices.isEmpty
                || fileManager.fileExists(atPath: fileURL.path) else { return }
        devices = []

        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            AppLog.battery.error(
                "清除电量历史失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func record(
        observations: [HistoryObservation],
        at timestamp: Date
    ) {
        guard !observations.isEmpty else { return }

        var updatedDevices = devices
        var didChange = false

        for observation in observations {
            guard !observation.deviceID.isEmpty,
                  !observation.components.isEmpty else { continue }

            let existingIndex = updatedDevices.firstIndex {
                $0.id == observation.deviceID
            }
            var device = existingIndex.map { updatedDevices[$0] }
                ?? BatteryHistoryDevice(
                    id: observation.deviceID,
                    name: observation.name,
                    symbolName: observation.symbolName,
                    lastRecordedAt: timestamp,
                    series: []
                )
            var deviceChanged = existingIndex == nil

            if device.name != observation.name {
                device.name = observation.name
                deviceChanged = true
            }
            if device.symbolName != observation.symbolName {
                device.symbolName = observation.symbolName
                deviceChanged = true
            }

            for component in observation.components
                where (0...100).contains(component.level) {
                let seriesIndex = device.series.firstIndex {
                    $0.component == component.kind
                }
                var series = seriesIndex.map { device.series[$0] }
                    ?? BatteryHistorySeries(
                        component: component.kind,
                        samples: []
                    )

                guard shouldAppend(
                    level: component.level,
                    isCharging: observation.isCharging,
                    timestamp: timestamp,
                    after: series.samples.last
                ) else { continue }

                series.samples.append(
                    BatteryHistorySample(
                        timestamp: timestamp,
                        level: component.level,
                        isCharging: observation.isCharging
                    )
                )
                if series.samples.count > Self.maximumSamplesPerSeries {
                    series.samples.removeFirst(
                        series.samples.count - Self.maximumSamplesPerSeries
                    )
                }

                if let seriesIndex {
                    device.series[seriesIndex] = series
                } else {
                    device.series.append(series)
                }
                deviceChanged = true
            }

            guard deviceChanged else { continue }

            device.lastRecordedAt = timestamp
            device.series.sort {
                componentOrder($0.component) < componentOrder($1.component)
            }
            if let existingIndex {
                updatedDevices[existingIndex] = device
            } else {
                updatedDevices.append(device)
            }
            didChange = true
        }

        guard didChange else { return }

        devices = Self.pruned(
            updatedDevices,
            referenceDate: timestamp
        ).sorted {
            if $0.lastRecordedAt != $1.lastRecordedAt {
                return $0.lastRecordedAt > $1.lastRecordedAt
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist()
    }

    private func shouldAppend(
        level: Int,
        isCharging: Bool?,
        timestamp: Date,
        after previous: BatteryHistorySample?
    ) -> Bool {
        guard let previous else { return true }
        guard timestamp > previous.timestamp else { return false }

        return previous.level != level
            || previous.isCharging != isCharging
            || timestamp.timeIntervalSince(previous.timestamp)
                >= Self.unchangedSampleInterval
    }

    private func persist() {
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let archive = Archive(schemaVersion: 1, devices: devices)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.battery.error(
                "保存电量历史失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func load(
        from fileURL: URL,
        fileManager: FileManager,
        referenceDate: Date
    ) -> [BatteryHistoryDevice] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == 1 else {
                throw HistoryError.unsupportedSchema(archive.schemaVersion)
            }
            return pruned(archive.devices, referenceDate: referenceDate)
        } catch {
            AppLog.battery.error(
                "读取电量历史失败：\(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private static func pruned(
        _ devices: [BatteryHistoryDevice],
        referenceDate: Date
    ) -> [BatteryHistoryDevice] {
        let cutoff = referenceDate.addingTimeInterval(-retentionInterval)
        return devices.compactMap { device in
            var updatedDevice = device
            updatedDevice.series = device.series.compactMap { series in
                var updatedSeries = series
                updatedSeries.samples = series.samples.filter {
                    $0.timestamp >= cutoff
                }
                return updatedSeries.samples.isEmpty ? nil : updatedSeries
            }
            return updatedDevice.series.isEmpty ? nil : updatedDevice
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseURL
            .appendingPathComponent("WhatBattery", isDirectory: true)
            .appendingPathComponent("battery-history.json", isDirectory: false)
    }

    private func componentOrder(_ component: BatteryComponentKind) -> Int {
        Self.componentOrder(component)
    }

    private static func componentOrder(_ component: BatteryComponentKind) -> Int {
        switch component {
        case .main: 0
        case .left: 1
        case .right: 2
        case .case: 3
        }
    }
}

private extension BatteryHistoryStore {
    struct HistoryObservation {
        let deviceID: String
        let name: String
        let symbolName: String
        let components: [BatteryComponentReading]
        let isCharging: Bool?
    }

    struct Archive: Codable {
        let schemaVersion: Int
        let devices: [BatteryHistoryDevice]
    }

    enum HistoryError: LocalizedError {
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                "Unsupported battery-history schema version \(version)."
            }
        }
    }
}
