import Foundation
import Testing

@testable import MyMole

@MainActor @Suite(.serialized) struct LiveRefreshTests {
    @MainActor private final class Gate {
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func open() { waiter?.resume(); waiter = nil }
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test func repeatedEventsCoalesceBehindOneReadAndInactivityPausesPolling() async throws {
        let refresh = LiveRefresh()
        let gate = Gate()
        var calls = 0
        var active = 0
        var maximum = 0
        let observe = Task {
            await refresh.observe(every: .seconds(60)) {
                calls += 1
                active += 1
                maximum = max(maximum, active)
                if calls == 1 { await gate.wait() }
                active -= 1
            }
        }
        defer { gate.open(); observe.cancel() }
        try await until { gate.waiter != nil }
        for _ in 0..<100 { refresh.request() }
        gate.open()
        try await until { calls == 2 && active == 0 }
        #expect(maximum == 1)
        refresh.setEnabled(false)
        for _ in 0..<100 { refresh.request() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls == 2)
        refresh.setEnabled(true)
        try await until { calls == 3 }
        observe.cancel()
        await observe.value
        refresh.request()
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls == 3)
    }

    @Test func reappearingDuringAnOldReadWaitsAndOldCleanupCannotEraseTheNewOwner() async throws {
        let refresh = LiveRefresh()
        let gate = Gate()
        var oldCalls = 0
        var newCalls = 0
        var active = 0
        var maximum = 0
        let first = Task {
            await refresh.observe(every: .seconds(60)) {
                oldCalls += 1
                active += 1
                maximum = max(maximum, active)
                await gate.wait()
                active -= 1
            }
        }
        defer { gate.open(); first.cancel() }
        try await until { gate.waiter != nil }
        first.cancel()
        let second = Task {
            await refresh.observe(every: .seconds(60)) {
                active += 1
                maximum = max(maximum, active)
                newCalls += 1
                active -= 1
            }
        }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(oldCalls == 1 && newCalls == 0)
        gate.open()
        await first.value
        try await until { newCalls == 1 }
        refresh.request()
        try await until { newCalls == 2 }
        #expect(maximum == 1 && oldCalls == 1)
        second.cancel()
        await second.value
    }

    @Test func pollingWaitsForThePreviousReadAndStopsWhenTheViewCloses() async throws {
        let refresh = LiveRefresh()
        var calls = 0
        let observe = Task { await refresh.observe(every: .milliseconds(5)) { calls += 1 } }
        try await until { calls >= 3 }
        observe.cancel()
        await observe.value
        let stoppedAt = calls
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls == stoppedAt)
    }
}
