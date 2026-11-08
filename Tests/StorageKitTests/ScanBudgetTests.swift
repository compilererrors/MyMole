import Foundation
import Synchronization
import Testing

@testable import StorageKit

@Suite struct ScanBudgetTests {
    @Test func noMoreThanTheSlotsRunAtOnce() async {
        let budget = ScanBudget(slots: 2)
        let now = Atomic<Int>(0)
        let most = Atomic<Int>(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await budget.run(background: false) {
                        let n = now.add(1, ordering: .relaxed).newValue
                        _ = most.max(n, ordering: .relaxed)
                        try? await Task.sleep(for: .milliseconds(20))
                        now.subtract(1, ordering: .relaxed)
                    }
                }
            }
        }
        #expect(most.load(ordering: .relaxed) == 2)
        #expect(budget.running == 0 && budget.waiting == 0)
    }

    @Test func aForegroundScanGoesBeforeWaitingBackgroundOnes() async throws {
        let budget = ScanBudget(slots: 1)
        let order = Mutex<[String]>([])
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task {
            await budget.run(background: false) { for await _ in stream { break } }
        }
        try #require(await waitUntil { budget.running == 1 })
        let first = Task { await budget.run(background: true) { order.withLock { $0.append("background") } } }
        try #require(await waitUntil { budget.waiting == 1 })
        let second = Task { await budget.run(background: false) { order.withLock { $0.append("foreground") } } }
        try #require(await waitUntil { budget.waiting == 2 })
        release.yield(())
        release.finish()
        _ = await (hold.value, first.value, second.value)
        #expect(order.withLock { $0 } == ["foreground", "background"])
    }

    @Test func stoppingAQueuedScanDoesNotWaitForOrReleaseAnotherScansSlot() async throws {
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task { await budget.run(background: false) { for await _ in stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let progress = ScanProgress()
        let worked = Atomic<Bool>(false)
        let finished = Atomic<Bool>(false)
        let queued = Task {
            let result = await budget.run(background: true, progress: progress) {
                worked.store(true, ordering: .relaxed)
                return 1
            }
            #expect(result == nil)
            finished.store(true, ordering: .relaxed)
        }
        try #require(await waitUntil { budget.waiting == 1 })
        progress.cancel()
        progress.cancel()
        try #require(await waitUntil { finished.load(ordering: .relaxed) })
        #expect(worked.load(ordering: .relaxed) == false)
        #expect(budget.waiting == 0 && budget.running == 1)
        release.yield(())
        release.finish()
        _ = await (hold.value, queued.value)
        #expect(budget.running == 0)
    }

    @Test func cancellingTheTaskAlsoRemovesItsQueuedScan() async throws {
        let budget = ScanBudget(slots: 1)
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.yield(()); release.finish() }
        let hold = Task { await budget.run(background: false) { for await _ in stream { break } } }
        try #require(await waitUntil { budget.running == 1 })
        let progress = ScanProgress()
        let finished = Atomic<Bool>(false)
        let queued = Task {
            let result = await budget.run(background: false, progress: progress) { 1 }
            #expect(result == nil)
            finished.store(true, ordering: .relaxed)
        }
        try #require(await waitUntil { budget.waiting == 1 })
        queued.cancel()
        try #require(await waitUntil { finished.load(ordering: .relaxed) })
        #expect(progress.isCancelled && budget.waiting == 0 && budget.running == 1)
        release.yield(())
        release.finish()
        _ = await (hold.value, queued.value)
        #expect(budget.running == 0)
    }

    @Test func aScanStoppedBeforeQueuingNeverStarts() async {
        let budget = ScanBudget(slots: 1)
        let progress = ScanProgress()
        progress.cancel()
        let result = await budget.run(background: false, progress: progress) { 1 }
        #expect(result == nil && budget.running == 0 && budget.waiting == 0)
    }

    private func waitUntil(_ ready: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }
}
