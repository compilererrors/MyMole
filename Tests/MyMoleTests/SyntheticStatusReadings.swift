import Foundation
import SystemKit

@testable import MyMole

/// Deliberately synthetic values, with invalid PIDs so a telemetry row cannot
/// capture or act on any real process. No reader or sampler is constructed.
@MainActor enum SyntheticStatusReadings {
    static let history: StatusHistory = {
        var history = StatusHistory()
        for reading in 0..<StatusHistory.kept { history.add(snapshot(reading: reading)) }
        return history
    }()

    static func snapshot(reading: Int = 0) -> SystemSnapshot {
        let gib: Int64 = 1_073_741_824
        let processes: [SystemSnapshot.Process] = (0..<8).map { index in
            let pid = -Int32(index) - 1
            let memory = gib / 2 + Int64(index) * 33_554_432
            return SystemSnapshot.Process(pid: pid, name: "Synthetic worker \(index)", cpu: Double(index + 1) * 3, memoryBytes: memory)
        }
        return SystemSnapshot(
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(reading)),
            hardware: .init(model: "Synthetic device", chip: nil, memoryBytes: 16 * gib, osVersion: "26"),
            uptime: 7_200,
            cpu: .init(usage: Double(10 + reading % 80), perCore: (0..<8).map { Double(10 + ($0 + reading) % 80) }, load: nil),
            memory: .init(used: 8 * gib, total: 16 * gib, swapUsed: gib, swapTotal: 2 * gib, pressure: .normal),
            volumes: [.init(name: "Synthetic disk", mount: "/", total: 1_000 * gib, available: 400 * gib, isInternal: true)],
            disk: .init(read: 64 * 1_048_576, write: 16 * 1_048_576),
            network: [.init(name: "synthetic0", address: nil, received: 2 * 1_048_576, sent: 524_288)],
            battery: .init(percent: 68, charging: false, onPower: false, minutesLeft: 240, health: "Normal", cycleCount: 50, capacityPercent: 95),
            topProcesses: processes)
    }
}
