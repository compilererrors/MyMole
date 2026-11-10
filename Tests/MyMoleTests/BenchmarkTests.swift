import AppKit
import Darwin
import Foundation
@testable import StorageKit
import Synchronization
import SwiftUI
import Testing

@testable import MyMole

/// Synthetic workloads timed in an optimized build.
/// Off unless MYMOLE_BENCHMARK=1; each prints one "bench" line with the
/// time taken and the most memory the run had held by then.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MYMOLE_BENCHMARK"] == "1"))
struct BenchmarkTests {
    @Test func preparingLargeDiskMapResults() {
        let root = Folder(name: "synthetic", parent: nil, rootPath: "/synthetic")
        for folder in 0..<1_500 {
            let child = Folder(name: "folder-\(folder)", parent: root)
            child.listedFiles = (0..<64).map { file in
                FileItem(name: "file-\(file).bin", size: Int64(((folder * 64 + file) * 7919) % 100_003) + 1_048_576,
                         modified: .distantPast, kind: .other)
            }
            root.subfolders.append(child)
        }
        let baseline = Self.time("disk-large-legacy-96k") {
            var files: [LargeFile] = []
            var stack = [root]
            while let folder = stack.popLast() {
                let path = folder.path
                files += folder.listedFiles.map { LargeFile(path: path + "/" + $0.name, name: $0.name, folder: path, size: $0.size, modified: $0.modified, kind: $0.kind) }
                stack += folder.subfolders
            }
            files.sort { $0.size > $1.size }
            return Array(files.prefix(5_000))
        }
        let bounded = Self.time("disk-large-bounded-96k") { StorageModel.collectLargeFiles(root) }
        #expect(baseline.map(\.path) == bounded.map(\.path))
        let stopped = Self.time("disk-large-cancelled") { StorageModel.collectLargeFiles(root, stop: { true }) }
        #expect(stopped.isEmpty)
    }

    private final class Box {
        let root = FileManager.default.temporaryDirectory.appending(path: "bench-\(UUID().uuidString)")
        var path: String { root.path }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }

        func file(_ rel: String, bytes: Int, seed: UInt8 = 0) {
            let path = self.path + "/" + rel
            var data = [UInt8](repeating: seed, count: bytes)
            if bytes > 0 { arc4random_buf(&data, bytes) }
            FileManager.default.createFile(atPath: path, contents: Data(data))
        }

        func folder(_ rel: String) throws {
            try FileManager.default.createDirectory(atPath: path + "/" + rel, withIntermediateDirectories: true)
        }
    }

    /// What the process holds now (its footprint), not its peak.
    private static func nowMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func peakMB() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_maxrss) / 1_048_576
    }

    private static func report(_ name: String, _ ms: Double?, held: Double? = nil) {
        let label = name.padding(toLength: 30, withPad: " ", startingAt: 0)
        let value = ms.map { String(format: "%10.1f ms", $0) } ?? "       n/a   "
        let kept = held.map { String(format: "   held %+7.1f MB", $0) } ?? ""
        print("bench \(label)\(value)   peak " + String(format: "%7.1f MB", peakMB()) + kept)
    }

    /// Times `work` and says how much more memory the process holds while its result is kept.
    private static func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let before = nowMB()
        let start = ContinuousClock.now
        let v = try work()
        let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
        report(name, ms, held: nowMB() - before)
        return v
    }

    private static func repeated(_ name: String, runs: Int = 15, _ work: () -> Void) {
        work() // Warm the code path separately from the samples.
        let samples = (0..<runs).map { _ -> Double in
            let start = ContinuousClock.now
            work()
            return Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
        }.sorted()
        let p95 = samples[min(runs - 1, Int(ceil(Double(runs) * 0.95)) - 1)]
        print(String(format: "bench %@   n %d   median %.3f ms   p95 %.3f ms   max %.3f ms", name, runs, samples[runs / 2], p95, samples.last ?? 0))
    }

    @Test func stoppingAQueuedScan() async throws {
        _ = try await Self.queuedStopSample()
        var samples: [Double] = []
        for _ in 0..<15 { samples.append(try await Self.queuedStopSample()) }
        samples.sort()
        print(String(format: "bench stop a queued scan   n %d   median %.3f ms   p95 %.3f ms   max %.3f ms", samples.count, samples[7], samples[14], samples[14]))
    }

    private static func queuedStopSample() async throws -> Double {
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task { await budget.run(background: true) { for await _ in stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let progress = ScanProgress()
        let done = Mutex<ContinuousClock.Instant?>(nil)
        let stopped = Task {
            let value = await budget.run(background: false, progress: progress) { 1 }
            done.withLock { $0 = .now }
            return value
        }
        try #require(await waitUntil { budget.waiting == 1 })
        let start = ContinuousClock.now
        progress.cancel()
        try #require(await waitUntil { done.withLock { $0 != nil } })
        #expect(await stopped.value == nil)
        // Includes the stopped task's wake-up, without the sampling loop's
        // polling interval. The holder stays occupied until it has returned.
        let ended = try #require(done.withLock { $0 })
        let ms = Double((ended - start) / .microseconds(1)) / 1_000
        #expect(budget.running == 1 && budget.waiting == 0)
        release.yield(())
        release.finish()
        _ = await hold.value
        return ms
    }

    @MainActor @Test func preparingAnExpandableTree() async {
        for count in [50, 50_000] {
            let root = Folder(name: "tree", parent: nil, rootPath: "/synthetic/tree")
            for i in 0..<count {
                let child = Folder(name: "folder\(i)", parent: root)
                child.ownBytes[.other] = Int64(i + 1)
                root.subfolders.append(child)
            }
            root.finish()
            _ = await Self.treeSample(root, expected: count)
            var samples: [Double] = []
            for _ in 0..<7 { samples.append(await Self.treeSample(root, expected: count)) }
            samples.sort()
            print(String(format: "bench tree branch %d folders   n %d   median %.3f ms   p95 %.3f ms   max %.3f ms", count, samples.count, samples[3], samples[6], samples[6]))
        }
    }

    @MainActor private static func treeSample(_ root: Folder, expected: Int) async -> Double {
        let state = DiskOutline.State()
        let parent = DiskOutline(root: root, revision: 1, ready: { _ in true }, state: state,
                                 selection: .constant([]), expanded: .constant([]), marks: nil,
                                 row: { FileRow(id: $0.path, name: $0.name, size: $0.size) },
                                 onToggle: { _ in }, onOpen: { _ in }, onMark: { _ in }, onHover: { _ in },
                                 menu: { _, _ in [] }, onSmallFiles: { _ in })
        let coordinator = parent.makeCoordinator()
        defer { coordinator.stop() }
        let outline = DiskOutlineView()
        let name = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(name)
        outline.outlineTableColumn = name
        outline.addTableColumn(NSTableColumn(identifier: .init("size")))
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.outline = outline
        let start = ContinuousClock.now
        coordinator.rebuild()
        await coordinator.job?.value
        let ms = Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000
        #expect(state.visible.count == expected && outline.numberOfRows == expected)
        #expect(coordinator.rootNode?.children?.allSatisfy { $0.children == nil } == true)
        return ms
    }

    private static func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return ready()
    }

    @Test func scanningWideAndDeepTrees() throws {
        let box = try Box()
        for d in 0..<200 {
            try box.folder("wide/d\(d)")
            for f in 0..<100 { box.file("wide/d\(d)/f\(f)", bytes: 0) }
        }
        var deep = "deep"
        for i in 0..<200 { deep += "/l\(i)" }
        try box.folder(deep)
        box.file(deep + "/leaf", bytes: 10)
        _ = Self.time("scan wide 20,000 files") { StorageScanner.scan(path: box.path + "/wide", workers: 4) }
        _ = Self.time("scan wide again (warm)") { StorageScanner.scan(path: box.path + "/wide", workers: 4) }
        _ = Self.time("scan deep 200 levels") { StorageScanner.scan(path: box.path + "/deep", workers: 4) }

        // How soon a stop is honoured mid-scan.
        let progress = ScanProgress()
        let stopped = DispatchSemaphore(value: 0)
        let done = Mutex<ContinuousClock.Instant?>(nil)
        let wide = box.path + "/wide"
        DispatchQueue.global().async {
            _ = StorageScanner.scan(path: wide, progress: progress, workers: 4)
            done.withLock { $0 = .now }
            stopped.signal()
        }
        Thread.sleep(forTimeInterval: 0.002)
        let asked = ContinuousClock.now
        progress.cancel()
        stopped.wait()
        // A scan that ended before the stop says nothing about stopping.
        let ended = done.withLock { $0 } ?? asked
        Self.report("stop a scan", ended > asked ? Double((ended - asked) / .microseconds(1)) / 1_000 : nil)
    }

    @Test func comparingManyFilesOfOneLength() throws {
        let box = try Box()
        try box.folder("same")
        for i in 0..<5_000 { box.file("same/f\(i).bin", bytes: 8_192) }
        _ = Self.time("duplicates 5,000 × 8 KB") { DuplicateFinder.find(in: [box.path + "/same"], minimum: 4_096, workers: 4) }
    }

    @Test func duplicateSearchStages() throws {
        for count in [50, 5_000] {
            let box = try Box()
            try box.folder("files")
            for pair in 0..<(count / 2) {
                box.file("files/f\(pair)-a.bin", bytes: 8_192)
                try FileManager.default.copyItem(atPath: box.path + "/files/f\(pair)-a.bin", toPath: box.path + "/files/f\(pair)-b.bin")
            }
            var measurements: [String: [Double]] = [:]
            for _ in 0..<7 {
                let start = ContinuousClock.now
                let stages = Mutex<[String: Double]>([:])
                @Sendable func elapsed() -> Double { Double((ContinuousClock.now - start) / .microseconds(1)) / 1_000 }
                let found = DuplicateFinder.find(in: [box.path + "/files"], minimum: 4_096, workers: 4,
                    onGroup: { _ in stages.withLock { if $0["first verified group"] == nil { $0["first verified group"] = elapsed() } } },
                    onStep: { s in
                        if s.phase == .comparing, s.done == 0 { stages.withLock { $0["metadata"] = elapsed() } }
                    })
                #expect(found.groups.count == count / 2 && found.uncompared == 0 && found.unreadable.isEmpty)
                let total = elapsed()
                let measured = stages.withLock { $0 }
                for (name, value) in measured { measurements[name, default: []].append(value) }
                measurements["content comparison", default: []].append(total - (measured["metadata"] ?? total))
                measurements["total", default: []].append(total)
            }
            for name in measurements.keys.sorted() {
                let values = measurements[name, default: []].sorted()
                #expect(values.count == 7)
                print(String(format: "bench duplicates %d %@   n 7   median %.3f ms   p95 %.3f ms", count, name, values[values.count / 2], values.last ?? 0))
            }
        }
    }

    @Test func groupingTwentyThousandFingerprints() {
        let prints = (0..<20_000).map { i in
            (SimilarImage(path: "/synthetic/\(i).jpg", bytes: 1, modified: .distantPast, width: 1, height: 1, inode: 0, length: 1),
             UInt64.random(in: .min ... .max))
        }
        _ = Self.time("similar 20,000 fingerprints") { SimilarImages.group(prints) }
    }

    @Test func sortingAndFilteringLargeLists() {
        let rows = (0..<50_000).map { i in
            FileRow(id: "/synthetic/folder\(i % 300)/file\(i).bin", name: "file\(i).bin", size: Int64.random(in: 1...1_000_000_000),
                    modified: Date(timeIntervalSince1970: Double(i)), location: "/synthetic/folder\(i % 300)")
        }
        _ = Self.time("sort 50,000 rows by size") { FileTable.sorted(rows, by: .size, ascending: false) }
        _ = Self.time("sort 50,000 rows by name") { FileTable.sorted(rows, by: .name, ascending: true) }
        _ = Self.time("filter 50,000 rows") { rows.filter { DSFilterField.matches("file1 folder2", $0.name, $0.location ?? "") } }
        let query = TextQuery("file1 folder2")
        for count in [50, 50_000] {
            let list = Array(rows.prefix(count))
            Self.repeated("per-row query \(count) rows") {
                let found = list.filter { DSFilterField.matches("file1 folder2", $0.name, $0.location ?? "") }
                withExtendedLifetime(found) {}
            }
            Self.repeated("prepared filter \(count) rows") {
                let found = list.filter { query.matches($0.name, $0.location ?? "") }
                withExtendedLifetime(found) {}
            }
        }
    }

    @MainActor @Test func repeatedLargeListInteractions() async {
        let rows = (0..<50_000).map { FileRow(id: "/synthetic/\($0)", name: "Item \($0)", size: Int64($0)) }
        let parent = FileTable(rows: rows, columns: [.name, .size], autosave: "synthetic.interactions", selection: .constant([]))
        let coordinator = parent.makeCoordinator()
        let table = FileTableView()
        coordinator.table = table
        table.dataSource = coordinator
        coordinator.load(rows, marks: [], selection: [])
        await coordinator.sortJob?.value
        Self.repeated("unchanged table 50k", runs: 31) {
            coordinator.load(rows, marks: [], selection: [])
        }
        var offset = 0
        Self.repeated("selection table 50k", runs: 31) {
            offset += 1
            coordinator.load(rows, marks: [], selection: [rows[offset].id])
        }
        #expect(coordinator.shown.count == rows.count && coordinator.sortJob == nil)
    }

    @Test func preparedOrphanOwnerLookups() {
        let claimed = Set((0..<5_000).map { "net.syntheticcatalog.Product\($0)" })
        let owners = Orphans.Owners(vendors: [], running: [], claimedIDs: claimed)
        let candidates = (0..<12_000).map { "org.syntheticunused.Item\($0)" }
        Self.repeated("orphan ownership 5k x 12k", runs: 15) {
            #expect(!candidates.contains(where: owners.claims))
        }
    }

    @Test func firstAppInventoryPrecedesBundleSizes() throws {
        let box = try Box()
        for i in 0..<100 {
            let path = "Applications/Canvas\(i).app/Contents"
            try box.folder(path + "/Resources")
            let info: NSDictionary = ["CFBundleIdentifier": "org.example.Canvas\(i)", "CFBundleName": "Canvas\(i)"]
            try info.write(to: box.root.appending(path: path + "/Info.plist"))
            for f in 0..<100 { box.file(path + "/Resources/item\(f)", bytes: 0) }
        }
        Self.repeated("apps metadata 100 (10k files)", runs: 7) {
            let p = ScanProgress()
            // Stop at the actual inventory callback: no size walk is included.
            let listing = AppFinder.list(in: [box.path + "/Applications"], progress: p) { _ in p.cancel() }
            #expect(listing.apps.count == 100 && p.files == 0)
        }
        Self.repeated("apps complete 100 (10k files)", runs: 7) {
            let listing = AppFinder.list(in: [box.path + "/Applications"])
            #expect(listing.apps.count == 100 && listing.isComplete)
        }
    }

    /// Real AppKit menu construction with a synthetic table; no window or user files.
    @MainActor @Test func preparingMenusInSmallAndLargeTables() async {
        for count in [50, 50_000] {
            let rows = (0..<count).map { FileRow(id: "/synthetic/item\($0)", name: "item\($0)", size: Int64($0)) }
            let parent = FileTable(rows: rows, columns: [.name, .size], autosave: "synthetic.benchmark", selection: .constant([]),
                                   menu: { FileActions.menu($0) })
            let coordinator = parent.makeCoordinator()
            let table = FileTableView()
            table.dataSource = coordinator
            coordinator.table = table
            coordinator.load(rows, marks: nil, selection: [])
            await coordinator.sortJob?.value
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let menu = NSMenu()
            Self.repeated("context menu in \(count) rows") {
                coordinator.menuNeedsUpdate(menu)
                #expect(menu.items.contains { $0.title == "Copy Absolute Path" })
            }
        }
    }
}
