import AppKit
import Quartz
import SwiftUI

/// One row of a `FileTable`. Every column is optional; a table shows the
/// columns it was given.
struct FileRow: Identifiable, Equatable, Sendable {
    /// The item's identity; file rows use their absolute path.
    let id: String
    var name: String
    /// nil while the item is still being measured ("Scanning…").
    var size: Int64?
    /// Of `size`, what could be removed.
    var freeable: Int64?
    /// Growth since an earlier measurement; negative when it shrank.
    var change: Int64?
    var changeHelp: String?
    var modified: Date?
    var kind: String?
    var items: Int?
    var location: String?
    var symbol = "doc"
    /// A second line under the name, as Mail shows a message's sender: what
    /// would otherwise need columns of its own in a narrow table.
    var subtitle: String?
    var tint: NSColor?
    var badge: String?
    var badgeHelp: String?
    /// Green unless the badge says something else than "fine".
    var badgeTint: NSColor?
    var locked = false
    /// A measured item may still be protected or required in this review.
    var canChoose = true
    var reviewBeforeChoosing = false
    /// A retained duplicate can still be chosen individually, but bulk choice keeps it.
    var bulkCheckable = true
    var choiceHelp: String?
    var sizePlaceholder: String?
}

enum FileColumn: String, CaseIterable, Sendable {
    case name, size, change, freeable, modified, kind, items, location

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .size: String(localized: "Size")
        case .change: String(localized: "Change")
        case .freeable: String(localized: "Removable")
        case .modified: String(localized: "Modified")
        case .kind: String(localized: "Kind")
        case .items: String(localized: "Items")
        case .location: String(localized: "Location")
        }
    }

    /// Names and places read A→Z first; numbers and dates biggest/newest first.
    var ascendingFirst: Bool { self == .name || self == .kind || self == .location }

    var isNumber: Bool { self == .size || self == .change || self == .freeable || self == .items }

    /// Shared by every table and outline, so a column is as wide everywhere.
    var width: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch self {
        case .name: (120, 200, 32_768)
        case .size: (64, 80, 32_768)
        case .change: (60, 72, 32_768)
        case .freeable: (64, 78, 32_768)
        case .modified: (100, 112, 32_768)
        case .kind: (60, 110, 32_768)
        case .items: (48, 64, 32_768)
        case .location: (120, 260, 32_768)
        }
    }
}

/// An entry of a table's context menu.
enum TableMenuEntry {
    case action(String, () -> Void)
    /// Opens Quick Look on the rows the menu is for.
    case quickLook
    case divider
    case submenu(String, [TableMenuEntry])
}

/// A one-time menu request; later header clicks keep their native behavior.
struct FileSortRequest: Equatable {
    let id = UUID()
    let column: FileColumn
    let ascending: Bool
}

/// A virtualized native file table with sortable, resizable columns.
struct FileTable: NSViewRepresentable {
    var rows: [FileRow]
    var columns: [FileColumn]
    var hiddenByDefault: Set<FileColumn> = []
    /// Column titles that read better for this table ("Last Active").
    var titles: [FileColumn: String] = [:]
    /// Remembers column widths, order, visibility and sort.
    var autosave: String
    var defaultSort: FileColumn = .size
    var sortRequest: FileSortRequest?
    @Binding var selection: Set<String>
    /// Marked paths; nil hides the checkboxes.
    var marks: Set<String>?
    var onToggleMark: (String) -> Void = { _ in }
    var onOpen: ([String]) -> Void = { _ in }
    var onMark: ([String]) -> Void = { _ in }
    /// Explicit add/remove semantics; nil hides the bulk checkbox.
    var onSetMarks: (([String], Bool) -> Void)?
    var bulkChoiceHelp: String?
    var bulkChoicesEnabled = true
    var onHover: (String?) -> Void = { _ in }
    var menu: ([String]) -> [TableMenuEntry] = { FileActions.inspectionMenu($0) }
    /// Groups and integration records map their IDs to real files explicitly.
    var filePaths: ([String]) -> [String] = { FileActions.paths($0) }

    static var rowHeight: CGFloat { DS.Table.row }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        context.coordinator.enabled = context.environment.isEnabled
        table.style = DS.Table.style
        table.configureRows(height: Self.rowHeight)
        table.apply(context.environment.palette, lines: context.environment.tableLines, stripes: true)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
            col.title = titles[c] ?? c.title
            col.minWidth = c.width.min
            col.width = c.width.ideal
            col.maxWidth = c.width.max
            col.resizingMask = .userResizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: c.ascendingFirst)
            if c.isNumber { col.headerCell.alignment = .right }
            col.isHidden = hiddenByDefault.contains(c)
            table.addTableColumn(col)
        }
        table.autosaveName = autosave
        table.autosaveTableColumns = true
        table.sortDescriptors = [context.coordinator.savedSort ?? NSSortDescriptor(key: defaultSort.rawValue, ascending: defaultSort.ascendingFirst)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        TableChoiceHeader.install(on: table)
        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        table.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu
        context.coordinator.table = table
        context.coordinator.rowMenu = rowMenu
        context.coordinator.headerMenu = headerMenu
        context.coordinator.applySortRequest()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.load(rows, marks: marks, selection: selection)
        table.configureUserColumns(hiddenByDefault: Set(hiddenByDefault.map(\.rawValue)))
        context.coordinator.fitting = table.keepFitting(FileColumn.name.rawValue)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopSorting()
        coordinator.stopPresentation()
        NSTableView.stopFitting(&coordinator.fitting)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.enabled = context.environment.isEnabled
        c.applyDensity(context.environment.layoutDensity)
        c.table?.apply(context.environment.palette, lines: context.environment.tableLines, stripes: true)
        c.applySortRequest()
        c.load(rows, marks: marks, selection: selection)
    }

    /// `rows` in the order of a column, ties broken by name, as Finder does.
    /// The column's values are read out once and positions are sorted, so
    /// the rows themselves, which are large, move only once.
    nonisolated static func sorted(_ rows: [FileRow], by col: FileColumn, ascending asc: Bool) -> [FileRow] {
        func byName(_ i: Int, _ j: Int) -> Bool { rows[i].name.localizedStandardCompare(rows[j].name) == .orderedAscending }
        func order<T: Comparable>(_ keys: [T]) -> [Int] {
            rows.indices.sorted { i, j in
                keys[i] == keys[j] ? byName(i, j) : (asc ? keys[i] < keys[j] : keys[i] > keys[j])
            }
        }
        func text(_ keys: [String], tieByName: Bool) -> [Int] {
            rows.indices.sorted { i, j in
                let r = keys[i].localizedStandardCompare(keys[j])
                if r == .orderedSame { return tieByName && byName(i, j) }
                return asc ? r == .orderedAscending : r == .orderedDescending
            }
        }
        let positions: [Int] = switch col {
        case .name: text(rows.map(\.name), tieByName: false)
        case .size: order(rows.map { $0.size ?? -1 })
        case .freeable: order(rows.map { $0.freeable ?? -1 })
        case .change: order(rows.map { $0.change ?? 0 })
        case .modified: order(rows.map { $0.modified ?? .distantPast })
        case .kind: order(rows.map { $0.kind ?? "" })
        case .items: order(rows.map { $0.items ?? -1 })
        case .location: text(rows.map { $0.location ?? "" }, tieByName: true)
        }
        return positions.map { rows[$0] }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FileTable
        var enabled = true
        weak var table: FileTableView?
        weak var rowMenu: NSMenu?
        weak var headerMenu: NSMenu?
        var fitting: [NSObjectProtocol] = []
        private var source: [FileRow] = []
        private(set) var shown: [FileRow] = []
        private var marks: Set<String>?
        private struct Prepared: Sendable {
            let source: [FileRow]
            let rows: [FileRow]
            let index: [String: Int]
            let column: FileColumn
            let ascending: Bool
            let sameOrder: Bool
            let changes: TableRowChanges?
            let unchanged: Bool
            let choices: ListedChoices
        }
        private var sortGeneration = 0
        private var installedGeneration = -1
        private let sorter = OffMain<Prepared?>(nil)
        private(set) var sortJob: Task<Void, Never>?
        private var appliedSource: [FileRow] = []
        private var appliedColumn: FileColumn?
        private var appliedAscending = false
        private var rowIndex: [String: Int] = [:]
        private var choices = ListedChoices([])
        private var requestedSelection: Set<String>?
        private var pendingDisplay: (Prepared, Int)?
        private var resume: DispatchWorkItem?
        private(set) var presentationActive = true
        private weak var observedWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        /// Set while the table's selection is changed from code, so it isn't
        /// echoed back into the binding.
        private var syncing = false
        private var lastSortRequest: UUID?
        private var density = Density.current

        init(_ parent: FileTable) { self.parent = parent }

        func applyDensity(_ value: Density) {
            guard density != value, let table else { return }
            density = value
            let anchor = TableScrollAnchor(table) { self.shown.indices.contains($0) ? self.shown[$0].id : nil }
            table.style = DS.Table.style
            table.configureRows(height: DS.Table.row)
            refreshVisibleCells()
            table.updateScrollableWidth()
            anchor.restore(in: table) { rowIndex[$0] }
        }

        func applySortRequest() {
            guard let request = parent.sortRequest, lastSortRequest != request.id, let table,
                  let column = table.tableColumns.first(where: { $0.identifier.rawValue == request.column.rawValue }) else { return }
            lastSortRequest = request.id
            column.isHidden = false
            table.sortDescriptors = [NSSortDescriptor(key: request.column.rawValue, ascending: request.ascending)]
            table.fitFlexibleColumn(FileColumn.name.rawValue)
        }

        var savedSort: NSSortDescriptor? {
            guard let s = UserDefaults.standard.string(forKey: parent.autosave + ".sort") else { return nil }
            let parts = s.split(separator: ":")
            guard parts.count == 2, FileColumn(rawValue: String(parts[0])) != nil else { return nil }
            return NSSortDescriptor(key: String(parts[0]), ascending: parts[1] == "a")
        }

        func load(_ rows: [FileRow], marks: Set<String>?, selection: Set<String>) {
            guard let table else { return }
            let sameStorage = rows.count == source.count && rows.withUnsafeBufferPointer { left in
                source.withUnsafeBufferPointer { left.baseAddress == $0.baseAddress }
            }
            if !sameStorage && (max(rows.count, source.count) > 512 || rows != source) {
                source = rows
                resort()
            }
            if marks != self.marks {
                self.marks = marks
                if presentationActive { refreshMarks(table) }
            }
            if requestedSelection != selection { select(selection) }
            refreshChoiceHeader()
        }

        private func refreshChoiceHeader() {
            guard let header = table?.headerView as? TableChoiceHeader else { return }
            let state = choices.state(marks ?? [])
            header.update(state: state, visible: marks != nil && parent.onSetMarks != nil,
                          enabled: enabled && parent.bulkChoicesEnabled && installedGeneration == sortGeneration && sortJob == nil && pendingDisplay == nil && presentationActive && (!choices.checkable.isEmpty || !choices.clearable.isDisjoint(with: marks ?? [])),
                          help: parent.bulkChoiceHelp) { [weak self] in self?.setListedMarks() }
        }

        func setListedMarks(_ checked: Bool? = nil) {
            guard table != nil, enabled, parent.bulkChoicesEnabled, presentationActive, installedGeneration == sortGeneration, sortJob == nil, pendingDisplay == nil,
                  let marks, let action = parent.onSetMarks else { return }
            let checked = checked ?? (choices.state(marks) != .on)
            let ids = checked ? choices.checkable : choices.clearable
            if !ids.isEmpty { action(Array(ids), checked) }
        }

        private func refreshMarks(_ table: NSTableView) {
            let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.rawValue))
            guard col >= 0 else { return }
            table.enumerateAvailableRowViews { rowView, row in
                guard row < self.shown.count, let cell = rowView.view(atColumn: col) as? FileNameCell else { return }
                cell.setMarked(self.marks.map { $0.contains(self.shown[row].id) })
            }
        }

        private var selectedIDs: Set<String> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
        }

        private func select(_ ids: Set<String>, reveal: Bool = true) {
            guard let table else { return }
            requestedSelection = ids
            let set = IndexSet(ids.compactMap { rowIndex[$0] })
            let wasSyncing = syncing
            syncing = true
            if table.selectedRowIndexes != set { table.selectRowIndexes(set, byExtendingSelection: false) }
            syncing = wasSyncing
            if reveal, let first = set.first, !table.rows(in: table.visibleRect).contains(first) { table.scrollRowToVisible(first) }
        }

        private func resort() {
            let descriptor = table?.sortDescriptors.first
            let column = descriptor.flatMap { $0.key }.flatMap(FileColumn.init) ?? parent.defaultSort
            let ascending = descriptor?.ascending ?? column.ascendingFirst
            sortGeneration += 1
            let generation = sortGeneration
            let input = source, previousInput = appliedSource, previousRows = shown, previousIndex = rowIndex
            let sameSort = column == appliedColumn && ascending == appliedAscending
            sortJob?.cancel()
            if input.count <= 512 {
                sortJob = nil
                install(Timings.measure(.sort, rows: input.count) {
                    Self.prepare(input, column: column, ascending: ascending, previousInput: previousInput,
                                 previousRows: previousRows, previousIndex: previousIndex, sameSort: sameSort)
                }, generation: generation)
                return
            }
            let sorter = sorter
            sortJob = Task { [weak self] in
                await sorter.update(count: input.count, inlineLimit: 512, step: .sort) {
                    Self.prepare(input, column: column, ascending: ascending, previousInput: previousInput,
                                 previousRows: previousRows, previousIndex: previousIndex, sameSort: sameSort)
                }
                guard let self, !Task.isCancelled, generation == self.sortGeneration, let prepared = sorter.value else { return }
                self.sortJob = nil
                self.install(prepared, generation: generation)
            }
            refreshChoiceHeader()
        }

        nonisolated private static func prepare(_ input: [FileRow], column: FileColumn, ascending: Bool,
                                                previousInput: [FileRow], previousRows: [FileRow], previousIndex: [String: Int], sameSort: Bool) -> Prepared {
            if sameSort, input == previousInput {
                return Prepared(source: input, rows: previousRows, index: previousIndex, column: column,
                                ascending: ascending, sameOrder: true, changes: nil, unchanged: true, choices: ListedChoices(input))
            }
            let sorted = FileTable.sorted(input, by: column, ascending: ascending)
            let sameOrder = sorted.count == previousRows.count && zip(sorted, previousRows).allSatisfy { $0.id == $1.id }
            let index = sameOrder ? previousIndex : Dictionary(sorted.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
            let changes = sameOrder ? nil : TableRowChanges.between(previousRows.map(\.id), sorted.map(\.id))
            return Prepared(source: input, rows: sorted, index: index, column: column, ascending: ascending, sameOrder: sameOrder, changes: changes, unchanged: false, choices: ListedChoices(input))
        }

        func stopSorting() {
            sortGeneration += 1
            sortJob?.cancel()
            sortJob = nil
            let previous = RetiredValue(pendingDisplay)
            pendingDisplay = nil
            previous.releaseLater()
        }

        private func install(_ prepared: Prepared, generation: Int) {
            guard generation == sortGeneration, let table else { return }
            guard presentationActive else {
                let previous = RetiredValue(pendingDisplay)
                pendingDisplay = (prepared, generation)
                previous.releaseLater()
                return
            }
            let anchor = TableScrollAnchor(table) { self.shown.indices.contains($0) ? self.shown[$0].id : nil }
            let previous = RetiredValue((shown, appliedSource, rowIndex))
            shown = prepared.rows
            appliedSource = prepared.source
            rowIndex = prepared.index
            appliedColumn = prepared.column
            appliedAscending = prepared.ascending
            choices = prepared.choices
            installedGeneration = generation
            previous.releaseLater()
            refreshChoiceHeader()
            guard !prepared.unchanged else { return }
            if prepared.sameOrder {
                Timings.measure(.refresh, rows: prepared.rows.count) { refreshVisibleCells() }
            } else {
                Timings.measure(.reload, rows: prepared.rows.count) {
                    syncing = true
                    table.withoutRowAnimation {
                        if let changes = prepared.changes {
                            table.beginUpdates()
                            table.removeRows(at: changes.removed, withAnimation: [])
                            table.insertRows(at: changes.inserted, withAnimation: [])
                            table.endUpdates()
                        } else { table.reloadData() }
                        select(parent.selection, reveal: false)
                        refreshVisibleCells()
                        anchor.restore(in: table) { rowIndex[$0] }
                    }
                    syncing = false
                }
            }
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        }

        /// Update existing cells in place. Recreating visible views on each
        /// measurement flashes selection chrome and interrupts pointer tracking.
        func refreshVisibleCells() {
            guard let table else { return }
            table.enumerateAvailableRowViews { rowView, row in
                guard self.shown.indices.contains(row) else { return }
                let value = self.shown[row]
                for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                    guard let field = FileColumn(rawValue: column.identifier.rawValue) else { continue }
                    if let cell = rowView.view(atColumn: index) as? FileNameCell {
                        cell.configure(value, marked: self.marks.map { $0.contains(value.id) }, dimUnmeasured: self.parent.columns.contains(.size)) { [weak self] in self?.parent.onToggleMark(value.id) }
                    } else if let cell = rowView.view(atColumn: index) as? FileTextCell { cell.configure(value, column: field) }
                }
            }
        }

        func bindWindow(_ window: NSWindow?) {
            if let window, observedWindow === window { return }
            for token in windowObservers { NotificationCenter.default.removeObserver(token) }
            windowObservers = []
            observedWindow = window
            guard let window else { setPresentationActive(false); return }
            for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                })
            }
            updateVisibility()
        }

        private func updateVisibility() {
            guard let window = observedWindow else { return }
            setPresentationActive(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        func setPresentationActive(_ active: Bool) {
            guard presentationActive != active else { return }
            presentationActive = active
            resume?.cancel()
            guard active else { return }
            // Preserve the last displayed rows for window restoration. Apply a
            // single latest snapshot on the next main-queue turn.
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.presentationActive else { return }
                if let (prepared, generation) = self.pendingDisplay {
                    self.pendingDisplay = nil
                    self.install(prepared, generation: generation)
                }
                if let table = self.table { self.refreshMarks(table) }
            }
            resume = item
            DispatchQueue.main.async(execute: item)
        }

        func stopPresentation() {
            resume?.cancel()
            for token in windowObservers { NotificationCenter.default.removeObserver(token) }
            windowObservers = []
            observedWindow = nil
            presentationActive = false
        }

        // Rows the menu or a key acts on: the selection, or the clicked row
        // when it's outside the selection (as in Finder).
        func targetIDs(clicked: Int) -> [String] {
            guard let table else { return [] }
            if clicked >= 0, clicked < shown.count, !table.selectedRowIndexes.contains(clicked) { return [shown[clicked].id] }
            return table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil }
        }

        var selectedPaths: [String] { FileActions.paths(parent.filePaths(targetIDs(clicked: -1))) }
        var previewURLs: [URL] { selectedPaths.map { URL(fileURLWithPath: $0) } }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let col = FileColumn(rawValue: id.rawValue), row < shown.count else { return nil }
            let r = shown[row]
            if col == .name {
                let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileNameCell ?? FileNameCell(identifier: id)
                cell.configure(r, marked: marks.map { $0.contains(r.id) }, dimUnmeasured: parent.columns.contains(.size)) { [weak self] in self?.parent.onToggleMark(r.id) }
                return cell
            }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FileTextCell ?? FileTextCell(identifier: id)
            cell.configure(r, column: col)
            return cell
        }

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            tableView.visibleContentWidth(of: column)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LinedRowView.make(in: tableView)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            if let d = tableView.sortDescriptors.first, let key = d.key {
                UserDefaults.standard.set("\(key):\(d.ascending ? "a" : "d")", forKey: parent.autosave + ".sort")
            }
            resort()
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            let ids = selectedIDs
            requestedSelection = ids
            if ids != parent.selection { parent.selection = ids }
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier.rawValue == FileColumn.name.rawValue && row < shown.count ? shown[row].name : nil
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0 else { return }
            open(clicked: table.clickedRow)
        }

        func open(clicked: Int = -1) { let ids = targetIDs(clicked: clicked); if !ids.isEmpty { parent.onOpen(ids) } }
        func mark() { let ids = targetIDs(clicked: -1); if !ids.isEmpty { parent.onMark(ids) } }
        func hover(row: Int) { parent.onHover(row >= 0 && row < shown.count ? shown[row].id : nil) }

        // MARK: Menus

        func menuNeedsUpdate(_ menu: NSMenu) {
            Timings.measure(.menu) { updateMenu(menu) }
        }

        private func updateMenu(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if menu === headerMenu {
                table.populateColumnHeader(menu)
                return
            }
            let ids = targetIDs(clicked: table.clickedRow)
            if !ids.isEmpty { add(parent.menu(ids), to: menu) }
            addListedChoices(to: menu)
            table.addColumnSubmenu(to: menu)
        }

        func keyboardMenu() -> NSMenu {
            let menu = NSMenu()
            add(parent.menu(targetIDs(clicked: -1)), to: menu, clickedRow: -1)
            addListedChoices(to: menu)
            table?.addColumnSubmenu(to: menu)
            return menu
        }

        /// A tracked menu can outlive a sort. Resolve its original identities,
        /// never a saved row number that now belongs to a different file.
        func selectForPreview(_ ids: Set<String>) -> Bool {
            let current = Set(ids.filter { rowIndex[$0] != nil })
            guard !current.isEmpty else { return false }
            parent.selection = current
            select(current, reveal: false)
            return true
        }

        private func addListedChoices(to menu: NSMenu) {
            guard marks != nil, parent.onSetMarks != nil else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if !choices.checkable.isEmpty { menu.addItem(ClosureMenuItem(String(localized: "Check All Listed")) { [weak self] in self?.setListedMarks(true) }) }
            if !choices.clearable.isEmpty { menu.addItem(ClosureMenuItem(String(localized: "Uncheck All Listed")) { [weak self] in self?.setListedMarks(false) }) }
        }

        private func add(_ entries: [TableMenuEntry], to menu: NSMenu, clickedRow: Int? = nil) {
            for e in entries {
                switch e {
                case .action(let title, let run): menu.addItem(ClosureMenuItem(title, run))
                case .quickLook:
                    let ids = Set(targetIDs(clicked: clickedRow ?? table?.clickedRow ?? -1))
                    menu.addItem(ClosureMenuItem(String(localized: "Quick Look")) { [weak self] in
                        guard let self, let table, selectForPreview(ids) else { return }
                        table.togglePreview()
                    })
                case .divider:
                    if let last = menu.items.last, !last.isSeparatorItem { menu.addItem(.separator()) }
                case .submenu(let title, let children):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    let sub = NSMenu(title: title)
                    add(children, to: sub, clickedRow: clickedRow)
                    item.submenu = sub
                    menu.addItem(item)
                }
            }
            if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        }
    }
}

/// The table view itself: keys, hover, Quick Look.
final class FileTableView: NSTableView, LinedTable, UserColumnTable {
    var defaultHiddenColumns = Set<String>()
    var columnViewport: ColumnViewport?
    weak var coordinator: FileTable.Coordinator?
    var lines = TableLines.none
    var lineColor = NSColor.separatorColor
    private var tracking: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.bindWindow(window)
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        drawColumnLinesAboveRows(in: clipRect)
    }

    override func keyDown(with event: NSEvent) {
        if handleFileKey(event) { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        switch event.keyCode {
        case 49 where plain:  // Space
            togglePreview()
        case 36, 76:  // Return, Enter
            guard plain else { super.keyDown(with: event); return }
            coordinator?.open()
        case 51 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.command).isEmpty:  // ⌫, ⌘⌫
            coordinator?.mark()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleFileKey(event) || super.performKeyEquivalent(with: event)
    }

    private func handleFileKey(_ event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let action = FileKeyboard.action(event) else { return false }
        switch action {
        case .menu: if let menu = coordinator?.keyboardMenu() { showKeyboardMenu(menu) }
        case .copyAbsolutePath: FileActions.copy(coordinator?.selectedPaths ?? [], as: .absolutePath)
        }
        return true
    }

    func togglePreview() {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !(coordinator?.previewURLs.isEmpty ?? true) {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        coordinator?.hover(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.hover(row: -1)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // Quick Look declares these without an actor, but always calls them on
    // the main thread, where the panel's data source is set.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

extension FileTableView: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { coordinator?.previewURLs.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let urls = coordinator?.previewURLs, index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}

// MARK: - Cells (laid out by hand: cheap, and exact at a fixed row height)

final class FileNameCell: NSTableCellView, ColumnWidthProviding {
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let sub = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let lock = NSImageView()
    private var showsCheck = false
    private var name = ""
    private var onToggle: () -> Void = {}
    private var normalBadgeTint = NSColor.systemGreen
    private var choiceIsEditable = true
    private var reviewBeforeChoosing = false
    private var markedState: NSControl.StateValue = .off

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateBadgeColors() }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.target = self
        check.action = #selector(toggled)
        icon.imageScaling = .scaleProportionallyDown
        label.font = .systemFont(ofSize: 13)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .systemGreen
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: String(localized: "Unreadable"))
        lock.contentTintColor = .systemOrange
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.isSelectable = false
        for v in [check, icon, label, sub, badge, lock] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: FileRow, marked: Bool?, dimUnmeasured: Bool = true, onToggle: @escaping () -> Void) {
        showsCheck = marked != nil
        check.isHidden = marked == nil
        markedState = marked == true ? .on : .off
        check.state = markedState
        reviewBeforeChoosing = r.reviewBeforeChoosing
        choiceIsEditable = r.size != nil && r.canChoose
        check.isEnabled = choiceIsEditable
        check.setAccessibilityLabel(String(localized: "Choose \(r.name) for removal"))
        check.toolTip = r.choiceHelp ?? String(localized: "Choose for removal. ⌫ chooses or unchooses the selected rows.")
        self.onToggle = onToggle
        icon.image = NSImage(systemSymbolName: r.symbol, accessibilityDescription: nil)
        icon.contentTintColor = r.tint ?? .secondaryLabelColor
        name = r.name
        sub.stringValue = r.subtitle ?? ""
        sub.toolTip = r.subtitle
        toolTip = [r.name, r.subtitle].compactMap { $0 }.joined(separator: "\n")
        sub.isHidden = r.subtitle == nil
        label.stringValue = Breakable.text(r.name)
        label.textColor = dimUnmeasured && r.size == nil ? .secondaryLabelColor : .labelColor
        label.toolTip = r.name
        badge.isHidden = r.badge == nil
        badge.stringValue = r.badge ?? ""
        normalBadgeTint = r.badgeTint ?? .systemGreen
        updateBadgeColors()
        badge.toolTip = r.badgeHelp ?? r.badge
        lock.isHidden = !r.locked
        lock.toolTip = r.locked ? String(localized: "MyMole couldn't read inside this folder") : nil
        needsLayout = true
    }

    var preferredColumnWidth: CGFloat {
        let text = max((name as NSString).size(withAttributes: [.font: label.font as Any]).width,
                       (sub.stringValue as NSString).size(withAttributes: [.font: sub.font as Any]).width)
        let trailing = (badge.isHidden ? 0 : badge.intrinsicContentSize.width + 16) + (lock.isHidden ? 0 : 18)
        return ceil(text + DS.Table.cellInset + DS.Table.iconStep + (showsCheck ? DS.Table.tickStep : 0) + trailing + 16)
    }

    private func updateBadgeColors() {
        let color: NSColor = backgroundStyle == .emphasized ? .selectedControlTextColor : normalBadgeTint
        badge.textColor = color
        badge.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBadgeColors()
    }

    @objc private func toggled() {
        if reviewBeforeChoosing { check.state = markedState }
        onToggle()
    }

    func setMarked(_ marked: Bool?) {
        let visible = marked != nil
        if showsCheck != visible {
            showsCheck = visible
            check.isHidden = !visible
            needsLayout = true
        }
        let state: NSControl.StateValue = marked == true ? .on : .off
        markedState = state
        if check.state != state { check.state = state }
    }

    func setChoosingEnabled(_ enabled: Bool, help: String? = nil) {
        check.isEnabled = enabled && choiceIsEditable
        if let help { check.toolTip = help }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = DS.Table.cellInset
        if showsCheck {
            check.frame = NSRect(x: x, y: (h - 18) / 2, width: 18, height: 18)
            x += DS.Table.tickStep
        }
        icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        x += DS.Table.iconStep
        var right = bounds.width - 2
        if !lock.isHidden {
            lock.frame = NSRect(x: right - 12, y: (h - 12) / 2, width: 12, height: 12)
            right -= 18
        }
        if !badge.isHidden {
            let w = badge.intrinsicContentSize.width + 10
            // The name comes first: the badge only shows where both fit.
            if right - w - 6 - x >= min(label.attributedStringValue.size().width, 120) {
                badge.frame = NSRect(x: right - w, y: (h - 16) / 2, width: w, height: 16)
                right -= w + 6
            } else {
                badge.frame = .zero
            }
        }
        let width = max(10, right - x)
        if !sub.isHidden {
            // Name and second line, one line each.
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.stringValue = name
            let gap: CGFloat = 1
            label.frame = NSRect(x: x, y: h / 2 + gap - 1, width: width, height: 17)
            sub.frame = NSRect(x: x, y: h / 2 - 14 - gap, width: width, height: 14)
            return
        }
        // Wraps between a name's parts; a part too long for the column is
        // shortened in the middle, as Finder does, rather than broken.
        let longest = name.split(whereSeparator: { " /-_.".contains($0) })
            .map { (String($0) as NSString).size(withAttributes: [.font: label.font as Any]).width }.max() ?? 0
        // A little room to spare: the field's own insets take some of it.
        if longest > width - 6 {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.stringValue = name
        } else {
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            label.stringValue = Breakable.text(name)
        }
        let fit = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: h)) ?? .zero
        let lh = min(ceil(fit.height), h)
        label.frame = NSRect(x: x, y: (h - lh) / 2, width: width, height: lh)
    }
}

final class FileTextCell: NSTableCellView, ColumnWidthProviding {
    private let label = NSTextField(wrappingLabelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: FileRow, column: FileColumn) {
        label.alignment = column.isNumber ? .right : .left
        label.maximumNumberOfLines = column == .location ? 2 : 1
        label.textColor = column == .size ? .labelColor : .secondaryLabelColor
        label.font = column == .size || column == .freeable || column == .change ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : column == .items ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: column == .location ? 11 : 12)
        label.toolTip = nil
        switch column {
        case .size:
            label.stringValue = r.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? r.sizePlaceholder ?? String(localized: "Scanning…")
            if r.size == nil { label.textColor = .tertiaryLabelColor }
        case .freeable:
            label.stringValue = r.freeable.map { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : "—" } ?? ""
            label.textColor = (r.freeable ?? 0) > 0 ? .systemGreen : .tertiaryLabelColor
        case .modified:
            label.stringValue = r.modified?.listText ?? "—"
            label.toolTip = r.modified.map { $0.formatted(date: .complete, time: .shortened) }
        case .change:
            if let c = r.change, c != 0 {
                label.stringValue = (c > 0 ? "+" : "−") + ByteCountFormatter.string(fromByteCount: abs(c), countStyle: .file)
                label.textColor = c > 0 ? .systemOrange : .systemGreen
            } else {
                label.stringValue = ""
            }
            label.toolTip = r.changeHelp
        case .kind: label.stringValue = r.kind ?? ""
        case .items: label.stringValue = r.items?.formatted() ?? ""
        case .location:
            label.stringValue = r.location.map(Breakable.path) ?? ""
            label.toolTip = r.location
        case .name: break
        }
        if label.toolTip == nil, !label.stringValue.isEmpty { label.toolTip = label.stringValue }
        toolTip = label.toolTip
        needsLayout = true
    }

    var preferredColumnWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width + 16)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let fit = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: bounds.width, height: h)) ?? .zero
        let lh = min(ceil(fit.height), h)
        label.frame = NSRect(x: 0, y: (h - lh) / 2, width: bounds.width, height: lh)
    }
}

extension NSTableView {
    /// Draws again the rows that have cells: those on screen and the few
    /// AppKit prepared just past its edges, which would otherwise show what
    /// they showed before when scrolled in.
    func reloadRowsWithViews(columns: IndexSet? = nil) {
        var rows = IndexSet()
        enumerateAvailableRowViews { _, row in if row >= 0 { rows.insert(row) } }
        guard !rows.isEmpty else { return }
        reloadData(forRowIndexes: rows, columnIndexes: columns ?? IndexSet(integersIn: 0..<numberOfColumns))
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
