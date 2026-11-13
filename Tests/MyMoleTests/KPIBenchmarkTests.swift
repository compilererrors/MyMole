import AppKit
import Foundation
@testable import StorageKit
import Synchronization
import SwiftUI
import Testing

@testable import MyMole

/// Key measurements of how quick and steady MyMole is, each held to a
/// budget in `Tests/KPIBudgets.json`. Synthetic data only, made by the run.
/// An ordinary benchmark run allows four times the budget, as parallel
/// work and a busy Mac add noise; MYMOLE_STRICT_BENCHMARKS=1, run serially,
/// holds each measurement to its budget. Off unless MYMOLE_BENCHMARK=1.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_BENCHMARK"] == "1"))
struct KPIBenchmarkTests {
    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "kpi-\(UUID().uuidString)")
        var path: String { root.path }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func file(_ rel: String, bytes: Int) {
            let url = root.appending(path: rel)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
        }
    }

    // MARK: Budget gate

    private static let budgets: [String: Double] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "KPIBudgets.json")
        guard let data = try? Data(contentsOf: url), let all = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else { return [:] }
        return all
    }()
    private static let strict = ProcessInfo.processInfo.environment["MYMOLE_STRICT_BENCHMARKS"] == "1"
    static let tolerance = 4.0

    /// Prints "kpi <name> <value> budget <budget> <unit>" and fails when the
    /// value is past the budget (strict) or past four times it (tolerant).
    private static func gate(_ name: String, _ value: Double, unit: String = "ms") {
        guard let budget = budgets[name] else {
            Issue.record("KPI \(name) has no budget in KPIBudgets.json")
            return
        }
        let limit = strict ? budget : budget * tolerance
        print(String(format: "kpi %@ %.3f %@ budget %.3f %@", name, value, unit, budget, value <= limit ? "ok" : "MISS"))
        #expect(value <= limit, "\(name): \(value) \(unit) against \(limit) (\(strict ? "strict" : "tolerant"))")
    }

    private static func ms(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        return Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    // MARK: Large results, in memory and on disk

    private static func spillRows(_ n: Int) -> [SpillTable.Row] {
        (0..<n).map { i in
            SpillTable.Row(path: "/synthetic/folder-\(i % 997)/file-\(i).bin", size: Int64((i &* 7_919) % 100_003) + 1_048_576,
                           modified: Date(timeIntervalSinceReferenceDate: Double(i % 86_400)), kind: FileKind.allCases[i % FileKind.allCases.count])
        }
    }

    private static func tableRows(_ n: Int) -> [FileRow] {
        (0..<n).map { i in
            FileRow(id: "/synthetic/folder-\(i % 997)/file-\(i).bin", name: "file-\(i).bin", size: Int64((i &* 7_919) % 100_003),
                    modified: Date(timeIntervalSinceReferenceDate: Double(i % 86_400)), kind: "Other", location: "/synthetic/folder-\(i % 997)")
        }
    }

    @Test func listsInMemorySortAndFilterQuickly() {
        for (n, label) in [(100_000, "100k"), (1_000_000, "1m")] {
            let rows = Self.tableRows(n)
            Self.gate("ram.sort-size.\(label)", Self.ms { _ = FileTable.sorted(rows, by: .size, ascending: false) })
            Self.gate("ram.sort-name.\(label)", Self.ms { _ = FileTable.sorted(rows, by: .name, ascending: true) })
            Self.gate("ram.filter.\(label)", Self.ms { _ = rows.filter { $0.name.lowercased().contains("file-12") } })
        }
    }

    @Test func spilledListsWriteReadSortAndFilterQuickly() throws {
        let box = try Box()
        for (n, label) in [(100_000, "100k"), (1_000_000, "1m")] {
            let rows = Self.spillRows(n)
            var table: SpillTable?
            Self.gate("spill.write.\(label)", try Self.ms { table = try SpillTable(writing: rows, in: box.root) })
            let spilled = try #require(table)
            // A screenful of rows at random places: what scrolling a long list reads.
            var generator = SystemRandomNumberGenerator()
            let reads = (0..<10_000).map { _ in Int.random(in: 0..<n, using: &generator) }
            Self.gate("spill.read-10k-rows.\(label)", Self.ms { for i in reads { _ = spilled.row(at: i) } })
            Self.gate("spill.scroll-page.\(label)", Self.ms { for i in 0..<40 { _ = spilled.row(at: n / 2 + i) } })
            var order: [UInt32]?
            Self.gate("spill.sort-size.\(label)", Self.ms { order = spilled.ordered(by: .size, ascending: false) })
            #expect(order?.count == n)
            Self.gate("spill.sort-name.\(label)", Self.ms { order = spilled.ordered(by: .name, ascending: true) })
            Self.gate("spill.filter.\(label)", Self.ms { order = spilled.ordered(by: .size, ascending: false, query: "folder-12") })
            #expect(order?.isEmpty == false)
            Self.gate("spill.disk-mb.\(label)", Double(spilled.diskBytes) / 1_048_576, unit: "MB")
            spilled.remove()
        }
    }

    // MARK: Scans

    @Test func diskMapAndProjectsScanSyntheticTreesQuickly() throws {
        let box = try Box()
        for folder in 0..<200 { for file in 0..<100 { box.file("tree/f\(folder)/file-\(file).bin", bytes: 64) } }
        for project in 0..<100 {
            box.file("work/p\(project)/Package.swift", bytes: 32)
            for file in 0..<50 { box.file("work/p\(project)/.build/obj-\(file).o", bytes: 64) }
        }
        let tree = box.path + "/tree"
        _ = StorageScanner.scan(path: tree)
        Self.gate("scan.disk-map.20k-files", Self.ms { _ = StorageScanner.scan(path: tree, workers: PerformanceLevel.full.workers(background: false)) })
        let roots = [box.path + "/work"]
        Self.gate("scan.projects.100", Self.ms { _ = ProjectScanner.scan(roots: roots, home: box.path + "/home") })
    }

    /// Scans `path` with a fresh model while a plain main-queue timer
    /// records the longest gap between its ticks: how long the main thread
    /// was ever kept from drawing.
    private func worstMainGap(scanning path: String, in box: Box) async throws -> (gap: Double, mb: Double, mapped: Bool) {
        let model = StorageModel()
        model.snapshotBase = box.root.appending(path: "snapshots-\(UUID().uuidString)")
        model.protections = UserProtections(root: box.root.appending(path: "support"))
        model.logURL = box.root.appending(path: "history.json")
        model.trashBackend = testBin(box.root)
        model.jobs = TrashJobs()
        model.scanBudget = ScanBudget(slots: 1)
        let worst = Mutex<Duration>(.zero), last = Mutex(ContinuousClock.now)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1))
        timer.setEventHandler {
            let now = ContinuousClock.now
            let gap = last.withLock { l in defer { l = now }; return now - l }
            worst.withLock { $0 = max($0, gap) }
        }
        let before = Self.residentMB()
        timer.resume()
        defer { timer.cancel() }
        model.scan(path: path)
        while model.scanning { try await Task.sleep(for: .milliseconds(1)) }
        await model.scanJob?.value
        return (Double(worst.withLock { $0 } / .microseconds(1)) / 1_000, max(0, Self.residentMB() - before), model.root != nil)
    }

    @Test func aDiskMapScanNeverStallsTheMainThread() async throws {
        let box = try Box()
        for folder in 0..<300 { for file in 0..<100 { box.file("tree/f\(folder)/file-\(file).bin", bytes: 64) } }
        // The first scan after launch also pays for code and threads used for the first time.
        let first = try await worstMainGap(scanning: box.path + "/tree", in: box)
        Self.gate("main.worst-gap.first-disk-map-scan", first.gap)
        let warm = try await worstMainGap(scanning: box.path + "/tree", in: box)
        Self.gate("main.worst-gap.disk-map-scan", warm.gap)
        Self.gate("memory.disk-map-scan-30k-files", warm.mb, unit: "MB")
        #expect(first.mapped && warm.mapped)
    }

    // MARK: First frame

    @Test func theFirstFrameOfASavedScanIsQuick() async throws {
        let box = try Box()
        for folder in 0..<300 { for file in 0..<100 { box.file("tree/f\(folder)/file-\(file).bin", bytes: 64) } }
        for file in 0..<200 { box.file("tree/big/file-\(file).bin", bytes: 1_100_000) }
        let saved = box.root.appending(path: "saved.mymolescan")
        try ScanExport(of: StorageScanner.scan(path: box.path + "/tree").root).data().write(to: saved)
        let model = StorageModel()
        model.snapshotBase = box.root.appending(path: "snapshots")
        model.protections = UserProtections(root: box.root.appending(path: "support"))
        model.logURL = box.root.appending(path: "history.json")
        model.trashBackend = testBin(box.root)
        model.jobs = TrashJobs()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        // Owned by this test, not by closing it.
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StorageView(model: model))
        window.contentView = host
        defer { window.close() }
        // From reading the saved result off disk to the pane drawn with it.
        let start = ContinuousClock.now
        await model.open(exported: saved)
        host.layoutSubtreeIfNeeded()
        host.display()
        Self.gate("launch.first-frame-saved-scan", Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000)
        #expect(model.root != nil && model.largeFiles.count == 200)
    }

    // MARK: Trash and Undo

    @Test func movingManyItemsAndPuttingThemBackIsQuick() throws {
        let box = try Box()
        let paths = (0..<2_000).map { i -> String in
            box.file("items/item-\(i).txt", bytes: 16)
            return box.path + "/items/item-\(i).txt"
        }
        let gate = TrashGate(still: { _ in true }, protections: TrashGate.keepsNothing)
        var outcome: TrashOutcome?
        Self.gate("trash.move-2k", Self.ms { outcome = Trasher.moveToTrash(paths, through: gate, backend: testBin(box.root)) })
        let moved = try #require(outcome?.moved)
        #expect(moved.count == 2_000)
        var failed: [TrashRecord] = []
        Self.gate("trash.undo-2k", Self.ms { failed = Trasher.restore(moved) })
        #expect(failed.isEmpty && paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }
}
