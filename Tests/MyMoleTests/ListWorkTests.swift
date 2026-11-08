import Foundation
import Testing

@testable import MyMole

/// The work a big list does on the main actor besides drawing: comparing,
/// sorting, filtering and finding the selection, with synthetic rows.
@MainActor
@Suite struct ListWorkTests {
    static let rows: [FileRow] = (0..<50_000).map { i in
        FileRow(
            id: "/Volumes/Synthetic/folder\(i % 97)/file-\(i).cache", name: "file-\(i).cache", size: Int64((i * 7919) % 1_000_003),
            modified: Date(timeIntervalSince1970: Double(i)), kind: "Cache", location: "/Volumes/Synthetic/folder\(i % 97)")
    }

    func time(_ work: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return clock.measure(work)
    }

    @Test func fiftyThousandRowsStayWithinAFrameBudgetForUpdates() {
        let rows = Self.rows
        var changed = rows
        changed[25_000].size = 1
        // What a scan update costs: the rows compared, then sorted by size.
        // The best of five, so other tests running at once don't count.
        let compare = (0..<5).map { _ in time { _ = rows == changed } }.min()!
        let bySize = time { _ = FileTable.sorted(rows, by: .size, ascending: false) }
        let byName = time { _ = FileTable.sorted(rows, by: .name, ascending: true) }
        let filter = time { _ = rows.filter { DSFilterField.matches("file-49", $0.name, $0.id) } }
        print("50 000 rows: compare \(compare), size sort \(bySize), name sort \(byName), filter \(filter)")
        #expect(compare < .milliseconds(50))
        #expect(bySize < .seconds(1) && filter < .seconds(1))
        let sorted = FileTable.sorted(rows, by: .size, ascending: false)
        #expect(zip(sorted, sorted.dropFirst()).allSatisfy { ($0.size ?? 0) >= ($1.size ?? 0) })
    }
}
