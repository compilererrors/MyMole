import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct TableUpdatesTests {
    @Test func editsAreLinearAndDoNotMistakeReordersOrDuplicateIDsForInsertions() throws {
        let ids = (0..<50_000).map { "row-\($0)" }
        var next = ids
        next.remove(at: 12)
        next.insert("new", at: 22)
        let changes = try #require(TableRowChanges.between(ids, next))
        #expect(changes.removed == IndexSet(integer: 12))
        #expect(changes.inserted == IndexSet(integer: 22))
        #expect(TableRowChanges.between(["a", "b"], ["b", "a"]) == nil)
        #expect(TableRowChanges.between(["a", "a"], ["a"]) == nil)
        #expect(TableRowChanges.between(["a"], ["a", "a"]) == nil)
        #expect(TableRowChanges.between([], ids) == nil)
        #expect(TableRowChanges.between(ids, ids.map { "new-" + $0 }) == nil)
    }

    @Test func removingAndReorderingRowsPreservesTheAnchorSelectionAndHorizontalPosition() throws {
        var selection: Set<String> = ["row-4"]
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let view = FileTable(rows: [], columns: [.name, .size], autosave: "synthetic.anchor", selection: binding)
        let coordinator = view.makeCoordinator()
        let table = FileTableView()
        table.coordinator = coordinator
        table.rowHeight = 40
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.tableColumns[0].width = 900
        table.addTableColumn(NSTableColumn(identifier: .init("size")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        scroll.hasHorizontalScroller = true
        table.configureUserColumns()
        let rows = (0..<200).map { FileRow(id: "row-\($0)", name: "Sample \($0)", size: Int64(200 - $0)) }
        coordinator.load(rows, marks: nil, selection: selection)
        scroll.contentView.scroll(to: NSPoint(x: 180, y: table.rect(ofRow: 80).minY + 7))
        let oldY = table.rect(ofRow: 80).minY - scroll.contentView.bounds.minY
        let x = scroll.contentView.bounds.minX
        coordinator.load(Array(rows.dropFirst(3)), marks: nil, selection: selection)
        let anchorRow = try #require(coordinator.shown.firstIndex { $0.id == "row-80" })
        #expect(abs(table.rect(ofRow: anchorRow).minY - scroll.contentView.bounds.minY - oldY) < 1)
        #expect(scroll.contentView.bounds.minX == x)
        #expect(selection == ["row-4"] && table.selectedRow == 1)
        #expect(table.tableColumns[0].width == 900)
        let reordered = rows.dropFirst(3).map { row -> FileRow in
            var row = row
            row.size = -(row.size ?? 0)
            return row
        }
        coordinator.load(reordered, marks: nil, selection: selection)
        let newAnchorRow = try #require(coordinator.shown.firstIndex { $0.id == "row-80" })
        #expect(abs(table.rect(ofRow: newAnchorRow).minY - scroll.contentView.bounds.minY - oldY) < 1)
        #expect(scroll.contentView.bounds.minX == x && selection == ["row-4"])
        #expect(coordinator.shown[table.selectedRow].id == "row-4")
    }

    @Test func removingTheTopVisibleRowAnchorsItsNextSurvivingNeighbour() throws {
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 8_000))
        let source = Rows()
        table.dataSource = source
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.rowHeight = 40
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        table.reloadData()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 50).minY + 5))
        let offset = table.rect(ofRow: 51).minY - scroll.contentView.bounds.minY
        let anchor = TableScrollAnchor(table) { "row-\($0)" }
        table.reloadData()
        anchor.restore(in: table) { key in
            let i = Int(key.dropFirst(4))!
            return i == 50 ? nil : i > 50 ? i - 1 : i
        }
        #expect(abs(table.rect(ofRow: 50).minY - scroll.contentView.bounds.minY - offset) < 1)
    }

    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 200 }
    }

    @Test(arguments: [Density.compact, .spacious]) func restoringAnUnscrolledTablePreservesItsNativeHeaderInset(_ density: Density) throws {
        let previous = Density.current
        defer { Density.current = previous }
        Density.current = density
        let table = FileTableView()
        table.style = DS.Table.style
        table.configureRows(height: DS.Table.row)
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        let source = Rows()
        table.dataSource = source
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = table
        scroll.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        table.reloadData()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -28))
        let top = scroll.contentView.bounds.minY
        try #require(top < 0)
        let anchor = TableScrollAnchor(table) { "row-\($0)" }
        table.reloadData()
        anchor.restore(in: table) { Int($0.dropFirst(4)) }
        #expect(abs(scroll.contentView.bounds.minY - top) < 0.5)
    }

    @Test(arguments: [Density.compact, .spacious]) func fileRowsStartAtTheirFinalHeightAndStayThereWhenSizesArrive(_ density: Density) throws {
        let previous = Density.current
        defer { Density.current = previous }
        Density.current = density
        let view = FileTable(rows: [], columns: [.name, .size], autosave: "synthetic.first-layout", selection: .constant([]))
        let coordinator = view.makeCoordinator()
        let table = FileTableView()
        table.style = DS.Table.style
        table.configureRows(height: DS.Table.row)
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 260
        table.addTableColumn(name)
        table.addTableColumn(NSTableColumn(identifier: .init("size")))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
        scroll.documentView = table
        table.configureUserColumns()
        for measured in [false, true] {
            let rows = (0..<50).map { FileRow(id: "sample-\($0)", name: "Sample item \($0)", size: measured ? Int64($0) : nil, subtitle: "Why this item was found") }
            coordinator.load(rows, marks: nil, selection: [])
            table.layoutSubtreeIfNeeded()
            for index in 0..<6 {
                let rect = table.rect(ofRow: index)
                #expect(rect.height == DS.Table.row)
                let cell = try #require(table.view(atColumn: 0, row: index, makeIfNecessary: true))
                cell.layoutSubtreeIfNeeded()
                #expect(cell.frame.height <= rect.height)
                for label in cell.subviews.compactMap({ $0 as? NSTextField }) where !label.isHidden {
                    #expect(label.frame.minY >= -0.5 && label.frame.maxY <= cell.bounds.height + 0.5)
                }
            }
        }
    }
}
