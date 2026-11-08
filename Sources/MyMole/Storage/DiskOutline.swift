import AppKit
import Observation
import Quartz
import StorageKit
import SwiftUI

enum DiskFolderView: String { case tree, list }

/// A virtualized tree of the map already in memory. Expanding never walks
/// the disk: a branch is prepared in chunks, sorted away from the main
/// actor, and installed only while it still belongs to this map.
struct DiskOutline: NSViewRepresentable {
    let root: Folder
    let revision: Int
    let ready: (Folder) -> Bool
    let state: State
    @Binding var selection: Set<String>
    @Binding var expanded: Set<String>
    let marks: Set<String>?
    let row: (DiskEntry) -> FileRow
    let onToggle: (DiskEntry) -> Void
    let onOpen: ([DiskEntry]) -> Void
    let onMark: ([DiskEntry]) -> Void
    let onHover: (DiskEntry?) -> Void
    let menu: ([DiskEntry], [DiskEntry]) -> [TableMenuEntry]
    let onSmallFiles: (String) -> Void
    var sortRows: @Sendable ([FileRow], FileColumn, Bool) -> [FileRow] = { FileTable.sorted($0, by: $1, ascending: $2) }

    @MainActor @Observable final class State {
        var rootID: ObjectIdentifier?
        var revision = -1
        var visible: [DiskEntry] = []
        var byPath: [String: DiskEntry] = [:]
        var readyCount = 0
    }

    final class Node {
        let entry: DiskEntry?
        let folder: Folder?
        let path: String
        let summary: FileRow?
        let smallFiles: Bool
        var children: [Node]?

        init(entry: DiskEntry?, folder: Folder?, path: String, summary: FileRow? = nil, smallFiles: Bool = false) {
            self.entry = entry
            self.folder = folder
            self.path = path
            self.summary = summary
            self.smallFiles = smallFiles
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = DiskOutlineView()
        let c = context.coordinator
        outline.coordinator = c
        outline.style = DS.Table.style
        outline.rowHeight = FileTable.rowHeight
        outline.apply(context.environment.palette, lines: context.environment.tableLines, stripes: true)
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.indentationPerLevel = DS.Table.indent
        outline.autoresizesOutlineColumn = false
        for column in [FileColumn.name, .size, .modified, .kind, .items] {
            let col = NSTableColumn(identifier: .init(column.rawValue))
            col.title = column.title
            col.minWidth = column == .name ? 140 : column.width.min
            col.width = column == .name ? 280 : column.width.ideal
            col.maxWidth = column.width.max
            col.resizingMask = .userResizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.ascendingFirst)
            col.isHidden = column != .name && column != .size
            if column.isNumber { col.headerCell.alignment = .right }
            outline.addTableColumn(col)
            if column == .name { outline.outlineTableColumn = col }
        }
        outline.autosaveName = "diskMap.tree"
        outline.autosaveTableColumns = true
        outline.sortDescriptors = [NSSortDescriptor(key: FileColumn.size.rawValue, ascending: false)]
        outline.dataSource = c
        outline.delegate = c
        outline.target = c
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        let menu = NSMenu()
        menu.delegate = c
        outline.menu = menu
        let header = NSMenu()
        header.delegate = c
        outline.headerView?.menu = header
        c.headerMenu = header
        c.outline = outline
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        outline.configureUserColumns()
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        c.rebuild()
        c.fitting = outline.keepFitting(FileColumn.name.rawValue)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let changed = c.parent.root !== root || c.parent.revision != revision
        let appearanceChanged = c.family != context.environment.palette.family
        c.family = context.environment.palette.family
        c.parent = self
        c.outline?.apply(context.environment.palette, lines: context.environment.tableLines, stripes: true)
        if changed { c.rebuild() }
        else { c.refreshVisible(appearance: appearanceChanged); c.select() }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.stop()
        NSTableView.stopFitting(&coordinator.fitting)
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: DiskOutline
        weak var outline: DiskOutlineView?
        weak var headerMenu: NSMenu?
        var fitting: [NSObjectProtocol] = []
        var family: ThemeFamily?
        private(set) var rootNode: Node?
        private var requestedRoot: Node?
        private var displayedRevision = -1
        private(set) var job: Task<Void, Never>?
        private var pending: [Node] = []
        private var generation = 0
        private var syncing = false
        private var stopped = false
        private var sort: FileColumn = .size
        private var ascending = false
        private var known: [String: Node] = [:]
        private var lastSelection: Set<String>?
        private var closing: (path: String, expanded: Set<String>)?
        private var lastMarks: Set<String>?
        private var marksKnown = false

        init(_ parent: DiskOutline) { self.parent = parent }

        func rebuild() {
            generation += 1
            let node = Node(entry: nil, folder: parent.root, path: parent.root.path)
            requestedRoot = node
            pending = []
            lastSelection = nil
            if rootNode == nil || rootNode?.path != node.path {
                rootNode = node
                known = [:]
                syncing = true
                outline?.reloadData()
                syncing = false
            }
            schedule(node)
        }

        func stop() {
            stopped = true
            generation += 1
            pending = []
            job?.cancel()
        }

        /// One worker even when sorting an old branch can't be interrupted.
        /// New requests replace the queue, and the old result is discarded.
        private func schedule(_ node: Node) {
            guard !stopped, !pending.contains(where: { $0 === node }) else { return }
            pending.append(node)
            guard job == nil else { return }
            job = Task { [weak self] in
                guard let self else { return }
                defer { job = nil }
                while !pending.isEmpty, !stopped {
                    let node = pending.removeFirst()
                    let run = generation
                    guard node === requestedRoot || outline?.isItemExpanded(node) == true else { continue }
                    await prepare(node, run: run)
                }
            }
        }

        private func children(_ node: Node) -> [Node] {
            if let children = node.children { return children }
            let loading = Node(entry: nil, folder: nil, path: "loading:" + node.path,
                               summary: FileRow(id: "loading:" + node.path, name: String(localized: "Preparing folder…"), symbol: "hourglass"))
            node.children = [loading]
            schedule(node)
            return node.children ?? []
        }

        private func prepare(_ node: Node, run: Int) async {
            guard let folder = node.folder, parent.ready(folder) else { return }
            // Copy the arrays on their owning actor. No background task reads
            // a Folder while the scanner or a Trash job may be writing it.
            let folders = folder.subfolders
            let files = folder.listedFiles
            let small = (folder.smallFileCount, folder.smallFileBytes)
            let base = node.path == "/" ? "" : node.path
            var entries: [DiskEntry] = []
            var keys: [FileRow] = []
            entries.reserveCapacity(folders.count + files.count)
            keys.reserveCapacity(folders.count + files.count)
            for i in 0..<(folders.count + files.count) {
                guard run == generation, !stopped else { return }
                let entry: DiskEntry
                if i < folders.count {
                    let f = folders[i]
                    let pending = !parent.ready(f)
                    let kind = pending ? (f.inheritedKind ?? .other) : (f.inheritedKind ?? ChartColors.dominantKind(.folder(f)))
                    entry = DiskEntry(path: base + "/" + f.name, name: f.name, size: pending ? 0 : f.size,
                                      modified: pending ? .distantPast : f.latestChange, kind: kind,
                                      kindTitle: String(localized: "Folder"), items: pending ? 0 : f.fileCount, folder: f, pending: pending)
                } else {
                    let f = files[i - folders.count]
                    entry = DiskEntry(path: base + "/" + f.name, name: f.name, size: f.size, modified: f.modified,
                                      kind: f.kind, kindTitle: f.kind.title, items: 1, folder: nil, pending: false)
                }
                entries.append(entry)
                keys.append(FileRow(id: entry.path, name: entry.name, size: entry.pending ? nil : entry.size,
                                    modified: entry.modified, kind: entry.kindTitle, items: entry.pending ? nil : entry.items))
                if i % 256 == 255 { await Task.yield() }
            }
            let (column, asc) = (sort, ascending)
            let sortRows = parent.sortRows
            let sorted: [FileRow]
            if keys.count > 512 {
                sorted = await Task.detached(priority: .userInitiated) { [keys] in
                    Timings.measure(.sort, rows: keys.count) { sortRows(keys, column, asc) }
                }.value
            } else { sorted = sortRows(keys, column, asc) }
            guard run == generation, !stopped, node === requestedRoot || outline?.isItemExpanded(node) == true else { return }
            let byID = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var nodes = sorted.compactMap { key -> Node? in
                guard let entry = byID[key.id] else { return nil }
                return Node(entry: entry, folder: entry.folder, path: entry.path)
            }
            if small.0 > 0 {
                let key = "small:" + node.path
                nodes.append(Node(entry: nil, folder: nil, path: node.path,
                                  summary: FileRow(id: key, name: String(localized: "\(small.0.formatted()) smaller files"), size: small.1,
                                                   symbol: "doc.on.doc", subtitle: String(localized: "Under 1 MB each · open to list")), smallFiles: true))
            }
            node.children = nodes
            syncing = true
            if node === requestedRoot {
                rootNode = node
                displayedRevision = parent.revision
                outline?.reloadData()
            }
            else { outline?.reloadItem(node, reloadChildren: true) }
            for child in nodes where child.folder != nil && parent.expanded.contains(child.path) && child.entry?.pending == false {
                outline?.expandItem(child)
            }
            syncing = false
            reportVisible()
            select(force: true)
        }

        func reportVisible() {
            guard isCurrent, let outline else { return }
            parent.state.rootID = parent.root.id
            parent.state.revision = parent.revision
            let nodes = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? Node }
            known = Dictionary(nodes.filter { $0.entry != nil }.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let entries = nodes.compactMap(\.entry)
            parent.state.visible = entries
            parent.state.byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            parent.state.readyCount = entries.filter { !$0.pending }.count
        }

        func select(force: Bool = false) {
            guard let outline else { return }
            guard force || lastSelection != parent.selection else { return }
            lastSelection = parent.selection
            let wanted = IndexSet(parent.selection.compactMap { path -> Int? in
                guard let node = known[path] else { return nil }
                let row = outline.row(forItem: node)
                return row >= 0 ? row : nil
            })
            guard wanted != outline.selectedRowIndexes else { return }
            syncing = true
            outline.selectRowIndexes(wanted, byExtendingSelection: false)
            syncing = false
        }

        func refreshVisible(appearance: Bool = false) {
            guard let outline else { return }
            if appearance { outline.reloadRowsWithViews(); return }
            guard !marksKnown || lastMarks != parent.marks else { return }
            lastMarks = parent.marks
            marksKnown = true
            let column = outline.column(withIdentifier: .init(FileColumn.name.rawValue))
            guard column >= 0 else { return }
            outline.enumerateAvailableRowViews { row, index in
                guard let node = outline.item(atRow: index) as? Node,
                      let cell = row.view(atColumn: column) as? FileNameCell else { return }
                self.configure(cell, node: node)
            }
        }

        private func targets(clicked: Int) -> [Node] {
            guard let outline else { return [] }
            let indices = clicked >= 0 && !outline.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : outline.selectedRowIndexes
            return indices.compactMap { outline.item(atRow: $0) as? Node }
        }

        private func actionable(_ nodes: [Node]) -> [DiskEntry] {
            guard isCurrent else { return [] }
            return nodes.compactMap(\.entry).filter { !$0.pending }
        }

        private var isCurrent: Bool { rootNode?.folder === parent.root && displayedRevision == parent.revision }

        var previewURLs: [URL] { actionable(targets(clicked: -1)).map { URL(fileURLWithPath: $0.path) } }

        @objc func doubleClicked() { open(clicked: outline?.clickedRow ?? -1) }

        func open(clicked: Int = -1) {
            guard isCurrent else { return }
            let nodes = targets(clicked: clicked)
            if nodes.count == 1, nodes[0].smallFiles { parent.onSmallFiles(nodes[0].path) }
            else { let entries = actionable(nodes); if !entries.isEmpty { parent.onOpen(entries) } }
        }

        func mark() {
            guard let marks = parent.marks else { return }
            parent.onMark(actionable(targets(clicked: -1)).filter { Marked.parent(of: $0.path, in: marks) == nil })
        }
        func hover(_ row: Int) { parent.onHover(row >= 0 ? (outline?.item(atRow: row) as? Node)?.entry : nil) }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node ?? rootNode else { return 0 }
            return children(node).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children((item as? Node) ?? rootNode!)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard isCurrent, let node = item as? Node, let folder = node.folder, node.entry?.pending == false else { return false }
            return !folder.subfolders.isEmpty || !folder.listedFiles.isEmpty || folder.smallFileCount > 0
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            return node.entry != nil || node.smallFiles
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? Node else { return }
            if !syncing { parent.expanded.insert(node.path) }
            reportVisible()
        }

        func outlineViewItemWillCollapse(_ notification: Notification) {
            guard !syncing, closing == nil, let node = notification.userInfo?["NSObject"] as? Node else { return }
            closing = (node.path, parent.expanded)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? Node else { return }
            // AppKit also collapses descendants. Keep their remembered paths
            // so reopening this branch restores the same working context.
            if let closing, closing.path != node.path { return }
            let remembered = (closing?.expanded ?? parent.expanded).subtracting([node.path])
            // The saved paths retain the expansion preference of descendants;
            // their row objects need not stay in memory while the branch is shut.
            node.children = nil
            closing = nil
            parent.expanded = remembered
            reportVisible()
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            parent.selection = Set(targets(clicked: -1).compactMap { $0.entry?.path })
            lastSelection = parent.selection
            if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        }

        func outlineView(_ outlineView: NSOutlineView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            outlineView.visibleContentWidth(of: column)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let id = tableColumn?.identifier, let column = FileColumn(rawValue: id.rawValue) else { return nil }
            if column == .name {
                let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? FileNameCell ?? FileNameCell(identifier: id)
                configure(cell, node: node)
                return cell
            }
            let row = node.entry.map(parent.row) ?? node.summary ?? FileRow(id: node.path, name: "")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? FileTextCell ?? FileTextCell(identifier: id)
            cell.configure(row, column: column)
            return cell
        }

        private func configure(_ cell: FileNameCell, node: Node) {
            var row = node.entry.map(parent.row) ?? node.summary ?? FileRow(id: node.path, name: "")
            let included = node.entry.flatMap { entry in parent.marks.flatMap { Marked.parent(of: entry.path, in: $0) } }
            let marked = node.entry.flatMap { entry in parent.marks.map { included != nil || $0.contains(entry.path) } }
            let help = included.map { folder in
                String(localized: "Included with \((folder as NSString).lastPathComponent). Unchoose the containing folder before choosing individual items.")
            }
            if included != nil {
                row.badge = String(localized: "Included")
                row.badgeHelp = help
                row.badgeTint = .secondaryLabelColor
            }
            cell.configure(row, marked: marked) { [weak self] in
                guard let self, isCurrent, let entry = node.entry, !entry.pending,
                      parent.marks.flatMap({ Marked.parent(of: entry.path, in: $0) }) == nil else { return }
                parent.onToggle(entry)
            }
            cell.setChoosingEnabled(isCurrent && included == nil && node.entry?.pending == false, help: help)
            cell.toolTip = node.entry?.path
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { LinedRowView.make(in: outlineView) }

        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? Node)?.entry?.name
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let d = outlineView.sortDescriptors.first, let key = d.key, let col = FileColumn(rawValue: key) else { return }
            sort = col
            ascending = d.ascending
            rebuild()
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            Timings.measure(.menu, rows: outline?.numberOfRows ?? 0) {
                menu.removeAllItems()
                if menu === headerMenu, let outline {
                    for col in outline.tableColumns {
                        let item = ClosureMenuItem(col.title) { col.isHidden.toggle(); outline.fitFlexibleColumn(FileColumn.name.rawValue) }
                        item.state = col.isHidden ? .off : .on
                        item.isEnabled = col !== outline.outlineTableColumn
                        menu.addItem(item)
                    }
                    outline.addColumnWidthActions(to: menu)
                } else {
                    var entries = parent.menu(actionable(targets(clicked: outline?.clickedRow ?? -1)), parent.state.visible)
                    entries = entries.map { entry in
                        if case .quickLook = entry {
                            return .action(String(localized: "Quick Look")) { [weak self] in
                                guard let self, let outline else { return }
                                if outline.clickedRow >= 0, !outline.selectedRowIndexes.contains(outline.clickedRow) {
                                    outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false)
                                }
                                outline.togglePreview()
                            }
                        }
                        return entry
                    }
                    menu.add(entries)
                }
            }
        }
    }
}

/// Native disclosure triangles and arrow-key navigation, with the same
/// selection, Quick Look, hover and removal keys as the file table.
final class DiskOutlineView: NSOutlineView, LinedTable {
    weak var coordinator: DiskOutline.Coordinator?
    var lines = TableLines.none
    var lineColor = NSColor.separatorColor
    private var tracking: NSTrackingArea?

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        drawColumnLinesAboveRows(in: clipRect)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePreview()
        case 36, 76: coordinator?.open()
        case 51 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.command).isEmpty: coordinator?.mark()
        default: super.keyDown(with: event)
        }
    }

    func togglePreview() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible { panel.orderOut(nil) }
        else if !(coordinator?.previewURLs.isEmpty ?? true) { panel.makeKeyAndOrderFront(nil) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); coordinator?.hover(row(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); coordinator?.hover(-1) }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = self } }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { MainActor.assumeIsolated { panel.dataSource = nil } }
}

extension DiskOutlineView: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { coordinator?.previewURLs.count ?? 0 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard let urls = coordinator?.previewURLs, index < urls.count else { return nil }
        return urls[index] as NSURL
    }
}
