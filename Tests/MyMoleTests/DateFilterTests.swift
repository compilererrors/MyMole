import Foundation
import Testing

@testable import MyMole

@Suite struct DateFilterTests {
    private let cal = Calendar.current
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func anyTimeMatchesEverything() {
        #expect(DateFilter().matches(.distantPast))
        #expect(DateFilter().matches(.now))
    }

    @Test func beforeAndAfterSplitAtStartOfDay() {
        var f = DateFilter(preset: .before, start: day(2026, 3, 10))
        #expect(f.matches(day(2026, 3, 9, 23)))
        #expect(!f.matches(day(2026, 3, 10, 0)))
        f.preset = .after
        #expect(f.matches(day(2026, 3, 10, 0)))
        #expect(!f.matches(day(2026, 3, 9, 23)))
    }

    @Test func betweenIncludesBothDaysInEitherOrder() {
        let f = DateFilter(preset: .between, start: day(2026, 3, 20), end: day(2026, 3, 10))
        #expect(f.matches(day(2026, 3, 10, 0)))
        #expect(f.matches(day(2026, 3, 20, 23)))
        #expect(!f.matches(day(2026, 3, 21, 0)))
        #expect(!f.matches(day(2026, 3, 9, 23)))
    }

    @Test func olderThanAndRecentPresets() {
        let old = cal.date(byAdding: .month, value: -8, to: .now)!
        #expect(DateFilter(preset: .olderHalfYear).matches(old))
        #expect(!DateFilter(preset: .olderYear).matches(old))
        #expect(!DateFilter(preset: .month).matches(old))
        #expect(DateFilter(preset: .today).matches(.now))
        // A folder with nothing in it (no date) only counts as old.
        #expect(DateFilter(preset: .olderTwoYears).matches(.distantPast))
        #expect(!DateFilter(preset: .week).matches(.distantPast))
    }
}
