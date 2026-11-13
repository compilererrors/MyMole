import Foundation
import Synchronization
import Testing

@testable import StorageKit

@Suite struct ResultSizeTests {
    @Test func eachStepUpKeepsMoreInMemoryAndHyperspeedEverything() {
        let gigabyte: UInt64 = 1 << 30
        let budgets = ResultSize.allCases.dropLast().map { $0.memoryBudget(physical: 16 * gigabyte)! }
        #expect(budgets == budgets.sorted() && Set(budgets).count == budgets.count)
        #expect(ResultSize.maximum.memoryBudget(physical: 16 * gigabyte) == 4 << 30, "A quarter of 16 GB")
        #expect(ResultSize.maximum.memoryBudget(physical: 4 * gigabyte) == 2 << 30, "At least 2 GB")
        #expect(ResultSize.hyperspeed.memoryBudget() == nil)
    }

    @Test func balancedKeepsWhatMyMoleKeptBefore() {
        #expect(ResultSize.base == .balanced)
        #expect(ResultSize.balanced.savedScanLimit == SnapshotStore.totalLimit)
    }

    @Test func nothingSavedMeansMaximum() {
        #expect(ResultSize.byDefault == .maximum)
        #expect(ResultSize(saved: 0) == .maximum)
        #expect(ResultSize(saved: 3) == .balanced)
        #expect(ResultSize(saved: 6) == .hyperspeed)
        #expect(ResultSize(saved: 42) == .maximum)
    }

    @Test func diskUseGrowsStepByStepAndOnlyHyperspeedHasNoLimit() {
        let megabyte: Int64 = 1 << 20
        #expect(ResultSize.allCases.map(\.savedScanLimit) == [50 * megabyte, 100 * megabyte, 200 * megabyte, 500 * megabyte, 1_024 * megabyte, nil])
        #expect(ResultSize.balanced.savedScanLimit == SnapshotStore.totalLimit)
        #expect(ResultSize.allCases.map { $0.historyInterval / 3_600 } == [24, 12, 6, 3, 1, 0])
        #expect(ResultSize.balanced.historyInterval == SnapshotStore.unattendedInterval)
        for size in ResultSize.allCases where size != .hyperspeed { #expect(size.projectSamplesKept == ProjectStore.keep) }
        #expect(ResultSize.hyperspeed.projectSamplesKept == .max)
    }

    @Test func hourlyPointsAtMaximumStillReachADayBack() {
        var samples: [ProjectStore.Sample] = []
        for hour in 0..<72 {
            samples = ProjectStore.adding(
                ProjectStore.Sample(date: Date(timeIntervalSince1970: Double(hour) * 3_600), bytes: Int64(hour)), to: samples,
                interval: ResultSize.maximum.historyInterval, keep: ResultSize.maximum.projectSamplesKept)
        }
        #expect(samples.count == ProjectStore.keep)
        #expect(ProjectStore.growth(samples)?.since == Date(timeIntervalSince1970: 47 * 3_600))
    }

    @Test func everyScanAddsAPointAtHyperspeedAndGrowthStillLooksADayBack() {
        var samples: [ProjectStore.Sample] = []
        for hour in 0..<30 {
            samples = ProjectStore.adding(
                ProjectStore.Sample(date: Date(timeIntervalSince1970: Double(hour) * 3_600), bytes: Int64(hour)), to: samples,
                interval: ResultSize.hyperspeed.historyInterval, keep: ResultSize.hyperspeed.projectSamplesKept)
        }
        #expect(samples.count == 30)
        let growth = ProjectStore.growth(samples)
        #expect(growth?.since == Date(timeIntervalSince1970: 5 * 3_600))
    }

    @Test func anUnattendedScanIsAlwaysDueAtHyperspeed() throws {
        let box = try Sandbox()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        SnapshotStore.save(Snapshot(rootPath: "/r", date: date, sizes: ["": 1]), base: box.url)
        #expect(!SnapshotStore.isDue(for: "/r", now: date.addingTimeInterval(60), base: box.url,
                                     interval: ResultSize.maximum.historyInterval))
        #expect(SnapshotStore.isDue(for: "/r", now: date.addingTimeInterval(60), base: box.url,
                                    interval: ResultSize.hyperspeed.historyInterval))
    }

    @Test func aDamagedOrMissingSnapshotStoreReadsAsNoHistory() throws {
        let box = try Sandbox()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let ref = try #require(SnapshotStore.save(Snapshot(rootPath: "/r", date: date, sizes: ["": 1]), base: box.url))
        try Data("not a scan".utf8).write(to: ref.url)
        #expect(SnapshotStore.load(ref) == nil, "A damaged scan is never read as a real one")
        try Data().write(to: ref.url.deletingLastPathComponent().appending(path: "stray-file.json"))
        #expect(SnapshotStore.history(for: "/r", base: box.url).count == 1, "Files that aren't scans are ignored")
        #expect(SnapshotStore.history(for: "/r", base: box.url.appending(path: "missing")).isEmpty)
    }

    @Test func theSharedBudgetFollowsTheScanSpeed() async {
        let slots = Atomic<Int>(1)
        let budget = ScanBudget(slots: { slots.load(ordering: .relaxed) })
        #expect(budget.slots == 1)
        slots.store(.max, ordering: .relaxed)
        #expect(budget.slots == .max)
        let ran = await budget.run(background: true) { 7 }
        #expect(ran == 7)
    }

    private func found(_ count: Int) -> [FoundFile] {
        (0..<count).map {
            FoundFile(name: "f\($0)", folder: "/synthetic", size: Int64($0), modified: .distantPast, kind: .other)
        }
    }

    @Test func aScanKeepsAsManyFoundFilesAsItsSizeAllows() {
        let few = ScanProgress(collectsFound: true, keepsFound: 3)
        few.add(found(10))
        #expect(few.drainFound().map(\.size) == [9, 8, 7])
        let all = ScanProgress(collectsFound: true, keepsFound: .max)
        all.add(found(ScanProgress.foundLimit + 5))
        #expect(all.drainFound().count == ScanProgress.foundLimit + 5)
    }

    @Test func theSearchIndexHoldsWhatItsLimitAllows() throws {
        let box = try Sandbox()
        for i in 0..<6 { try box.file("d\(i)/big.bin", bytes: 1_100_000) }
        let root = StorageScanner.scan(path: box.path).root
        let cut = ScanIndex(root, limit: 3)
        #expect(cut.truncated && cut.entries.count == 3 && cut.limit == 3)
        let whole = ScanIndex(root, limit: .max)
        #expect(!whole.truncated && whole.entries.count == 13)
    }
}
