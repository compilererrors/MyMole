import AppKit
import Quartz
import SwiftUI

/// One row of a `FileTable`. Every column is optional; a table shows the
/// columns it was given.
struct FileRow: Identifiable, Equatable, Sendable {
    /// The item's absolute path.
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
    var choiceHelp: String?
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

/// The app's list of files, Finder-style, on AppKit's own table: every row
/// the same height and only the visible ones built. Large lists sort off
/// the main thread. Click a header to sort; right-click it to
/// show or hide columns (remembered). ⌘-click, ⇧-click, ⇧-arrows, ⌘A and
/// type-to-select pick rows; Space is Quick Look, Return opens, ⌫ marks.
struct FileTable: NSViewRepresentable {
    var rows: [FileRow]
    var columns: [FileColumn]
    var hiddenByDefault: Set<FileColumn> = []
    /// Column titles that read better for this table ("Last Active").
    var titles: [FileColumn: String] = [:]
    /// Remembers column widths, order, visibility and sort.
    var autosave: String
    var defaultSort: FileColumn = .size
    @Binding var selection: Set<String>
    /// Marked paths; nil hides the checkboxes.
    var marks: Set<String>?
    var onToggleMark: (String) -> Void = { _ in }
    var onOpen: ([String]) -> Void = { _ in }
    var onMark: ([String]) -> Void = { _ in }
    var onHover: (String?) -> Void = { _ in }
    var menu: ([String]) -> [TableMenuEntry] = { _ in [] }

    static var rowHeight: CGFloat { DS.Table.row }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        table.coordinator = context.coordinator
        table.style = DS.Table.style
        table.rowHeight = Self.rowHeight
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
        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        table.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        table.headerView?.menu = headerMenu
        context.coordinator.table = table
        context.coordinator.rowMenu = rowMenu
        context.coordinator.headerMenu = headerMenu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.load(rows, marks: marks, selection: selection)
        table.configureUserColumns()
        context.coordinator.fitting = table.keepFitting(FileColumn.name.rawValue)
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stopSorting()
        NSTableView.stopFitting(&coordinator.fitting)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.table?.apply(context.environment.palette, lines: context.environment.tableLines, stripes: true)
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
        weak var table: FileTableView?
        weak var rowMenu: NSMenu?
        weak var headerMenu: NSMenu?
        var fitting: [NSObjectProtocol] = []
        private var source: [FileRow] = []
        private(set) var shown: [FileRow] = []
        private var marks: Set<String>?
        private struct SortRequest: Sendable {
            let rows: [FileRow]
            let column: FileColumn
            let ascending: Bool
            let generation: Int
        }

        private var sortGeneration = 0
        private var pendingSort: SortRequest?
        private(set) var sortJob: Task<Void, Never>?
        /// Set while the table's selection is changed from code, so it isn't
        /// echoed back into the binding.
        private var syncing = false

        init(_ parent: FileTable) { self.parent = parent }

        var savedSort: NSSortDescriptor? {
            guard let s = UserDefaults.standard.string(forKey: parent.autosave + ".sort") else { return nil }
            let parts = s.split(separator: ":")
            guard parts.count == 2, FileColumn(rawValue: String(parts[0])) != nil else { return nil }
            return NSSortDescriptor(key: String(parts[0]), ascending: parts[1] == "a")
        }

        func load(_ rows: [FileRow], marks: Set<String>?, selection: Set<String>) {
            guard let table else { return }
            if rows != source {
                source = rows
                self.marks = marks
                resort()
            } else if marks != self.marks {
                self.marks = marks
                // Only the tick boxes change: set in place, no cell made again.
                let col = table.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.rawValue))
                guard col >= 0 else { return }
                table.enumerateAvailableRowViews { rowView, row in
                    guard row < self.shown.count, let cell = rowView.view(atColumn: col) as? FileNameCell else { return }
                    cell.setMarked(marks.map { $0.contains(self.shown[row].id) })
                }
            }
            if selection != selectedIDs { select(selection) }
        }

        private func reloadVisible(_ table: NSTableView, columns: IndexSet? = nil) {
            table.reloadRowsWithViews(columns: columns)
        }

        private var selectedIDs: Set<String> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil })
        }

        private func select(_ ids: Set<String>) {
            guard let table else { return }
            var set = IndexSet()
            if !ids.isEmpty { for (i, r) in shown.enumerated() where ids.contains(r.id) { set.insert(i) } }
            syncing = true
            table.selectRowIndexes(set, byExtendingSelection: false)
            syncing = false
            if let first = set.first, !table.rows(in: table.visibleRect).contains(first) { table.scrollRowToVisible(first) }
        }

        private func resort() {
            let d = table?.sortDescriptors.first
            let col = d.flatMap { $0.key }.flatMap(FileColumn.init) ?? parent.defaultSort
            sortGeneration += 1
            let request = SortRequest(rows: source, column: col, ascending: d?.ascending ?? col.ascendingFirst, generation: sortGeneration)
            // Small lists are immediate; a large one keeps its earlier rows
            // usable while one worker sorts. Updates replace only the pending
            // request, so repeated refreshes can't start unbounded workers.
            if source.count <= 512 {
                pendingSort = nil
                let rows = source
                install(Timings.measure(.sort, rows: rows.count) { FileTable.sorted(rows, by: col, ascending: request.ascending) }, generation: request.generation)
                return
            }
            pendingSort = request
            guard sortJob == nil else { return }
            sortJob = Task { [weak self] in
                while let request = self?.takeSortRequest() {
                    let sorted = await Task.detached(priority: .userInitiated) {
                        Timings.measure(.sort, rows: request.rows.count) {
                            FileTable.sorted(request.rows, by: request.column, ascending: request.ascending)
                        }
                    }.value
                    guard !Task.isCancelled else { return }
                    self?.install(sorted, generation: request.generation)
                }
                self?.sortJob = nil
            }
        }

        private func takeSortRequest() -> SortRequest? {
            defer { pendingSort = nil }
            return pendingSort
        }

        func stopSorting() {
            sortGeneration += 1
            pendingSort = nil
            sortJob?.cancel()
            sortJob = nil
        }

        private func install(_ rows: [FileRow], generation: Int) {
            guard generation == sortGeneration, let table else { return }
            let sameOrder = rows.count == shown.count && zip(rows, shown).allSatisfy { $0.id == $1.id }
            shown = rows
            if sameOrder {
                Timings.measure(.refresh, rows: rows.count) { reloadVisible(table) }
            } else {
                Timings.measure(.reload, rows: rows.count) {
                    syncing = true
                    table.reloadData()
                    syncing = false
                    select(parent.selection)
                }
            }
            if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
                QLPreviewPanel.shared().reloadData()
            }
        }

        // Rows the menu or a key acts on: the selection, or the clicked row
        // when it's outside the selection (as in Finder).
        func targetIDs(clicked: Int) -> [String] {
            guard let table else { return [] }
            if clicked >= 0, clicked < shown.count, !table.selectedRowIndexes.contains(clicked) { return [shown[clicked].id] }
            return table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0].id : nil }
        }

        var previewURLs: [URL] {
            targetIDs(clicked: -1).map { URL(fileURLWithPath: $0) }
        }

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
            open()
        }

        func open() { let ids = targetIDs(clicked: table?.clickedRow ?? -1); if !ids.isEmpty { parent.onOpen(ids) } }
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
                for col in table.tableColumns {
                    guard let c = FileColumn(rawValue: col.identifier.rawValue), c != .name else { continue }
                    let item = ClosureMenuItem(c.title) { [weak table] in
                        col.isHidden.toggle()
                        table?.fitFlexibleColumn(FileColumn.name.rawValue)
                    }
                    item.state = col.isHidden ? .off : .on
                    menu.addItem(item)
                }
                table.addColumnWidthActions(to: menu)
                return
            }
            let ids = targetIDs(clicked: table.clickedRow)
            guard !ids.isEmpty else { return }
            add(parent.menu(ids), to: menu)
        }

        private func add(_ entries: [TableMenuEntry], to menu: NSMenu) {
            for e in entries {
                switch e {
                case .action(let title, let run): menu.addItem(ClosureMenuItem(title, run))
                case .quickLook:
                    menu.addItem(ClosureMenuItem(String(localized: "Quick Look")) { [weak self] in
                        guard let table = self?.table else { return }
                        if table.clickedRow >= 0, !table.selectedRowIndexes.contains(table.clickedRow) {
                            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
                        }
                        table.togglePreview()
                    })
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

/// The table view itself: keys, hover, Quick Look.
final class FileTableView: NSTableView, LinedTable {
    weak var coordinator: FileTable.Coordinator?
    var lines = TableLines.none
    var lineColor = NSColor.separatorColor
    private var tracking: NSTrackingArea?

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        drawColumnLinesAboveRows(in: clipRect)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49:  // Space
            togglePreview()
        case 36, 76:  // Return, Enter
            coordinator?.open()
        case 51 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.command).isEmpty:  // ⌫, ⌘⌫
            coordinator?.mark()
        default:
            super.keyDown(with: event)
        }
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
        check.state = marked == true ? .on : .off
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

    @objc private func toggled() { onToggle() }

    func setMarked(_ marked: Bool?) {
        let state: NSControl.StateValue = marked == true ? .on : .off
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
            label.stringValue = r.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Scanning…")
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
