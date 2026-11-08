import AppKit
import Testing

@testable import MyMole

@MainActor @Suite struct TableSizingTests {
    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var made = 0
        func numberOfRows(in tableView: NSTableView) -> Int { 50_000 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            made += 1
            let cell = FileNameCell(identifier: .init("name"))
            cell.configure(FileRow(id: "synthetic-\(row)", name: String(repeating: "Readable ", count: 12), size: 1024), marked: nil, onToggle: {})
            return cell
        }
    }

    @Test func fittingVisibleTextDoesNotCreateOffscreenRowsInALargeTable() throws {
        let table = FileTableView()
        let column = NSTableColumn(identifier: .init("name"))
        column.minWidth = 120
        column.width = 150
        table.addTableColumn(column)
        table.rowHeight = 40
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.documentView = table
        table.configureUserColumns()
        let rows = Rows()
        table.dataSource = rows
        table.delegate = rows
        table.reloadData()
        _ = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let before = rows.made
        let width = table.visibleContentWidth(of: 0)
        #expect(width > 500)
        #expect(rows.made == before && rows.made < 256)
    }

    @Test(arguments: [0, 1, 2]) func wideningColumnsAndShrinkingTheViewportPreservesReadableWidths(kind: Int) async throws {
        let table: NSTableView = switch kind {
        case 1: DiskOutlineView()
        case 2: FootprintOutlineView()
        default: FileTableView()
        }
        table.frame = NSRect(x: 0, y: 0, width: 720, height: 200)
        table.style = DS.Table.style
        for field in FileColumn.allCases {
            let column = NSTableColumn(identifier: .init(field.rawValue))
            column.minWidth = field.width.min
            column.width = field.width.ideal
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 200))
        scroll.documentView = table
        table.configureUserColumns()
        var observers = table.keepFitting("name")
        defer { NSTableView.stopFitting(&observers) }
        await Task.yield()
        let name = try #require(table.tableColumn(withIdentifier: .init("name")))
        let kind = try #require(table.tableColumn(withIdentifier: .init("kind")))
        name.width = 900
        kind.width = 800
        NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: table)
        #expect(name.width == 900 && kind.width == 800)
        #expect(table.frame.width > scroll.contentView.bounds.width)
        scroll.setFrameSize(NSSize(width: 420, height: 200))
        scroll.tile()
        await Task.yield()
        #expect(name.width == 900 && kind.width == 800)
        #expect(scroll.hasHorizontalScroller && table.allowsColumnResizing)
        #expect(table.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) && $0.maxWidth >= 4_096 })
    }

    @Test func clippedCellsExposeFullTextAndClearItWhenReused() throws {
        let title = "com.example.Editor.background.extension.with.a.long.name"
        let subtitle = "Found by an identity carried by the removed app"
        let kind = "Your data · Sandboxed Application Support"
        let path = "/synthetic/Library/Containers/com.example.Editor/Data/Library"
        let row = FileRow(id: path, name: title, size: 1024, kind: kind, location: path, subtitle: subtitle)
        let name = FileNameCell(identifier: .init("name"))
        name.frame.size = NSSize(width: 120, height: 46)
        name.configure(row, marked: false, onToggle: {})
        name.layoutSubtreeIfNeeded()
        #expect(name.toolTip == title + "\n" + subtitle)
        #expect(name.subviews.compactMap { $0 as? NSTextField }.contains { $0.toolTip == subtitle })
        #expect(name.preferredColumnWidth > name.frame.width)
        let value = FileTextCell(identifier: .init("kind"))
        value.configure(row, column: .kind)
        #expect(value.toolTip == kind)
        value.configure(row, column: .location)
        #expect(value.toolTip == path)
        value.configure(FileRow(id: "empty", name: "Empty"), column: .kind)
        #expect(value.toolTip == nil)
        name.configure(FileRow(id: "next", name: "Next"), marked: nil, onToggle: {})
        #expect(name.toolTip == "Next")
        #expect(!name.subviews.compactMap { $0 as? NSTextField }.contains { $0.toolTip == subtitle })
    }
}
