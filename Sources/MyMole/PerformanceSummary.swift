import Foundation
import StorageKit

/// What a performance step means in numbers, shown under its control in
/// Settings so each step reads as something concrete.
enum PerformanceSummary {
    static func scans(_ level: PerformanceLevel) -> String {
        let threads = level.workers(background: false)
        let slots = level.scanSlots()
        return slots == .max
            ? String(localized: "Any number of scans at once · \(threads) threads for a scan you wait on")
            : String(localized: "Up to \(slots) scans at once · \(threads) threads for a scan you wait on")
    }

    static func results(_ size: ResultSize) -> String {
        guard let saved = size.savedScanLimit, let memory = size.memoryBudget() else {
            return String(localized: "Every list in memory · every saved scan · a history point for every scan")
        }
        let hours = Int(size.historyInterval / 3_600)
        return String(localized: "Up to \(ByteSize.format(memory)) in memory, then disk · \(ByteSize.format(saved)) of saved scans · a history point at most every \(hours) h")
    }

    @MainActor static func responsiveness(_ level: Responsiveness) -> String {
        let r = level.resolved()
        let repaint = Int(r.publishInterval.components.seconds * 1_000 + r.publishInterval.components.attoseconds / 1_000_000_000_000_000)
        guard r.iconLimit != .max, let fresh = r.freshWindow(StorageModel.freshFor) else {
            return String(localized: "Every icon and chart kept · repaints every \(repaint) ms · every pane prepared afresh at launch")
        }
        let minutes = max(Int(fresh / 60), 1)
        return String(localized: "\(r.iconLimit.formatted()) icons · \(r.chartLayoutLimit.formatted()) charts · repaints every \(repaint) ms · a disk map under \(minutes) min old is reused at launch")
    }
}
