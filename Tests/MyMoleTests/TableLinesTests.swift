import AppKit
import Testing

@testable import MyMole

/// Where the tables' lines and an outline's disclosure arrows sit.
@MainActor
@Suite struct TableLinesTests {
    private func column(_ id: String, width: CGFloat) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.width = width
        return c
    }

    @Test func aGridsColumnLinesSitWhereTheHeaderDrawsItsDividers() throws {
        let table = FileTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        for (id, width) in [("name", 200), ("size", 80), ("kind", 80)] as [(String, CGFloat)] { table.addTableColumn(column(id, width: width)) }
        table.lines = .grid
        let header = try #require(table.headerView)
        #expect(table.columnLines == [0, 1].map { header.headerRect(ofColumn: $0).maxX - 1 })

        // A hidden column takes its line with it; the last shown column never has one.
        table.tableColumns[1].isHidden = true
        #expect(table.columnLines == [header.headerRect(ofColumn: 0).maxX - 1])
    }

    @Test func columnsStandFurtherApartInAGrid() {
        #expect(DS.Table.columnGap(.none) == DS.Table.columnGap)
        #expect(DS.Table.columnGap(.rows) == DS.Table.columnGap)
        #expect(DS.Table.columnGap(.grid) > DS.Table.columnGap)
    }

    /// A heading with a folder under it, and a file in the folder.
    private final class Tree: NSObject, NSOutlineViewDataSource {
        let heading: NSString = "heading"
        let folder: NSString = "folder"
        let file: NSString = "file"

        private func children(_ item: Any?) -> [NSString] {
            switch item as? NSString {
            case nil: [heading]
            case heading: [folder]
            case folder: [file]
            default: []
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(item)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !children(item).isEmpty }
    }

    @Test func anArrowHasItsSlotAndAChildStepsInByOne() {
        let outline = FootprintOutlineView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let name = column("name", width: 300)
        outline.addTableColumn(name)
        outline.outlineTableColumn = name
        outline.indentationPerLevel = DS.Table.indent
        let tree = Tree()
        outline.dataSource = tree
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        let (folder, file) = (outline.row(forItem: tree.folder), outline.row(forItem: tree.file))
        #expect(folder == 1 && file == 2)

        // Under a heading a row starts at the column's edge: the arrow's slot, a gap, then the cell.
        let arrow = outline.frameOfOutlineCell(atRow: folder)
        let cell = outline.frameOfCell(atColumn: 0, row: folder)
        #expect(arrow.minX == outline.rect(ofColumn: 0).minX + outline.intercellSpacing.width / 2)
        #expect(arrow.width == DS.Table.disclosure)
        #expect(cell.minX == arrow.maxX + DS.Table.disclosureGap)

        // A row that doesn't open keeps the slot, one level in: under its parent's cell.
        #expect(outline.frameOfOutlineCell(atRow: file).isEmpty)
        #expect(outline.frameOfCell(atColumn: 0, row: file).minX == cell.minX + DS.Table.indent)
    }
}
