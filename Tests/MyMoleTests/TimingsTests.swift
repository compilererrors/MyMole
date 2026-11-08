import Foundation
import Testing

@testable import MyMole

@Suite(.serialized) struct TimingsTests {
    @Test func theSummaryGivesMedianP95AndLongestOfTheKeptDurations() {
        Timings.clear()
        defer { Timings.clear() }
        for i in 1...100 { Timings.add(.filter, seconds: Double(i) / 1_000) }
        let s = Timings.summary().first { $0.step == .filter }
        #expect(s?.count == 100)
        #expect(s.map { abs($0.median - 0.0505) < 0.001 } == true)
        #expect(s.map { abs($0.p95 - 0.095) < 0.0015 } == true)
        #expect(s?.longest == 0.1)
        #expect(Timings.text().hasPrefix("filter: 100 ×"))
    }

    @Test func onlyTheNewestDurationsAreKept() {
        Timings.clear()
        defer { Timings.clear() }
        for _ in 0..<(Timings.kept + 50) { Timings.add(.sort, seconds: 0.001) }
        #expect(Timings.summary().first { $0.step == .sort }?.count == Timings.kept)
    }
}
