import AppKit
import SwiftUI

/// The lines between a table's rows and columns, chosen in Settings. Lines
/// tell the rows apart, so the stripes go; without lines, file lists keep
/// the system's stripes.
enum TableLines: String, CaseIterable, Identifiable {
    case none, rows, grid

    static let key = "appearance.tableLines"
    static let standard = TableLines.grid

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .rows: String(localized: "Rows")
        case .grid: String(localized: "Grid")
        }
    }
}

private struct TableLinesKey: EnvironmentKey {
    static let defaultValue = TableLines.standard
}

extension EnvironmentValues {
    /// Set once at the root; a change redraws the tables' rows, nothing is made again.
    var tableLines: TableLines {
        get { self[TableLinesKey.self] }
        set { self[TableLinesKey.self] = newValue }
    }
}

/// A table whose rows draw its lines (`LinedRowView`).
@MainActor protocol LinedTable: NSTableView {
    var lines: TableLines { get set }
    var lineColor: NSColor { get set }
}

/// A row that draws its table's lines: a hairline under it and, in a grid,
/// one after every column but the last. They span the columns, not the
/// margins of an inset table. A selected row draws none, and the row above
/// it leaves out its hairline, so a selection keeps clean edges.
final class LinedRowView: NSTableRowView {
    private static let id = NSUserInterfaceItemIdentifier("row")

    /// A row of `table`, reused when one is spare.
    static func make(in table: NSTableView) -> LinedRowView {
        if let row = table.makeView(withIdentifier: id, owner: nil) as? LinedRowView { return row }
        let row = LinedRowView()
        row.identifier = id
        return row
    }

    override var isNextRowSelected: Bool {
        didSet { if isNextRowSelected != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let table = superview as? LinedTable, table.lines != .none, !isSelected else { return }
        let shown = table.tableColumns.indices.filter { !table.tableColumns[$0].isHidden }
        guard let first = shown.first, let last = shown.last else { return }
        let left = table.rect(ofColumn: first).minX - frame.minX
        let right = table.rect(ofColumn: last).maxX - frame.minX
        table.lineColor.setFill()
        if !isNextRowSelected {
            NSRect(x: left, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: right - left, height: 1).fill(using: .sourceOver)
        }
        // A heading spans the row: no column crosses it.
        guard table.lines == .grid, !isGroupRowStyle else { return }
        for x in table.columnLines { NSRect(x: x - frame.minX, y: bounds.minY, width: 1, height: bounds.height).fill(using: .sourceOver) }
    }
}

extension LinedTable {
    /// Where a grid's column lines run: the last point of every shown column
    /// but the last, which is where the header draws its own dividers.
    var columnLines: [CGFloat] {
        tableColumns.indices.filter { !tableColumns[$0].isHidden }.dropLast().map { rect(ofColumn: $0).maxX.rounded(.down) - 1 }
    }

    /// A grid's column lines across the margin an inset table leaves above
    /// its first row, so they reach the header.
    func drawColumnLinesAboveRows(in clip: NSRect) {
        guard lines == .grid, numberOfRows > 0 else { return }
        let top = rect(ofRow: 0).minY
        guard top > 0, clip.minY < top else { return }
        lineColor.setFill()
        for x in columnLines { NSRect(x: x, y: 0, width: 1, height: top).fill(using: .sourceOver) }
    }
}

extension NSTableView {
    /// The theme's surface and the table's lines: the system's own surface,
    /// with its row stripes when `stripes` and no lines are drawn, or a
    /// themed family's workspace colour. Columns stand further apart in a
    /// grid, so text keeps clear of the line between them.
    func apply(_ palette: Palette, lines: TableLines, stripes: Bool) {
        let native = palette.family == .native
        let alternating = stripes && native && lines == .none
        if usesAlternatingRowBackgroundColors != alternating { usesAlternatingRowBackgroundColors = alternating }
        let background: NSColor = native ? .controlBackgroundColor : palette.workspace.ns
        if backgroundColor != background { backgroundColor = background }
        let gap = NSSize(width: DS.Table.columnGap(lines), height: 0)
        if intercellSpacing != gap {
            intercellSpacing = gap
            fitFlexibleColumn(FileColumn.name.rawValue)
        }
        guard let lined = self as? LinedTable else { return }
        let color = palette.separator.ns
        guard lined.lines != lines || lined.lineColor != color else { return }
        lined.lines = lines
        lined.lineColor = color
        enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
    }
}
