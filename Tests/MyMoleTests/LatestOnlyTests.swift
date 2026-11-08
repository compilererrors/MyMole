import Foundation
import Testing

@testable import MyMole

@MainActor
@Suite struct LatestOnlyTests {
    /// Many values sent at once from other threads reach the main actor as
    /// a few deliveries, the last of them the latest value.
    @Test func manyValuesArriveAsTheLatest() async throws {
        var got: [Int] = []
        let relay = LatestOnly<Int>(interval: .milliseconds(20)) { got.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for i in 1...200 { group.addTask { relay.send(i) } }
        }
        relay.send(1_000)
        for _ in 0..<100 where got.last != 1_000 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(got.last == 1_000)
        #expect(got.count < 20)
    }
}
