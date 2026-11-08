import Foundation
import StorageKit
import Testing

@testable import MyMole

@MainActor @Suite struct ComparisonTests {
    let mib: Int64 = 1_048_576

    func scan(_ total: Int64, docs: Int64, incomplete: Bool = false, day: Double = 0) -> Snapshot {
        Snapshot(
            rootPath: "/Users/synthetic", date: Date(timeIntervalSince1970: 86_400 * day),
            sizes: ["": total * mib, "Documents": docs * mib], incomplete: incomplete)
    }

    @Test func twoCompleteScansHaveATotal() {
        let r = StorageModel.comparison(scan(900, docs: 100), scan(1_000, docs: 200, day: 1))
        #expect(r.delta == 100 * mib && r.problem == nil)
        #expect(r.changes.map(\.path) == ["Documents"])
    }

    @Test func anIncompleteScanLeavesTheTotalUnknown() {
        // Complete 900 MiB, then a partial 500 MiB: not a 400 MiB drop.
        let shrink = StorageModel.comparison(scan(900, docs: 400), scan(500, docs: 100, incomplete: true, day: 1))
        #expect(shrink.delta == nil && shrink.problem?.contains("newer scan") == true)
        #expect(shrink.changes.allSatisfy { $0.kind != .shrank && $0.kind != .vanished })
        let grow = StorageModel.comparison(scan(500, docs: 100, incomplete: true), scan(900, docs: 400, day: 1))
        #expect(grow.delta == nil && grow.problem?.contains("older scan") == true)
    }

    @Test func anUnreadableScanIsNotAComparisonToNothing() {
        let r = StorageModel.comparison(nil, scan(900, docs: 100))
        #expect(r.delta == nil && r.changes.isEmpty && r.problem?.contains("couldn't be read") == true)
    }
}
