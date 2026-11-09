import AppKit

@MainActor protocol ColumnWidthProviding {
    var preferredColumnWidth: CGFloat { get }
}

extension NSTableView {
    func configureUserColumns(hiddenByDefault: Set<String> = []) {
        (self as? any UserColumnTable)?.defaultHiddenColumns = hiddenByDefault
        tableColumn(withIdentifier: .init(FileColumn.name.rawValue))?.isHidden = false
        allowsColumnResizing = true
        allowsColumnReordering = true
        columnAutoresizingStyle = .noColumnAutoresizing
        for column in tableColumns {
            column.resizingMask = .userResizingMask
            if let field = FileColumn(rawValue: column.identifier.rawValue) { column.maxWidth = field.width.max }
        }
        enclosingScrollView?.hasHorizontalScroller = true
        headerView?.toolTip = String(localized: "Drag column dividers to resize. Double-click a divider to fit visible contents. Right-click a heading to show or hide columns. Scroll sideways or hover to read full text.")
    }

    /// Fill unused space without shrinking any user-chosen column width.
    func fitFlexibleColumn(_ id: String) {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.width > 0,
              let flexible = tableColumn(withIdentifier: .init(id)), !flexible.isHidden else { return }
        let extra = clip.bounds.width - columnsWidth
        if extra > 0.5 { flexible.width = min(flexible.maxWidth, flexible.width + extra) }
        updateScrollableWidth()
    }

    private var columnsWidth: CGFloat {
        let visible = tableColumns.indices.filter { !tableColumns[$0].isHidden }
        guard let first = visible.first, let last = visible.last else { return 0 }
        return rect(ofColumn: last).maxX + rect(ofColumn: first).minX
    }

    func updateScrollableWidth() {
        let width = max(enclosingScrollView?.contentView.bounds.width ?? 0, columnsWidth)
        if abs(frame.width - width) > 0.5 { setFrameSize(NSSize(width: width, height: frame.height)) }
    }

    /// Use existing visible views only: never enumerate a large data source,
    /// make offscreen cells, or read the filesystem from a header action.
    func visibleContentWidth(of index: Int) -> CGFloat {
        guard tableColumns.indices.contains(index) else { return 0 }
        let column = tableColumns[index]
        var width = (column.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 32
        let visible = rows(in: visibleRect)
        var sampled = 0
        enumerateAvailableRowViews { row, number in
            guard sampled < 256, NSLocationInRange(number, visible),
                  let cell = row.view(atColumn: index) as? any ColumnWidthProviding else { return }
            sampled += 1
            let indent = max(0, frameOfCell(atColumn: index, row: number).minX - rect(ofColumn: index).minX)
            width = max(width, cell.preferredColumnWidth + indent)
        }
        return min(column.maxWidth, max(column.minWidth, ceil(width)))
    }

    func addColumnWidthActions(to menu: NSMenu) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(String(localized: "Fit Visible Contents")) { [weak self] in
            guard let self else { return }
            for (index, column) in tableColumns.enumerated() where !column.isHidden { column.width = visibleContentWidth(of: index) }
            updateScrollableWidth()
        })
        menu.addItem(ClosureMenuItem(String(localized: "Reset Column Widths")) { [weak self] in
            guard let self else { return }
            for column in tableColumns {
                if let field = FileColumn(rawValue: column.identifier.rawValue) { column.width = field.width.ideal }
            }
            fitFlexibleColumn(FileColumn.name.rawValue)
        })
    }

    static func stopFitting(_ observers: inout [NSObjectProtocol]) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// Viewport growth may fill the name column; manual drags never trigger
    /// a fit or take width away from another column.
    func keepFitting(_ id: String) -> [NSObjectProtocol] {
        guard let clip = enclosingScrollView?.contentView else { return [] }
        let state = ColumnViewport(table: self, id: id)
        clip.postsFrameChangedNotifications = true
        DispatchQueue.main.async { state.resized() }
        return [
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { _ in
                MainActor.assumeIsolated { state.resized() }
            },
            NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateScrollableWidth() }
            },
        ]
    }
}

@MainActor private final class ColumnViewport {
    weak var table: NSTableView?
    let id: String
    private var width: CGFloat = -1

    init(table: NSTableView, id: String) { self.table = table; self.id = id }
    func resized() {
        guard let table, let current = table.enclosingScrollView?.contentView.bounds.width, abs(width - current) > 0.5 else { return }
        width = current
        table.fitFlexibleColumn(id)
    }
}
