import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct TableSizingTests {
    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var made = 0
        var rowViews: [LayoutRow] = []
        func numberOfRows(in tableView: NSTableView) -> Int { 50_000 }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = LayoutRow()
            rowViews.append(view)
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            made += 1
            let cell = FileNameCell(identifier: .init("name"))
            cell.configure(FileRow(id: "synthetic-\(row)", name: String(repeating: "Readable ", count: 12), size: 1024), marked: nil, onToggle: {})
            return cell
        }
    }

    private final class LayoutRow: NSTableRowView {
        var layouts = 0
        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    @Test func repeatedWidthUpdatesDeferCellLayoutUntilAppKitFlushes() throws {
        let table = FileTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.configureRows(height: 40)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        scroll.documentView = table
        let rows = Rows()
        table.dataSource = rows
        table.delegate = rows
        table.reloadData()
        _ = try #require(table.rowView(atRow: 0, makeIfNecessary: true))
        table.layoutSubtreeIfNeeded()
        let layouts = rows.rowViews.map(\.layouts)
        let made = rows.made
        for _ in 0..<100 { table.updateScrollableWidth() }
        #expect(rows.rowViews.map(\.layouts) == layouts)
        #expect(rows.made == made)
        table.layoutSubtreeIfNeeded()
        #expect(rows.rowViews.map(\.layouts) != layouts)
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
        #expect(table.headerView?.frame.width == table.frame.width)
        #expect(table.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) && $0.maxWidth >= 4_096 })
    }

    @Test func switchingDensityInPlacePreservesSelectionAndUserColumnWidths() {
        let before = Density.current
        defer { Density.current = before }
        Density.current = .spacious
        var selected: Set<String> = ["sample"]
        let binding = Binding(get: { selected }, set: { selected = $0 })
        let view = FileTable(rows: [], columns: [.name, .size], autosave: "synthetic.density", selection: binding)
        let coordinator = view.makeCoordinator()
        let table = FileTableView()
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.addTableColumn(NSTableColumn(identifier: .init("size")))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = table
        table.configureUserColumns()
        table.tableColumns[0].width = 900
        let column = table.tableColumns[0]
        coordinator.load([FileRow(id: "sample", name: "Sample", size: 1024)], marks: nil, selection: selected)
        for density in [Density.compact, .spacious, .compact, .spacious] {
            Density.current = density
            coordinator.applyDensity(density)
            #expect(table.tableColumns[0] === column && column.width == 900)
            #expect(table.rowHeight == DS.Table.row && table.style == DS.Table.style)
            #expect(selected == ["sample"] && table.selectedRow == 0)
        }
    }

    @Test(arguments: [0, 1, 2]) func transientWideLayoutDoesNotHideColumnsAndOnlyAutomaticFillerRetracts(_ kind: Int) throws {
        let table: NSTableView = kind == 0 ? FileTableView() : kind == 1 ? DiskOutlineView() : FootprintOutlineView()
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 200
        table.addTableColumn(name)
        let size = NSTableColumn(identifier: .init("size"))
        size.width = 100
        table.addTableColumn(size)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 200))
        scroll.documentView = table
        table.configureUserColumns()
        var observers = table.keepFitting("name")
        defer { NSTableView.stopFitting(&observers) }
        let state = try #require((table as? any UserColumnTable)?.columnViewport)
        state.fit()
        #expect(name.width > 1_000)
        scroll.setFrameSize(NSSize(width: 500, height: 200))
        scroll.tile()
        state.fit()
        #expect(name.width >= 200 && name.width < 400)
        #expect(size.width == 100 && table.rect(ofColumn: 1).maxX <= scroll.contentView.bounds.width + 1)
        name.width = 900
        NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: table)
        scroll.setFrameSize(NSSize(width: 1_400, height: 200))
        scroll.tile()
        state.fit()
        #expect(name.width > 1_000)
        scroll.setFrameSize(NSSize(width: 420, height: 200))
        scroll.tile()
        state.fit()
        #expect(name.width == 900 && size.width == 100)
        #expect(table.frame.width > scroll.contentView.bounds.width)
    }

    @Test func savedUserWidthIsDistinctFromTheLastAutomaticallyFilledWidth() throws {
        let box = FileManager.default.temporaryDirectory.appending(path: "table-width-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let defaults = testDefaults(in: box)
        let table = FileTableView()
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 200
        table.addTableColumn(name)
        table.autosaveName = "synthetic.width"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 200))
        scroll.documentView = table
        table.configureUserColumns()
        var observers = table.keepFitting("name", defaults: defaults)
        defer { NSTableView.stopFitting(&observers) }
        let state = try #require(table.columnViewport)
        state.fit()
        #expect(name.width > 1_000)
        #expect(defaults.double(forKey: "table.flexibleWidth.v1.synthetic.width.name") == 200)
        // Native outlines can postpone the end-of-drag notification until
        // after the first viewport event. Fit must recognize the new width.
        NSTableView.stopFitting(&observers)
        name.width = 650
        state.fit()
        #expect(defaults.double(forKey: "table.flexibleWidth.v1.synthetic.width.name") == 650)
        #expect(name.width > 1_000)
        let restored = ColumnViewport(table: table, id: "name", defaults: defaults)
        scroll.setFrameSize(NSSize(width: 420, height: 200))
        scroll.tile()
        restored.fit()
        #expect(name.width == 650)
    }

    /// A window or pane resize fits the name column every frame. That fit
    /// is not the user's choice and writes no setting: each write to the
    /// defaults wakes every stored setting's view in the app, which drew the whole
    /// window anew on every frame of a resize.
    @Test(arguments: [0, 1, 2]) func fittingTheNameColumnWhileResizingWritesNoSetting(kind: Int) throws {
        let box = FileManager.default.temporaryDirectory.appending(path: "table-fit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let defaults = testDefaults(in: box)
        let table: NSTableView = kind == 0 ? FileTableView() : kind == 1 ? DiskOutlineView() : FootprintOutlineView()
        let name = NSTableColumn(identifier: .init("name"))
        name.width = 200
        table.addTableColumn(name)
        let size = NSTableColumn(identifier: .init("size"))
        size.width = 100
        table.addTableColumn(size)
        table.persistColumns(as: "synthetic.fit.\(kind).\(UUID().uuidString)", defaults: defaults)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        scroll.documentView = table
        table.configureUserColumns()
        var observers = table.keepFitting("name", defaults: defaults)
        defer { NSTableView.stopFitting(&observers) }
        let state = try #require((table as? any UserColumnTable)?.columnViewport)
        state.fit()
        var writes = 0
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in writes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        var slack: Set<Int> = []
        for step in 0..<30 {
            scroll.setFrameSize(NSSize(width: 700 + CGFloat(step % 10) * 40, height: 200))
            scroll.tile()
            state.resized()
            slack.insert(Int((scroll.contentView.bounds.width - name.width).rounded()))
        }
        // Each fit fills the viewport and is kept, not undone by saved state.
        #expect(slack.count == 1)
        #expect(writes == 0, "\(writes) settings writes while the viewport resized")
        #expect(defaults.double(forKey: "table.flexibleWidth.v1.\(table.autosaveName ?? "").name") == 200)
    }

    /// The user's columns come back: order, widths and the hidden ones.
    /// The first time, what AppKit's own autosave kept is taken over.
    @Test func aListsColumnsComeBackAsTheUserLeftThem() throws {
        let box = FileManager.default.temporaryDirectory.appending(path: "table-columns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: box) }
        let defaults = testDefaults(in: box)
        func table() -> NSTableView {
            let table = FileTableView()
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for (id, width) in [("name", 200.0), ("size", 100.0), ("kind", 120.0)] {
                let column = NSTableColumn(identifier: .init(id))
                column.width = width
                column.maxWidth = 2_000
                table.addTableColumn(column)
            }
            return table
        }
        let name = "synthetic.columns.\(UUID().uuidString)"
        let first = table()
        first.persistColumns(as: name, defaults: defaults)
        first.tableColumns[1].width = 140
        first.tableColumns[2].isHidden = true
        first.moveColumn(1, toColumn: 0)
        first.columnsChanged()
        let second = table()
        second.persistColumns(as: name, defaults: defaults)
        #expect(second.tableColumns.map(\.identifier.rawValue) == ["size", "name", "kind"])
        #expect(second.tableColumns[0].width == 140 && second.tableColumns[2].isHidden)
        #expect(second.autosaveName == name && !second.autosaveTableColumns)
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
