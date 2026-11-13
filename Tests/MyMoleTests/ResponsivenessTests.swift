import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct ResponsivenessTests {
    private let gigabyte: UInt64 = 1 << 30

    @Test func automaticFollowsPowerAndMemory() {
        #expect(Responsiveness.automatic.resolved(lowPower: true, memory: 64 * gigabyte) == .gentle)
        #expect(Responsiveness.automatic.resolved(lowPower: false, memory: 8 * gigabyte) == .gentle)
        #expect(Responsiveness.automatic.resolved(lowPower: false, memory: 16 * gigabyte) == .balanced)
        #expect(Responsiveness.automatic.resolved(lowPower: false, memory: 32 * gigabyte) == .fast)
        // A level chosen by hand is never changed by the Mac's state.
        #expect(Responsiveness.hyperspeed.resolved(lowPower: true, memory: 8 * gigabyte) == .hyperspeed)
        #expect(Responsiveness(rawValue: 99) == nil)
    }

    private func defaults(_ name: String) -> (UserDefaults, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        return (testDefaults(in: dir), dir)
    }

    @Test func nothingSavedMeansMaximumWithSensibleLimits() throws {
        let (defaults, dir) = defaults("responsiveness")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Responsiveness.saved(in: defaults) == .maximum)
        #expect(PerformanceLevel.current(in: defaults) == .full && ResultSize.current(in: defaults) == .maximum)
        defaults.set(Responsiveness.automatic.rawValue, forKey: Responsiveness.defaultsKey)
        #expect(Responsiveness.saved(in: defaults) == .automatic, "Automatic stays when chosen")
        let top = Responsiveness.maximum
        #expect(top.iconLimit == 16_000 && top.chartLayoutLimit == 512)
        let window = top.freshWindow(1_800)
        #expect(window == 300, "Maximum reuses only a result a few minutes old: \(String(describing: window))")
        let unlimited = Responsiveness.hyperspeed
        #expect(unlimited.iconLimit == .max && unlimited.textWidthLimit == .max && unlimited.symbolLimit == .max
            && unlimited.chartLayoutLimit == .max)
        #expect(unlimited.freshWindow(30 * 60) == nil && unlimited.keepsMapAway && unlimited.prewarmsDiskMap)
    }

    @Test func savedValuesFromEveryEarlierBuildEndUpOnTheSixSteps() throws {
        // Before version 2: the middle defaults go to Maximum; turning launch preparation off was a choice.
        var (defaults, dir) = defaults("performance-v1")
        defer { try? FileManager.default.removeItem(at: dir) }
        defaults.set(3, forKey: PerformanceLevel.defaultsKey)
        defaults.set(1, forKey: ResultSize.defaultsKey)
        defaults.set(0, forKey: Responsiveness.defaultsKey)
        defaults.set(false, forKey: LoadingSettings.prefetchKey)
        PerformanceDefaults.migrate(defaults)
        #expect(PerformanceLevel.current(in: defaults) == .full)
        #expect(ResultSize.current(in: defaults) == .maximum)
        #expect(Responsiveness.saved(in: defaults) == .maximum)
        #expect(!LoadingSettings.prefetch(in: defaults))

        // Versions 2 and 3 numbered results Standard, Large, No limit and
        // responsiveness Automatic, Lean, Balanced, Fast, Maximum.
        let renumbered: [(results: Int, responsiveness: Int, size: ResultSize, level: Responsiveness)] = [
            (1, 1, .balanced, .gentle), (2, 2, .maximum, .balanced), (3, 3, .hyperspeed, .fast), (3, 4, .hyperspeed, .maximum),
            (2, 0, .maximum, .automatic),
        ]
        for case let (results, responsiveness, size, level) in renumbered {
            let (d, folder) = self.defaults("performance-v3")
            defer { try? FileManager.default.removeItem(at: folder) }
            d.set(3, forKey: PerformanceDefaults.versionKey)
            d.set(results, forKey: ResultSize.defaultsKey)
            d.set(responsiveness, forKey: Responsiveness.defaultsKey)
            PerformanceDefaults.migrate(d)
            #expect(ResultSize.current(in: d) == size, "results \(results)")
            #expect(Responsiveness.saved(in: d) == level, "responsiveness \(responsiveness)")
        }

        // A choice made after the migration is kept, whatever it is.
        (defaults, dir) = self.defaults("performance-v4")
        defaults.set(PerformanceDefaults.version, forKey: PerformanceDefaults.versionKey)
        defaults.set(Responsiveness.balanced.rawValue, forKey: Responsiveness.defaultsKey)
        PerformanceDefaults.migrate(defaults)
        #expect(Responsiveness.saved(in: defaults) == .balanced)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func memoryReliefStartsOffAndTheMigrationTurnsItOff() throws {
        let (defaults, dir) = defaults("memory-relief")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!MemoryRelief.isOn(in: defaults))
        // A Mac already at version 2: relief goes off, a level chosen since stays.
        defaults.set(2, forKey: PerformanceDefaults.versionKey)
        defaults.set(true, forKey: MemoryRelief.defaultsKey)
        defaults.set(PerformanceLevel.balanced.rawValue, forKey: PerformanceLevel.defaultsKey)
        PerformanceDefaults.migrate(defaults)
        #expect(!MemoryRelief.isOn(in: defaults))
        #expect(PerformanceLevel.current(in: defaults) == .balanced)
        // Turned on afterwards, it stays on.
        defaults.set(true, forKey: MemoryRelief.defaultsKey)
        PerformanceDefaults.migrate(defaults)
        #expect(MemoryRelief.isOn(in: defaults))
    }

    @Test func eachStepUpKeepsMoreAndRepaintsNoLater() {
        let levels: [Responsiveness] = [.gentle, .light, .balanced, .fast, .maximum, .hyperspeed]
        for (lower, higher) in zip(levels, levels.dropFirst()) {
            #expect(lower.iconLimit < higher.iconLimit)
            #expect(lower.textWidthLimit < higher.textWidthLimit)
            #expect(lower.symbolLimit < higher.symbolLimit)
            #expect(lower.chartLayoutLimit < higher.chartLayoutLimit)
            #expect(lower.publishInterval >= higher.publishInterval)
        }
        #expect(!Responsiveness.gentle.keepsMapAway && !Responsiveness.gentle.prewarmsDiskMap)
        #expect(Responsiveness.light.keepsMapAway && Responsiveness.light.prewarmsDiskMap)
        // Balanced holds the earlier limits: the 200 ms repaint, 4,000 icons, 128 charts, the usual fresh window.
        #expect(Responsiveness.balanced.publishInterval == .milliseconds(200) && Responsiveness.balanced.iconLimit == 4_000
            && Responsiveness.balanced.chartLayoutLimit == 128 && Responsiveness.balanced.freshWindow(600) == 600)
        // Lower steps wait longer before preparing a pane again; higher ones less.
        let windows = levels.map { $0.freshWindow(600) ?? 0 }
        #expect(windows == [2_400, 1_200, 600, 300, 100, 0])
    }

    @Test func applyingALevelSetsTheCaches() {
        defer { Responsiveness.apply(.maximum) }
        Responsiveness.apply(.hyperspeed)
        #expect(AppIcons.limit == .max && ChartLayouts.limit == .max)
        Responsiveness.apply(.maximum)
        #expect(AppIcons.limit == 16_000 && ChartLayouts.limit == 512)
        Responsiveness.apply(.gentle)
        #expect(AppIcons.limit == Responsiveness.gentle.iconLimit)
    }

    @Test func layoutsAreKeptNewestFirstAndOnlyForOneMap() {
        let memo = LayoutMemo<Int, String>(limit: 2)
        // Held for the whole test, so the two maps never share an address.
        let maps = (NSObject(), NSObject())
        let map = ObjectIdentifier(maps.0)
        memo.keep("a", for: 1, map: map)
        memo.keep("b", for: 2, map: map)
        #expect(memo.value(1, map: map) == "a")  // 1 is now the newest
        memo.keep("c", for: 3, map: map)
        #expect(memo.value(2, map: map) == nil && memo.value(1, map: map) == "a" && memo.value(3, map: map) == "c")
        // Another map's layouts never come back, and a new map drops the old ones.
        let other = ObjectIdentifier(maps.1)
        #expect(memo.value(1, map: other) == nil)
        memo.keep("x", for: 1, map: other)
        #expect(memo.count == 1 && memo.value(1, map: other) == "x")
        memo.limit = 0
        #expect(memo.count == 0)
    }

    @Test func aLimitOfOneKeepsNoLayouts() {
        let memo = LayoutMemo<Int, String>(limit: 1)
        let owner = NSObject()
        let map = ObjectIdentifier(owner)
        memo.keep("a", for: 1, map: map)
        #expect(memo.value(1, map: map) == nil && memo.count == 0)
    }
}

@MainActor @Suite struct PerformanceSummaryTests {
    @Test func eachStepReadsAsNumbers() {
        #expect(PerformanceSummary.results(.maximum).contains(ByteSize.format(1 << 30)) && PerformanceSummary.results(.maximum).contains("in memory, then disk"))
        #expect(PerformanceSummary.results(.maximum).contains("1 h"))
        #expect(PerformanceSummary.results(.hyperspeed).hasPrefix("Every list in memory"))
        #expect(PerformanceSummary.scans(.hyperspeed).hasPrefix("Any number of scans"))
        #expect(PerformanceSummary.scans(.balanced).hasPrefix("Up to 3 scans at once"))
        #expect(PerformanceSummary.responsiveness(.balanced).contains("200 ms"))
        #expect(PerformanceSummary.responsiveness(.hyperspeed).contains("prepared afresh"))
    }
}
