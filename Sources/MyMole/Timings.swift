import Foundation
import os
import Synchronization

/// How long the interface's own work takes, so a slow moment can be put
/// down to reading, working out or drawing. Kept on this Mac only: every
/// step is an `os_signpost` interval Instruments can show, and, when
/// turned on in Settings, the last durations of each kind are kept in
/// memory for a summary. No file names, paths or counts of anything but
/// rows are kept.
enum Timings {
    enum Step: String, CaseIterable, Sendable {
        /// Filtering a list (`OffMain`).
        case filter
        /// Sorting a table's rows.
        case sort
        /// Putting rows into a table: a full reload or the visible rows.
        case reload, refresh
        /// From the start of a Disk Map scan to the first map on screen.
        case firstMap
        /// From requesting an app list until its first inventory reaches the UI.
        case firstApps
        /// The complete app inventory and all its sizes.
        case appListing
        /// Duplicate search queue, metadata walk, first UI results and full run.
        case duplicateQueue, duplicateListing, firstDuplicates, duplicateSearch
        /// Preparing an AppKit table's context or column menu.
        case menu
        /// From asking a Disk Map scan to stop to it having stopped.
        case stop
        case confirmation, removalPreparation
        case removalScanWait, removalQueue, removalMove, removalApply

        var title: String {
            switch self {
            case .filter: String(localized: "Filter a list")
            case .sort: String(localized: "Sort a table")
            case .reload: String(localized: "Reload a table")
            case .refresh: String(localized: "Redraw visible rows")
            case .firstMap: String(localized: "First map of a scan")
            case .firstApps: String(localized: "First apps in a listing")
            case .appListing: String(localized: "Complete app listing")
            case .duplicateQueue: String(localized: "Duplicate search queue")
            case .duplicateListing: String(localized: "List duplicate candidates")
            case .firstDuplicates: String(localized: "First duplicate results")
            case .duplicateSearch: String(localized: "Complete duplicate search")
            case .menu: String(localized: "Prepare a table menu")
            case .stop: String(localized: "Stop a scan")
            case .confirmation: String(localized: "Open a confirmation")
            case .removalPreparation: String(localized: "Prepare removal details")
            case .removalScanWait: String(localized: "Stop scan before moving")
            case .removalQueue: String(localized: "Wait for the removal queue")
            case .removalMove: String(localized: "Move chosen items to the Trash")
            case .removalApply: String(localized: "Update the map after removal")
            }
        }
    }

    static let key = "timings.keep"
    /// Durations kept of each step, the newest.
    static let kept = 200
    static let signposter = OSSignposter(subsystem: "com.mymole.app", category: "Interface")

    private static let samples = Mutex<[Step: [Double]]>([:])

    static var isKeeping: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Times `work` as `step`, with how many rows it handled.
    static func measure<T>(_ step: Step, rows: Int = 0, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval("step", id: signposter.makeSignpostID(), "\(step.rawValue, privacy: .public) \(rows)")
        let start = ContinuousClock.now
        defer {
            signposter.endInterval("step", state)
            record(step, since: start)
        }
        return try work()
    }

    static func record(_ step: Step, since start: ContinuousClock.Instant) {
        guard isKeeping else { return }
        add(step, seconds: Double((ContinuousClock.now - start) / .milliseconds(1)) / 1_000)
    }

    static func add(_ step: Step, seconds: Double) {
        samples.withLock { all in
            var list = all[step] ?? []
            list.append(seconds)
            if list.count > kept { list.removeFirst(list.count - kept) }
            all[step] = list
        }
    }

    struct Summary: Sendable, Equatable {
        let step: Step
        let count: Int
        let median: Double
        let p95: Double
        let longest: Double
    }

    /// Each step measured so far, with its median, 95th percentile and longest time.
    static func summary() -> [Summary] {
        let all = samples.withLock { $0 }
        return Step.allCases.compactMap { step in
            guard let list = all[step], !list.isEmpty else { return nil }
            let sorted = list.sorted()
            func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
            return Summary(step: step, count: sorted.count, median: at(0.5), p95: at(0.95), longest: sorted.last ?? 0)
        }
    }

    static func clear() { samples.withLock { $0 = [:] } }

    /// The summary as plain text, to paste into a report.
    static func text() -> String {
        summary().map { s in
            String(format: "%@: %d × · median %.1f ms · p95 %.1f ms · longest %.1f ms",
                   s.step.rawValue, s.count, s.median * 1_000, s.p95 * 1_000, s.longest * 1_000)
        }.joined(separator: "\n")
    }
}
