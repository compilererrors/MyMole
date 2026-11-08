import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor
@Suite struct FileTableSortTests {
    private func fixture(selection: Binding<Set<String>> = .constant([])) -> (FileTable.Coordinator, FileTableView) {
        let view = FileTable(rows: [], columns: [.name, .size], autosave: "synthetic.sort", selection: selection)
        let coordinator = view.makeCoordinator()
        let table = FileTableView()
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        table.dataSource = coordinator
        coordinator.table = table
        return (coordinator, table)
    }

    private func rows(_ prefix: String, count: Int = 20_000) -> [FileRow] {
        (0..<count).map { FileRow(id: "/synthetic/\(prefix)/\($0)", name: "file-\($0)", size: Int64($0)) }
    }

    @Test func largeSortKeepsEarlierRowsUsableAndRestoresSelection() async throws {
        let large = rows("large")
        var selected: Set<String> = [large[123].id]
        let (coordinator, table) = fixture(selection: Binding(get: { selected }, set: { selected = $0 }))
        let earlier = rows("earlier", count: 1)
        coordinator.load(earlier, marks: nil, selection: selected)
        coordinator.load(large, marks: nil, selection: selected)
        #expect(coordinator.shown == earlier)
        let job = try #require(coordinator.sortJob)
        await job.value
        #expect(coordinator.shown.map(\.size) == large.reversed().map(\.size))
        #expect(table.selectedRowIndexes == IndexSet(integer: large.count - 1 - 123))
        #expect(selected == [large[123].id])
        #expect(coordinator.sortJob == nil)
    }

    @Test func newerLargeResultWinsOverASortInFlight() async throws {
        let (coordinator, table) = fixture()
        coordinator.load(rows("old"), marks: nil, selection: [])
        _ = try #require(coordinator.sortJob)
        await Task.yield()
        let newest = rows("new")
        coordinator.load(newest, marks: nil, selection: [])
        await coordinator.sortJob?.value
        #expect(coordinator.shown.map(\.id) == newest.reversed().map(\.id))
        #expect(table.numberOfRows == newest.count)
        #expect(coordinator.sortJob == nil)
    }

    @Test func anEmptyResultSupersedesPendingWorkImmediately() async throws {
        let (coordinator, table) = fixture()
        coordinator.load(rows("old"), marks: nil, selection: [])
        let job = try #require(coordinator.sortJob)
        coordinator.load([], marks: nil, selection: [])
        #expect(coordinator.shown.isEmpty)
        await job.value
        #expect(coordinator.shown.isEmpty && table.numberOfRows == 0)
    }

    @Test func dismantlingPreventsALateSortFromPublishing() async throws {
        let (coordinator, table) = fixture()
        let earlier = rows("earlier", count: 1)
        coordinator.load(earlier, marks: nil, selection: [])
        coordinator.load(rows("old"), marks: nil, selection: [])
        let job = try #require(coordinator.sortJob)
        coordinator.stopSorting()
        await job.value
        #expect(coordinator.shown == earlier && table.numberOfRows == 1)
    }
}
