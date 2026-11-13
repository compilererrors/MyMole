import StorageKit
import SwiftUI

struct ScanSpeedControl: View {
    @Binding var performance: Int
    private var level: PerformanceLevel { PerformanceLevel(saved: performance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Slider(value: Binding(get: { Double(level.rawValue) }, set: { performance = Int($0.rounded()) }),
                   in: 1...Double(PerformanceLevel.allCases.count), step: 1) {
                Text("Scan speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise").help("Gentle")
            } maximumValueLabel: {
                Image(systemName: "hare").help("Hyperspeed: no limits")
            }
            .accessibilityIdentifier("settings.scan-speed")
            .accessibilityValue("\(level.title), level \(level.rawValue) of \(PerformanceLevel.allCases.count)")
            HStack(spacing: 6) {
                Text("\(level.title) · level \(level.rawValue) of \(PerformanceLevel.allCases.count)").fontWeight(.medium)
                if level == .standard {
                    Text("Default").foregroundStyle(.secondary)
                } else {
                    Button("Reset") { performance = PerformanceLevel.standard.rawValue }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("settings.scan-speed.reset")
                }
            }.font(.caption)
            Text(level.detail).font(.caption).foregroundStyle(.secondary)
            Text(PerformanceSummary.scans(level)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
