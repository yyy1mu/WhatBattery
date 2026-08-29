import Charts
import SwiftUI

struct BatteryHistorySettingsView: View {
    let history: BatteryHistoryStore

    @State private var selectedDeviceID: String?
    @State private var selectedRange: BatteryHistoryRange = .week
    @State private var selectedTimestamp: Date?
    @State private var isClearConfirmationPresented = false
    @State private var referenceDate = Date()

    var body: some View {
        VStack(spacing: 16) {
            HistoryToolbar(
                devices: history.devices,
                selectedDeviceID: $selectedDeviceID,
                selectedRange: $selectedRange,
                clearHistory: {
                    isClearConfirmationPresented = true
                }
            )

            if let selectedDevice {
                HistoryDeviceContent(
                    device: selectedDevice,
                    presentation: history.presentation(
                        for: selectedDevice.id,
                        range: selectedRange,
                        now: referenceDate
                    ),
                    range: selectedRange,
                    selectedTimestamp: $selectedTimestamp
                )
            } else {
                ContentUnavailableView(
                    "No Battery History",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        "History will appear after WhatBattery successfully reads a device battery level."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .onChange(of: history.devices, initial: true) { _, devices in
            let deviceIDs = devices.map(\.id)
            referenceDate = Date()
            if selectedDeviceID == nil
                || !deviceIDs.contains(selectedDeviceID ?? "") {
                selectedDeviceID = deviceIDs.first
            }
        }
        .onChange(of: selectedDeviceID) {
            selectedTimestamp = nil
        }
        .onChange(of: selectedRange) {
            selectedTimestamp = nil
            referenceDate = Date()
        }
        .confirmationDialog(
            "Clear Battery History?",
            isPresented: $isClearConfirmationPresented
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes battery history for all devices.")
        }
    }

    private var selectedDevice: BatteryHistoryDevice? {
        guard let selectedDeviceID else { return nil }
        return history.devices.first { $0.id == selectedDeviceID }
    }
}

private struct HistoryToolbar: View {
    let devices: [BatteryHistoryDevice]
    @Binding var selectedDeviceID: String?
    @Binding var selectedRange: BatteryHistoryRange
    let clearHistory: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Device", selection: $selectedDeviceID) {
                if devices.isEmpty {
                    Text("No Devices")
                        .tag(Optional<String>.none)
                } else {
                    ForEach(devices) { device in
                        Label(device.name, systemImage: device.symbolName)
                            .tag(Optional(device.id))
                    }
                }
            }
            .frame(maxWidth: 290)

            Picker("Time Range", selection: $selectedRange) {
                ForEach(BatteryHistoryRange.allCases) { range in
                    Text(range.displayName)
                        .tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()

            Button("Clear History", systemImage: "trash", action: clearHistory)
                .disabled(devices.isEmpty)
        }
    }
}

private struct HistoryDeviceContent: View {
    let device: BatteryHistoryDevice
    let presentation: BatteryHistoryPresentation
    let range: BatteryHistoryRange
    @Binding var selectedTimestamp: Date?

    var body: some View {
        VStack(spacing: 14) {
            HistoryStatistics(presentation: presentation)

            if presentation.points.isEmpty {
                ContentUnavailableView(
                    "No Data in This Range",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Choose a longer time range or wait for a new reading.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BatteryHistoryChart(
                    deviceName: device.name,
                    presentation: presentation,
                    range: range,
                    selectedTimestamp: $selectedTimestamp
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryStatistics: View {
    let presentation: BatteryHistoryPresentation

    var body: some View {
        HStack(spacing: 10) {
            HistoryMetric(
                title: "Latest",
                value: percentage(presentation.latestLevel),
                systemImage: "battery.100percent",
                tint: .green
            )
            HistoryMetric(
                title: "Change",
                value: signedPercentage(presentation.change),
                systemImage: changeSymbol,
                tint: changeTint
            )
            HistoryMetric(
                title: "Minimum",
                value: percentage(presentation.minimumLevel),
                systemImage: "arrow.down",
                tint: .orange
            )
            HistoryMetric(
                title: "Maximum",
                value: percentage(presentation.maximumLevel),
                systemImage: "arrow.up",
                tint: .blue
            )
        }
    }

    private var changeSymbol: String {
        guard let change = presentation.change else { return "minus" }
        if change > 0 { return "arrow.up.right" }
        if change < 0 { return "arrow.down.right" }
        return "minus"
    }

    private var changeTint: Color {
        guard let change = presentation.change else { return .secondary }
        if change > 0 { return .green }
        if change < 0 { return .orange }
        return .secondary
    }

    private func percentage(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    private func signedPercentage(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value > 0 ? "+\(value)%" : "\(value)%"
    }
}

private struct HistoryMetric: View {
    let title: LocalizedStringResource
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct BatteryHistoryChart: View {
    let deviceName: String
    let presentation: BatteryHistoryPresentation
    let range: BatteryHistoryRange
    @Binding var selectedTimestamp: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(presentation.points) { point in
                    LineMark(
                        x: .value(String(localized: "Date"), point.timestamp),
                        y: .value(String(localized: "Battery Level"), point.level)
                    )
                    .foregroundStyle(
                        by: .value(String(localized: "Battery"), point.seriesName)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }

                ForEach(latestPoints) { point in
                    PointMark(
                        x: .value(String(localized: "Date"), point.timestamp),
                        y: .value(String(localized: "Battery Level"), point.level)
                    )
                    .foregroundStyle(
                        by: .value(String(localized: "Battery"), point.seriesName)
                    )
                    .symbolSize(38)
                }

                if let selectedTimestamp {
                    RuleMark(
                        x: .value(
                            String(localized: "Selected Date"),
                            selectedTimestamp
                        )
                    )
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    ForEach(selectedPoints) { point in
                        PointMark(
                            x: .value(String(localized: "Date"), point.timestamp),
                            y: .value(String(localized: "Battery Level"), point.level)
                        )
                        .foregroundStyle(
                            by: .value(
                                String(localized: "Battery"),
                                point.seriesName
                            )
                        )
                        .symbolSize(64)
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let level = value.as(Int.self) {
                            Text("\(level)%")
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) {
                    AxisGridLine()
                    AxisTick()
                    if range == .day {
                        AxisValueLabel(format: .dateTime.hour().minute())
                    } else {
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
            }
            .chartLegend(
                presentationSeriesCount > 1 ? .visible : .hidden
            )
            .chartXSelection(value: $selectedTimestamp)
            .chartPlotStyle { plotArea in
                plotArea
                    .background(.quaternary.opacity(0.18))
                    .clipShape(.rect(cornerRadius: 8))
            }
            .accessibilityLabel("Battery history for \(deviceName)")

            if let selectedTimestamp, !selectedPoints.isEmpty {
                HStack(spacing: 12) {
                    Text(selectedTimestamp, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.secondary)

                    ForEach(selectedPoints) { point in
                        Text("\(point.seriesName): \(point.level)%")
                            .fontWeight(.medium)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            } else {
                Text("Select a point on the chart to inspect its battery level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var presentationSeriesCount: Int {
        Set(presentation.points.map(\.component)).count
    }

    private var latestPoints: [BatteryHistoryChartPoint] {
        Dictionary(grouping: presentation.points, by: \.component)
            .compactMap { $0.value.last }
            .sorted { $0.component.rawValue < $1.component.rawValue }
    }

    private var selectedPoints: [BatteryHistoryChartPoint] {
        guard let selectedTimestamp else { return [] }
        return Dictionary(grouping: presentation.points, by: \.component)
            .compactMap { _, points in
                points.min {
                    abs($0.timestamp.timeIntervalSince(selectedTimestamp))
                        < abs($1.timestamp.timeIntervalSince(selectedTimestamp))
                }
            }
            .sorted { $0.component.rawValue < $1.component.rawValue }
    }
}
