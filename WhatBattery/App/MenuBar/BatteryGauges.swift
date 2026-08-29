import SwiftUI

enum BatteryLevelTint {
    static func color(for level: Int?) -> Color {
        guard let level else { return .secondary }
        switch level {
        case ...20:
            return .red
        case 21...50:
            return .orange
        default:
            return .green
        }
    }
}

struct CircularBatteryGauge: View {
    let level: Int?
    let isCharging: Bool
    var diameter: CGFloat = 38
    var lineWidth: CGFloat = 3.5

    private var tint: Color {
        BatteryLevelTint.color(for: level)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)

            if let level {
                Circle()
                    .trim(from: 0, to: max(CGFloat(level) / 100, 0.015))
                    .stroke(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(
                            lineWidth: lineWidth,
                            lineCap: .round
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }

            Text(level.map { "\($0)" } ?? "--")
                .font(.system(size: diameter * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(level == nil ? .secondary : tint)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .monospacedDigit()
                .padding(4)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) {
            if isCharging {
                Image(systemName: "bolt.circle.fill")
                    .font(.system(size: diameter * 0.38))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(.background, in: .circle)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery level")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let level else {
            return String(localized: "Unknown")
        }
        if isCharging {
            return String(
                localized: "\(level)% charging",
                comment: "Accessible value for a charging circular battery gauge."
            )
        }
        return "\(level)%"
    }
}

struct BatteryComponentGauges: View {
    let components: [BatteryComponentReading]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(components) { component in
                BatteryComponentGauge(component: component)
            }
        }
    }
}

private struct BatteryComponentGauge: View {
    let component: BatteryComponentReading

    var body: some View {
        VStack(spacing: 2) {
            CircularBatteryGauge(
                level: component.level,
                isCharging: false,
                diameter: 30,
                lineWidth: 2.5
            )

            componentLabel
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var componentLabel: some View {
        switch component.kind {
        case .main:
            Text("Battery")
        case .left:
            Text("L")
        case .right:
            Text("R")
        case .case:
            Text("Case")
        }
    }
}
