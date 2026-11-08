import Foundation
import Synchronization
import SystemKit
import Testing

@testable import MyMole

/// When MyMole notifies, with a clock and preferences of the test's own.
@MainActor
@Suite struct WatchTests {
    private let gb: Int64 = 1_000_000_000
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aBigDiskIsNotCalledFullEarly() {
        #expect(Alerts.lowMark(total: 128 * gb) == 12_800_000_000)
        #expect(Alerts.lowMark(total: 500 * gb) == 25 * gb)
        #expect(Alerts.lowMark(total: 4_000 * gb) == 25 * gb)
    }

    @Test func theDiskSaysItOnceUntilThereIsRoomAgainOrAWeekPasses() {
        var alerts = Alerts()
        func low(_ free: Int64, after seconds: TimeInterval, total: Int64 = 500) -> Bool {
            alerts.diskIsLow(free: free * gb, total: total * gb, now: t0 + seconds)
        }
        #expect(!low(60, after: 0))
        #expect(low(20, after: 0))
        // Still low a minute and a day later: said already.
        #expect(!low(19, after: 60))
        #expect(!low(18, after: Alerts.day))
        // Just over the mark isn't room to spare; the next dip isn't news.
        #expect(!low(26, after: 2 * Alerts.day))
        #expect(!low(20, after: 2 * Alerts.day + 60))
        // Low for a week: a reminder.
        #expect(low(20, after: Alerts.week))
        // Room to spare, then low again: news at once.
        #expect(!low(40, after: Alerts.week + 60))
        #expect(low(10, after: Alerts.week + 120))
        #expect(!low(0, after: 0, total: 0))
    }

    @Test func findsAreSaidWeeklyOrWhenTheyGrewByAsMuchAgain() {
        var alerts = Alerts()
        func say(_ largest: Int64, after seconds: TimeInterval) -> Bool {
            alerts.findsAreWorthSaying(largest: largest * gb, now: t0 + seconds)
        }
        #expect(!say(4, after: 0))
        #expect(say(12, after: 0))
        #expect(!say(30, after: 3_600))
        #expect(!say(14, after: 2 * Alerts.day))
        #expect(say(18, after: 2 * Alerts.day))
        #expect(say(18, after: 2 * Alerts.day + Alerts.week))
    }

    /// A reading every minute from `from` through `to`, in minutes after t0.
    private func readings(_ busy: inout BusyProcesses, _ ps: [SystemSnapshot.Process], from: Int, to: Int) -> [String] {
        var said: [String] = []
        for m in from...to { said += busy.observe(ps, now: t0 + Double(m) * 60) }
        return said
    }

    @Test func aProcessIsNamedOnceItHasBeenBusyLongAndOnceADayAtMost() {
        var busy = BusyProcesses()
        let hot = [SystemSnapshot.Process(pid: 1, name: "Renderer", cpu: 99, memoryBytes: 0),
                   SystemSnapshot.Process(pid: 2, name: "kernel_task", cpu: 300, memoryBytes: 0)]
        #expect(readings(&busy, hot, from: 0, to: 9).isEmpty)
        #expect(busy.observe(hot, now: t0 + 10 * 60) == ["Renderer"])
        // Not again the same day, even after a pause and a new busy run.
        #expect(busy.observe([], now: t0 + 11 * 60).isEmpty)
        #expect(readings(&busy, hot, from: 12, to: 30).isEmpty)
        // A dip below the mark starts the run over.
        var other = BusyProcesses()
        _ = other.observe(hot, now: t0)
        _ = other.observe([SystemSnapshot.Process(pid: 1, name: "Renderer", cpu: 20, memoryBytes: 0)], now: t0 + 60)
        #expect(readings(&other, hot, from: 2, to: 11).isEmpty)
        #expect(other.observe(hot, now: t0 + 12 * 60) == ["Renderer"])
    }

    @Test func aRestartedProcessOrAGapIsANewRun() {
        // The same name under another process ID every few minutes: never ten minutes of one process.
        var swapping = BusyProcesses()
        var said: [String] = []
        for m in 0...20 {
            let pid = Int32(100 + m / 4)
            said += swapping.observe([SystemSnapshot.Process(pid: pid, name: "Worker", cpu: 99, memoryBytes: 0)], now: t0 + Double(m) * 60)
        }
        #expect(said.isEmpty)
        // Readings far apart, as across a sleep, don't prove it stayed busy.
        var asleep = BusyProcesses()
        let hot = [SystemSnapshot.Process(pid: 1, name: "Renderer", cpu: 99, memoryBytes: 0)]
        _ = asleep.observe(hot, now: t0)
        #expect(asleep.observe(hot, now: t0 + 11 * 60).isEmpty)
        #expect(readings(&asleep, hot, from: 12, to: 20).isEmpty)
    }

    @Test func anAppInTheTrashIsMentionedOnlyWhenTurnedOnAndItLeftSomething() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = testDefaults(in: dir)
        let posted = Mutex<[Alert]>([])
        let watch = Watch(defaults: defaults, notifier: Notifier(authorize: { true }, post: { a in posted.withLock { $0.append(a) } }))
        await watch.trashedApp("Editor", left: 5_000_000)
        defaults.set(true, forKey: WatchSettings.trashedAppsKey)
        await watch.trashedApp("Editor", left: 0)
        await watch.trashedApp("Editor", left: 5_000_000)
        let alerts = posted.withLock { $0 }
        #expect(alerts.count == 1)
        #expect(alerts.first?.kind == .trashedApp && alerts.first?.title == "Editor is in the Trash")
        // A click opens Uninstall on what removed apps left.
        #expect(alerts.first?.pane == Pane.uninstall.rawValue && alerts.first?.action == Alert.showOrphans)
    }

    @Test func nothingIsPostedUnlessTurnedOnAndTheStateIsKept() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = testDefaults(in: dir)
        let posted = Mutex<[Alert]>([])
        let notifier = Notifier(authorize: { true }, post: { alert in posted.withLock { $0.append(alert) } })
        let watch = Watch(defaults: defaults, notifier: notifier)
        let low = SystemSnapshot.Volume(name: "Disk", mount: "/", total: 500 * gb, available: 12 * gb, isInternal: true)
        let finds: [(pane: Pane, bytes: Int64)] = [(.projects, 48 * gb), (.installer, 3 * gb)]

        await watch.check(low, finds: finds, now: t0)
        await watch.scanned(finds, now: t0)
        #expect(posted.withLock { $0.isEmpty })

        defaults.set(true, forKey: WatchSettings.diskKey)
        defaults.set(true, forKey: WatchSettings.findsKey)
        await watch.check(low, finds: finds, now: t0)
        await watch.scanned(finds, now: t0)
        // A second watch reads what the first one said: nothing is said twice.
        let again = Watch(defaults: defaults, notifier: notifier)
        await again.check(low, finds: finds, now: t0 + 60)
        await again.scanned(finds, now: t0 + 60)

        let alerts = posted.withLock { $0 }
        #expect(alerts.map(\.kind) == [.disk, .finds])
        #expect(alerts[0].pane == Pane.dashboard.rawValue && alerts[0].body.contains("Projects"))
        // Each pane by itself, never a sum; a click opens the pane that found most.
        #expect(alerts[1].pane == Pane.projects.rawValue && alerts[1].body.contains(" · "))
    }
}
