import Foundation
import Synchronization
import Testing

@testable import MyMole

@MainActor @Suite struct DiskAccessMonitorTests {
    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    @Test func noHomeScopeMeansNoProbeAndAHomeGrantChecksOffTheMainThread() async {
        let calls = Mutex(0)
        let monitor = DiskAccessMonitor {
            #expect(!Thread.isMainThread)
            calls.withLock { $0 += 1 }
            return .granted
        }
        monitor.request(scope: nil)
        #expect(!monitor.hasResult && !monitor.checking && calls.withLock { $0 } == 0)
        await monitor.request(scope: 1)?.value
        #expect(monitor.hasResult && monitor.state == .granted && !monitor.checking)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func activationAndPollingShareOneProbeAndTheNextCheckFindsAGrant() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        let granted = Mutex(false)
        let calls = Mutex(0)
        defer { gate.signal() }
        let monitor = DiskAccessMonitor {
            let call = calls.withLock { $0 += 1; return $0 }
            let state: FullDiskAccess.State = granted.withLock { $0 } ? .granted : .denied
            if call == 1 { started.withLock { $0 = true }; _ = gate.wait(timeout: .now() + 5) }
            return state
        }
        let first = monitor.request(scope: 1)
        try #require(await wait { started.withLock { $0 } })
        for _ in 0..<100 { monitor.request(scope: 1) }
        #expect(calls.withLock { $0 } == 1 && monitor.checking)
        gate.signal()
        await first?.value
        #expect(monitor.state == .denied && monitor.hasResult)
        granted.withLock { $0 = true }
        await monitor.request(scope: 1)?.value
        #expect(monitor.state == .granted && calls.withLock { $0 } == 2)
    }

    @Test func anOldScopeCannotPublishAfterAChangedFolderGrant() async throws {
        let gate = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        defer { gate.signal() }
        let monitor = DiskAccessMonitor {
            let call = calls.withLock { $0 += 1; return $0 }
            if call == 1 { _ = gate.wait(timeout: .now() + 5); return .denied }
            return .granted
        }
        var published: [FullDiskAccess.State] = []
        monitor.didChange = { published.append(monitor.state) }
        let first = monitor.request(scope: 1)
        try #require(await wait { calls.withLock { $0 } == 1 })
        let latest = monitor.request(scope: 2)
        #expect(!monitor.hasResult && monitor.checking)
        gate.signal()
        await first?.value
        await latest?.value
        #expect(published == [.granted] && monitor.hasResult && monitor.state == .granted)
        #expect(calls.withLock { $0 } == 2)
        monitor.didChange = nil
    }

    @Test func revocationDiscardsAProbeStillRunning() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = Mutex(false)
        defer { gate.signal() }
        let monitor = DiskAccessMonitor {
            started.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 5)
            return .granted
        }
        let first = monitor.request(scope: 1)
        try #require(await wait { started.withLock { $0 } })
        monitor.request(scope: nil)
        gate.signal()
        await first?.value
        #expect(!monitor.hasResult && !monitor.checking && monitor.state == .unknown)
    }
}
