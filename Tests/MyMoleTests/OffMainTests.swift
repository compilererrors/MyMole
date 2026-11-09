import Foundation
import Synchronization
import Testing

@testable import MyMole

@MainActor
@Suite struct OffMainTests {
    @Test func aSmallListIsWorkedOutAtOnce() async {
        let list = OffMain<[Int]>([])
        await list.update(count: 10) { Array(0..<10) }
        #expect(list.value.count == 10 && !list.working)
    }

    @Test func aLargeListIsWorkedOutOffTheMainThread() async {
        let list = OffMain<Bool>(false)
        await list.update(count: OffMain<Bool>.inline + 1) { !Thread.isMainThread }
        #expect(list.value)
    }

    @Test func aRequestReplacedByANewerOneNeverLands() async {
        let list = OffMain<String>("start")
        let older = Task { @MainActor in
            await list.update(count: 50_000) {
                Thread.sleep(forTimeInterval: 0.2)
                return "older"
            }
        }
        older.cancel()
        await list.update(count: 50_000) { "newer" }
        await older.value
        #expect(list.value == "newer")
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test func oneWorkerRunsOnlyTheNewestPendingRequest() async throws {
        let list = OffMain<String>("initial")
        let gate = DispatchSemaphore(value: 0)
        let starts = Mutex<[String]>([])
        defer { gate.signal() }
        let first = Task {
            await list.update(count: 5_000) {
                starts.withLock { $0.append("first") }
                _ = gate.wait(timeout: .now() + 5)
                return "first"
            }
        }
        try #require(await wait { starts.withLock { !$0.isEmpty } })
        var entered = false
        let replaced = Task {
            entered = true
            await list.update(count: 5_000) { starts.withLock { $0.append("replaced") }; return "replaced" }
        }
        try #require(await wait { entered })
        entered = false
        let latest = Task {
            entered = true
            await list.update(count: 5_000) { starts.withLock { $0.append("latest") }; return "latest" }
        }
        try #require(await wait { entered })
        await replaced.value
        #expect(starts.withLock { $0 } == ["first"])
        #expect(list.value == "initial" && list.working)
        gate.signal()
        await first.value
        await latest.value
        #expect(starts.withLock { $0 } == ["first", "latest"])
        #expect(list.value == "latest" && !list.working)
    }

    @Test func cancellationAndSmallUpdatesDontWaitForAnOldWorker() async throws {
        let list = OffMain<Int>(0)
        let gate = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        defer { gate.signal() }
        let first = Task {
            await list.update(count: 5_000) {
                started.withLock { $0 = true }
                _ = gate.wait(timeout: .now() + 5)
                return 1
            }
        }
        try #require(await wait { started.withLock { $0 } })
        first.cancel()
        await first.value
        #expect(list.value == 0 && !list.working)
        await list.update(count: 1) { 2 }
        gate.signal()
        await list.update(count: 5_000) { 3 }
        #expect(list.value == 3 && !list.working)
    }

    @Test func replacedLargePayloadIsReleasedOffTheMainThread() async throws {
        final class ReleaseState: Sendable { let thread = Mutex<Bool?>(nil) }
        final class Probe: Sendable {
            let state: ReleaseState
            init(_ state: ReleaseState) { self.state = state }
            deinit { state.thread.withLock { $0 = Thread.isMainThread } }
        }
        let released = ReleaseState()
        let list = OffMain<Probe?>(nil)
        await list.update(count: 5_000) { Probe(released) }
        await list.update(count: 1) { nil }
        try #require(await wait { released.thread.withLock { $0 != nil } })
        #expect(released.thread.withLock { $0 } == false)
    }
}
