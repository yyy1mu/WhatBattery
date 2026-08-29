import Foundation

struct BatteryHistorySample: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: Int
    let isCharging: Bool?

    init(
        id: UUID = UUID(),
        timestamp: Date,
        level: Int,
        isCharging: Bool?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.isCharging = isCharging
    }
}

struct BatteryHistorySeries: Codable, Equatable, Identifiable, Sendable {
    let component: BatteryComponentKind
    var samples: [BatteryHistorySample]

    var id: BatteryComponentKind { component }
}

struct BatteryHistoryDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var symbolName: String
    var lastRecordedAt: Date
    var series: [BatteryHistorySeries]

    var latestLevel: Int? {
        series.compactMap { $0.samples.last?.level }.min()
    }
}

struct BatteryHistoryChartPoint: Equatable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let level: Int
    let seriesName: String
    let component: BatteryComponentKind
}

struct BatteryHistoryPresentation: Equatable, Sendable {
    let points: [BatteryHistoryChartPoint]
    let latestLevel: Int?
    let change: Int?
    let minimumLevel: Int?
    let maximumLevel: Int?

    static let empty = BatteryHistoryPresentation(
        points: [],
        latestLevel: nil,
        change: nil,
        minimumLevel: nil,
        maximumLevel: nil
    )
}

enum BatteryHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: Self { self }

    var duration: TimeInterval {
        switch self {
        case .day:
            24 * 60 * 60
        case .week:
            7 * 24 * 60 * 60
        case .month:
            30 * 24 * 60 * 60
        }
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .day:
            "24 Hours"
        case .week:
            "7 Days"
        case .month:
            "30 Days"
        }
    }
}
