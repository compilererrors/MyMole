import SwiftUI

/// A Finder-style date criterion: recent, older than, or a custom range.
/// Every list that filters by date uses this one type and control.
struct DateFilter: Hashable, Codable {
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case any, today, week, month, year
        case olderMonth, olderHalfYear, olderYear, olderTwoYears
        case before, after, between
        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: String(localized: "Any Time")
            case .today: String(localized: "Today")
            case .week: String(localized: "Last 7 Days")
            case .month: String(localized: "Last 30 Days")
            case .year: String(localized: "Last 12 Months")
            case .olderMonth: String(localized: "Older than 1 Month")
            case .olderHalfYear: String(localized: "Older than 6 Months")
            case .olderYear: String(localized: "Older than 1 Year")
            case .olderTwoYears: String(localized: "Older than 2 Years")
            case .before: String(localized: "Before a Date…")
            case .after: String(localized: "After a Date…")
            case .between: String(localized: "Between Dates…")
            }
        }

        static let groups: [[Preset]] = [
            [.any],
            [.today, .week, .month, .year],
            [.olderMonth, .olderHalfYear, .olderYear, .olderTwoYears],
            [.before, .after, .between],
        ]
    }

    var preset: Preset = .any
    /// The date for Before/After, and the first day for Between.
    var start = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    /// The last day (inclusive) for Between.
    var end = Date.now

    var isActive: Bool { preset != .any }
    var isCustom: Bool { [.before, .after, .between].contains(preset) }

    nonisolated func matches(_ date: Date) -> Bool {
        let cal = Calendar.current
        let now = Date.now
        func ago(_ c: Calendar.Component, _ n: Int) -> Date { cal.date(byAdding: c, value: -n, to: now) ?? now }
        switch preset {
        case .any: return true
        case .today: return date >= cal.startOfDay(for: now)
        case .week: return date >= ago(.day, 7)
        case .month: return date >= ago(.day, 30)
        case .year: return date >= ago(.year, 1)
        case .olderMonth: return date < ago(.month, 1)
        case .olderHalfYear: return date < ago(.month, 6)
        case .olderYear: return date < ago(.year, 1)
        case .olderTwoYears: return date < ago(.year, 2)
        case .before: return date < cal.startOfDay(for: start)
        case .after: return date >= cal.startOfDay(for: start)
        case .between:
            let lo = cal.startOfDay(for: min(start, end))
            let hi = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(start, end))) ?? now
            return date >= lo && date < hi
        }
    }
}

/// The date filter as a menu, with labelled date fields below for a custom range.
struct DateFilterControl: View {
    @Binding var filter: DateFilter
    var label = String(localized: "Modified")
    var showsLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Menu {
                Picker(label, selection: $filter.preset) {
                    ForEach(Array(DateFilter.Preset.groups.enumerated()), id: \.offset) { i, group in
                        if i > 0 { Divider() }
                        ForEach(group) { Text($0.title).tag($0) }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(
                    showsLabel ? (filter.isActive ? "\(label): \(value)" : label) : value,
                    systemImage: "calendar")
            }
            .fixedSize()
            .help("Show only items by the date they last changed")
            if filter.isCustom {
                DSFlow(spacing: DS.Space.sm) {
                    DatePicker(
                        filter.preset == .between ? String(localized: "From") : String(localized: "Date"), selection: $filter.start,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .fixedSize()
                    if filter.preset == .between {
                        DatePicker(String(localized: "To"), selection: $filter.end, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .fixedSize()
                    }
                }
                .frame(width: 260, alignment: .leading)
            }
        }
    }

    private var value: String { filter.preset.title.replacingOccurrences(of: "…", with: "") }
}
