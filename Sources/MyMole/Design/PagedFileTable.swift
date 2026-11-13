import AppKit
import StorageKit
import SwiftUI

/// The file table for a result kept on disk (`SpillTable`), used once a
/// result is past its memory budget. Only the order of the rows is in
/// memory, four bytes each; a row is read from disk as it scrolls into
/// view. Sorting and filtering run off the main thread against the table
/// and replace the order once done; a newer request supersedes an older one,
/// so a stale order is never shown. Cells, rows, lines and menus are
/// `FileTable`'s own.
struct PagedFileTable: NSViewRepresentable {
    let table: SpillTable
    var columns: [FileColumn]
    var hiddenByDefault: Set<FileColumn> = []
    var autosave: String
    /// What the rows are filtered with; a change orders the table again.
    var filterKey: AnyHashable
    var keep: @Sendable (SpillTable.Row) -> Bool
    @Binding var selection: Set<String>
    /// Marked paths; nil hides the checkboxes.
    var marks: Set<String>?
    var onToggleMark: (SpillTable.Row) -> Void = { _ in }
    var onOpen: ([String]) -> Void = { _ in }
    var menu: ([String]) -> [TableMenuEntry] = { FileActions.inspectionMenu($0) }
    /// The rows shown now, in order, once an ordering is done.
    var onOrdered: ([UInt32]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        NativeListViewport.size(proposal)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = NSTableView()
        view.style = DS.Table.style
        view.configureRows(height: DS.Table.row)
        view.apply(context.environment.palette, lines: context.environment.tableLines, stripes: true)
        view.allowsMultipleSelection = true
        view.allowsColumnReordering = true
        view.allowsColumnResizing = true
        view.columnAutoresizingStyle = .noColumnAutoresizing
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = c.title
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: c.ascendingFirst)
            col.isHidden = hiddenByDefault.contains(c)
            view.addTableColumn(col)
        }
        view.persistColumns(as: autosave + ".paged")
        if view.sortDescriptors.isEmpty { view.sortDescriptors = [NSSortDescriptor(key: FileColumn.size.rawValue, ascending: false)] }
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.target = context.coordinator
        view.doubleAction = #selector(Coordinator.doubleClicked)
        let menu = NSMenu()
        menu.delegate = context.coordinator
        view.menu = menu
        context.coordinator.view = view
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.reorder()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let changed = c.parent.table !== table || c.parent.filterKey != filterKey
        let marksChanged = c.parent.marks != marks
        c.parent = self
        if changed { c.reorder() }
        if marksChanged { c.view?.reloadData(forRowIndexes: c.visibleRows, columnIndexes: IndexSet(integer: 0)) }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: PagedFileTable
        weak var view: NSTableView?
        private(set) var order: [UInt32] = []
        private var generation = 0
        private var job: Task<Void, Never>?
        private var syncing = false

        init(_ parent: PagedFileTable) { self.parent = parent }

        var visibleRows: IndexSet {
            guard let view else { return [] }
            let r = view.rows(in: view.visibleRect)
            return IndexSet(integersIn: r.location ..< r.location + r.length)
        }

        /// Orders the table again for the current sort and filter. The
        /// selection is carried over by path, found while ordering.
        func reorder() {
            generation += 1
            let run = generation
            job?.cancel()
            let descriptor = view?.sortDescriptors.first
            let column = descriptor.flatMap { $0.key }.flatMap(FileColumn.init) ?? .size
            let ascending = descriptor?.ascending ?? false
            let (table, keep, selected) = (parent.table, parent.keep, parent.selection)
            let sortOrder: SpillTable.Order =
                switch column {
                case .name: .name
                case .modified: .modified
                case .kind: .kind
                case .location: .folder
                default: .size
                }
            job = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> ([UInt32], IndexSet)? in
                    guard let order = table.ordered(by: sortOrder, ascending: ascending, keep: keep, stop: { Task.isCancelled }) else { return nil }
                    guard !selected.isEmpty else { return (order, []) }
                    var rows = IndexSet()
                    for (i, n) in order.enumerated() {
                        if Task.isCancelled { return nil }
                        if let row = table.row(at: Int(n)), selected.contains(row.path) { rows.insert(i) }
                    }
                    return (order, rows)
                }.value
                guard let self, run == generation, let (order, rows) = result else { return }
                install(order, selecting: rows)
            }
        }

        private func install(_ order: [UInt32], selecting rows: IndexSet) {
            self.order = order
            guard let view else { return }
            syncing = true
            view.reloadData()
            view.selectRowIndexes(rows, byExtendingSelection: false)
            syncing = false
            parent.onOrdered(order)
        }

        func row(_ index: Int) -> SpillTable.Row? {
            guard index >= 0, index < order.count else { return nil }
            return parent.table.row(at: Int(order[index]))
        }

        private func fileRow(_ r: SpillTable.Row) -> FileRow {
            FileRow(id: r.path, name: r.name, size: r.size, modified: r.modified,
                    kind: r.isFolder ? String(localized: "Folder") : r.kind.title, location: r.folder,
                    symbol: r.isFolder ? "folder.fill" : r.kind.symbol)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let col = FileColumn(rawValue: id.rawValue), let spilled = self.row(row) else { return nil }
            let r = fileRow(spilled)
            if col == .name {
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileNameCell ?? FileNameCell(identifier: id)
                cell.configure(r, marked: parent.marks.map { $0.contains(r.id) }, dimUnmeasured: false) { [weak self] in
                    self?.parent.onToggleMark(spilled)
                }
                return cell
            }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileTextCell ?? FileTextCell(identifier: id)
            cell.configure(r, column: col)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LinedRowView.make(in: tableView) }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reorder() }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let view else { return }
            let ids = Set(view.selectedRowIndexes.compactMap { row($0)?.path })
            if ids != parent.selection { parent.selection = ids }
        }

        @objc func doubleClicked() {
            guard let view, let r = row(view.clickedRow) else { return }
            parent.onOpen([r.path])
        }

        /// The rows a menu is for: the selection, or the clicked row outside it.
        private func targets(clicked: Int) -> [String] {
            guard let view else { return [] }
            if clicked >= 0, !view.selectedRowIndexes.contains(clicked) { return row(clicked).map { [$0.path] } ?? [] }
            return view.selectedRowIndexes.compactMap { row($0)?.path }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let view else { return }
            add(parent.menu(targets(clicked: view.clickedRow)), to: menu)
        }

        private func add(_ entries: [TableMenuEntry], to menu: NSMenu) {
            for e in entries {
                switch e {
                case .action(let title, let run): menu.addItem(ClosureMenuItem(title, run))
                case .quickLook: continue
                case .divider:
                    if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
                case .submenu(let title, let children):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let sub = NSMenu(title: title)
                    add(children, to: sub)
                    item.submenu = sub
                    menu.addItem(item)
                }
            }
            if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        }
    }
}
