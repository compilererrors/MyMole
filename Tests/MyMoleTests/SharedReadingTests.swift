import Foundation
import Synchronization
import Testing

@testable import MyMole

@MainActor
@Suite struct SharedReadingTests {
    @Test func requestsAtOnceShareOneReading() async {
        let reads = Atomic<Int>(0)
        let shared = SharedReading<Int> {
            Thread.sleep(forTimeInterval: 0.05)
            return reads.add(1, ordering: .relaxed).newValue
        }
        async let a = shared.value(maxAge: 0)
        async let b = shared.value(maxAge: 0)
        async let c = shared.value(maxAge: 0)
        let values = await [a, b, c]
        #expect(Set(values) == [1] && shared.count == 1)
    }

    @Test func aRecentReadingIsUsedAndAnOlderOneIsTakenAgain() async {
        let reads = Atomic<Int>(0)
        let clock = Mutex(Date(timeIntervalSince1970: 1_000))
        let shared = SharedReading<Int>(now: { clock.withLock { $0 } }) { reads.add(1, ordering: .relaxed).newValue }
        #expect(await shared.value(maxAge: 1) == 1)
        clock.withLock { $0 += 0.5 }
        #expect(await shared.value(maxAge: 1) == 1)
        clock.withLock { $0 += 1 }
        #expect(await shared.value(maxAge: 1) == 2)
        // Asked for now, it's always read.
        #expect(await shared.value(maxAge: 0) == 3)
    }
}
