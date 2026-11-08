import Foundation
import SystemKit

/// The most recent readings of CPU, memory, the startup disk and the
/// battery, a few minutes' worth, for small graphs. Kept in memory only,
/// filled by the readings taken anyway, so it adds no work of its own.
struct StatusHistory: Equatable {
    static let kept = 120

    private(set) var cpu: [Double] = []
    private(set) var memory: [Double] = []
    private(set) var disk: [Double] = []
    private(set) var battery: [Double] = []

    mutating func add(_ s: SystemSnapshot) {
        append(&cpu, s.cpu?.usage)
        append(&memory, s.memory?.usedPercent)
        append(&disk, s.startupVolume?.usedPercent)
        append(&battery, s.battery?.percent)
    }

    /// A reading that's missing ends the line rather than drawing a zero.
    private func append(_ list: inout [Double], _ value: Double?) {
        guard let value else {
            list.removeAll()
            return
        }
        list.append(value)
        if list.count > Self.kept { list.removeFirst(list.count - Self.kept) }
    }
}
