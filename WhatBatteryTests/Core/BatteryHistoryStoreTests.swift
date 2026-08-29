import Foundation
import Testing
@testable import WhatBattery

@MainActor
struct BatteryHistoryStoreTests {
    @Test("History stores changes, suppresses duplicate polling samples, and persists")
    func storesOnlyUsefulSamples() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let start = Date()
        let store = BatteryHistoryStore(
            fileURL: fixture.fileURL,
            referenceDate: start
        )

        store.record(
            deviceID: "hid:test",
            name: "Test Mouse",
            symbolName: "computermouse",
            reading: BatteryReading(level: 80),
            at: start
        )
        store.record(
            deviceID: "hid:test",
            name: "Test Mouse",
            symbolName: "computermouse",
            reading: BatteryReading(level: 80),
            at: start.addingTimeInterval(5 * 60)
        )
        store.record(
            deviceID: "hid:test",
            name: "Test Mouse",
            symbolName: "computermouse",
            reading: BatteryReading(level: 76),
            at: start.addingTimeInterval(10 * 60)
        )

        let samples = try #require(store.devices.first?.series.first?.samples)
        #expect(samples.map(\.level) == [80, 76])

        let presentation = store.presentation(
            for: "hid:test",
            range: .day,
            now: start.addingTimeInterval(10 * 60)
        )
        #expect(presentation.latestLevel == 76)
        #expect(presentation.change == -4)
        #expect(presentation.minimumLevel == 76)
        #expect(presentation.maximumLevel == 80)

        let reloaded = BatteryHistoryStore(
            fileURL: fixture.fileURL,
            referenceDate: start.addingTimeInterval(10 * 60)
        )
        #expect(reloaded.devices == store.devices)
    }

    @Test("Unchanged batteries receive a sparse heartbeat sample")
    func recordsHeartbeatSamples() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let start = Date()
        let store = BatteryHistoryStore(
            fileURL: fixture.fileURL,
            referenceDate: start
        )

        let offsets: [TimeInterval] = [0, 5 * 60, 6 * 60 * 60]
        for offset in offsets {
            store.record(
                deviceID: "hid:test",
                name: "Test Keyboard",
                symbolName: "keyboard",
                reading: BatteryReading(level: 100),
                at: start.addingTimeInterval(offset)
            )
        }

        #expect(store.devices.first?.series.first?.samples.count == 2)
    }

    @Test("Bluetooth component batteries become separate chart series")
    func recordsBluetoothComponents() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let timestamp = Date()
        let store = BatteryHistoryStore(
            fileURL: fixture.fileURL,
            referenceDate: timestamp
        )
        let earbuds = BluetoothBatteryDevice(
            id: "airpods",
            name: "Earbuds",
            kind: .earbuds,
            transport: .bluetooth,
            address: nil,
            components: [
                BatteryComponentReading(kind: .left, level: 71),
                BatteryComponentReading(kind: .right, level: 68),
                BatteryComponentReading(kind: .case, level: 90),
            ],
            isAppleAccessory: true,
            connectionState: .connected,
            checkedAt: timestamp
        )

        store.record(bluetoothDevices: [earbuds], at: timestamp)

        let device = try #require(store.devices.first)
        #expect(device.series.map(\.component) == [.left, .right, .case])
        #expect(device.latestLevel == 68)
        #expect(
            store.presentation(
                for: device.id,
                range: .day,
                now: timestamp
            ).points.count == 3
        )
    }

    @Test("History older than thirty days is removed when loading")
    func removesExpiredHistory() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let now = Date()
        let initialStore = BatteryHistoryStore(
            fileURL: fixture.fileURL,
            referenceDate: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )
        initialStore.record(
            deviceID: "hid:expired",
            name: "Old Device",
            symbolName: "battery.100percent",
            reading: BatteryReading(level: 50),
            at: now.addingTimeInterval(-31 * 24 * 60 * 60)
        )

        let reloaded = BatteryHistoryStore(
            fileURL: fixture.fileURL,
            referenceDate: now
        )
        #expect(reloaded.devices.isEmpty)
    }
}

private struct HistoryFixture {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("battery-history.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
