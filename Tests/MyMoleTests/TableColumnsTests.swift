import AppKit
import SwiftUI
import Testing

@testable import MyMole

@MainActor @Suite struct TableColumnsTests {
    @Test func filterHeightTracksStateChangesInsideTheHostedForm() async throws {
        let state = FilterHeightState()
        let scroll = FilterBodyScroll(frame: NSRect(x: 0, y: 0, width: 340, height: 360))
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        window.orderBack(nil)
        scroll.content = AnyView(ChangingFilterHeight(state: state))
        scroll.invalidateContent()
        #expect(abs(scroll.contentHeight(width: 340) - 120) < 1)
        state.expanded = true
        try await Task.sleep(for: .milliseconds(30))
        scroll.layoutSubtreeIfNeeded()
        #expect(abs(scroll.contentHeight(width: 340) - 600) < 1)
        state.expanded = false
        try await Task.sleep(for: .milliseconds(30))
        scroll.layoutSubtreeIfNeeded()
        #expect(abs(scroll.contentHeight(width: 340) - 120) < 1)
    }

    @Test(arguments: [120.0, 600.0]) func filterBodyFitsShortFormsAndCapsLongForms(_ height: Double) {
        let view = NSHostingView(rootView: DSFilterBody { Color.clear.frame(height: height) }.frame(width: 340))
        #expect(abs(view.fittingSize.height - min(height, 360)) < 1)
    }

    private final class Source: NSObject, NSTableViewDataSource {
        var reads = 0
        func numberOfRows(in tableView: NSTableView) -> Int { reads += 1; return 50_000 }
    }

    private func invoke(_ title: String, in menu: NSMenu) throws {
        let item = try #require(menu.items.first { $0.title == title })
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        _ = target.perform(action)
    }

    @Test(arguments: [0, 1, 2]) func columnsAreConsistentWithoutReadingRowsOrChangingOrderAndWidths(_ type: Int) throws {
        let table: NSTableView = type == 0 ? FileTableView() : type == 1 ? DiskOutlineView() : FootprintOutlineView()
        for name in ["name", "kind", "modified"] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = name == "kind" ? "Version" : name == "name" ? "Name" : "Modified"
            column.width = 280
            column.isHidden = name == "modified"
            table.addTableColumn(column)
        }
        table.configureUserColumns(hiddenByDefault: ["modified"])
        let source = Source()
        table.dataSource = source
        let reads = source.reads
        let header = table.columnVisibilityMenu()
        #expect(header.items.first?.title == "Name" && header.items.first?.state == .on && header.items.first?.isEnabled == false)
        #expect(header.items.contains { $0.title == "Version" })
        try invoke("Version", in: header)
        #expect(table.tableColumns[1].isHidden)
        try invoke(String(localized: "Show All Columns"), in: table.columnVisibilityMenu())
        #expect(table.tableColumns.allSatisfy { !$0.isHidden })
        try invoke(String(localized: "Restore Default Columns"), in: table.columnVisibilityMenu())
        #expect(!table.tableColumns[0].isHidden && !table.tableColumns[1].isHidden && table.tableColumns[2].isHidden)
        #expect(table.tableColumns.map(\.identifier.rawValue) == ["name", "kind", "modified"])
        #expect(table.tableColumns.allSatisfy { $0.width == 280 })
        #expect(source.reads == reads)
    }

    @Test func buttonFindsOnlyItsOwnVisibleTableAndEmptyTablesKeepColumnAccess() throws {
        let root = NSView()
        let first = FileTableView(), second = FileTableView()
        first.autosaveName = "synthetic.first"
        second.autosaveName = "synthetic.second"
        root.addSubview(first)
        root.addSubview(second)
        #expect(TableColumnsButton.table(in: root, scope: "synthetic.second") === second)
        first.isHidden = true
        #expect(TableColumnsButton.table(in: root, scope: "synthetic.first") == nil)
        #expect(TableColumnsButton.table(in: root, scope: "synthetic.missing") == nil)
        let view = FileTable(rows: [], columns: [.name, .size], autosave: "synthetic.empty", selection: .constant([]))
        let coordinator = view.makeCoordinator()
        coordinator.table = second
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        #expect(menu.items.last?.title == String(localized: "Columns") && menu.items.last?.submenu != nil)
        #expect(coordinator.keyboardMenu().items.last?.submenu != nil)
    }
}

@MainActor @Observable private final class FilterHeightState {
    var expanded = false
}

private struct ChangingFilterHeight: View {
    let state: FilterHeightState
    var body: some View { Color.clear.frame(height: state.expanded ? 600 : 120) }
}
