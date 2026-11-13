import AppKit
import StorageKit
import SwiftUI

/// Everything a project takes, as a list that opens like Finder's: the
/// groups (build output, caches, sessions), their entries, and what's inside
/// those, folder by folder, each with its own tick box. AppKit's outline
/// view builds only the rows on screen and keeps their cells, and a folder's
/// rows are made only when it's opened, so a node_modules with 50,000
/// folders opens and scrolls like a short list. What's inside an entry is
/// measured the first time it's opened, off the main thread.
struct FootprintOutline: NSViewRepresentable {
    let model: ProjectsModel
    let footprint: ProjectFootprint
    /// What the rows show besides the footprint, so a change reaches them.
    let chosen: Set<String>
    let age: ProjectsModel.Age
    let measured: Set<String>
    var contentsRevision: Int = 0
    let menu: (FootprintOutline.Target) -> [TableMenuEntry]
    var sortRows: @Sendable ([FileRow], FileColumn, Bool) -> [FileRow] = { FileTable.sorted($0, by: $1, ascending: $2) }

    /// What a row's menu is for.
    enum Target {
        case item(FootprintItem)
        case path(FootprintItem, String)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        NativeListViewport.size(proposal)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FootprintOutlineView()
        outline.coordinator = context.coordinator
        outline.style = DS.Table.style
        outline.configureRows(height: DS.Table.compactRow)
        // Sections and spacing carry the structure; stripes on rows this
        // tall would turn every group into a block.
        outline.apply(context.environment.palette, lines: context.environment.tableLines, stripes: false)
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.indentationPerLevel = DS.Table.indent
        outline.autoresizesOutlineColumn = false
        // The same widths as the file tables', so the columns line up from pane to pane.
        for c in [FileColumn.name, .modified, .size] {
            let id = c.rawValue
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = c.title
            col.minWidth = c == .name ? 100 : c.width.min
            col.width = c == .name ? 260 : c.width.ideal
            col.maxWidth = c.width.max
            col.resizingMask = .userResizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: c.ascendingFirst)
            if c.isNumber { col.headerCell.alignment = .right }
            outline.addTableColumn(col)
            if c == .name { outline.outlineTableColumn = col }
        }
        outline.sortDescriptors = [NSSortDescriptor(key: FileColumn.size.rawValue, ascending: false)]
        outline.persistColumns(as: "projects.detail")
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        TableChoiceHeader.install(on: outline)
        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        outline.menu = rowMenu
        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        outline.headerView?.menu = headerMenu
        context.coordinator.headerMenu = headerMenu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        outline.configureUserColumns()
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.rebuild()
        context.coordinator.fitting = outline.keepFitting("name")
        return scroll
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.sorting.stop()
        NSTableView.stopFitting(&coordinator.fitting)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.applyDensity(context.environment.layoutDensity)
        c.outline?.apply(context.environment.palette, lines: context.environment.tableLines, stripes: false)
        let old = c.parent
        c.parent = self
        if old.footprint != footprint {
            c.rebuild()
        } else {
            if old.measured != measured || old.contentsRevision != contentsRevision { c.rebuild() }
            if old.chosen != chosen || old.age != age { c.refreshVisible() }
        }
    }

    // MARK: Nodes

    final class Node {
        enum Kind {
            case section(String, help: String?)
            case item(FootprintItem)
            /// An entry of an item with several.
            case entry(FootprintItem, FootprintEntry)
            case folder(FootprintItem, Folder)
            case file(FootprintItem, path: String, size: Int64, modified: Date)
            case smallFiles(FootprintItem, folder: String, count: Int, bytes: Int64)
            case loading
        }

        var kind: Kind
        let key: String
        /// The folder whose contents are this row's children, when it has any.
        var opens: String?
        var children: [Node]?
        var sourceTree: Folder?
        var contentsVersion = 0
        var descendantsNeedRefresh = false
        var contentOwner: (path: String, version: Int)?
        var sortToken: UUID?

        init(_ kind: Kind, key: String, opens: String? = nil) {
            self.kind = kind
            self.key = key
            self.opens = opens
        }

        var item: FootprintItem? {
            switch kind {
            case .item(let i), .entry(let i, _), .folder(let i, _), .file(let i, _, _, _), .smallFiles(let i, _, _, _): i
            case .section, .loading: nil
            }
        }

        /// The path the row stands for, when it can be chosen on its own.
        var path: String? {
            switch kind {
            case .entry(_, let e): e.path
            case .folder(_, let f): f.path
            case .file(_, let p, _, _): p
            case .item(let i): i.entries.count == 1 ? i.entries[0].path : nil
            default: nil
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var parent: FootprintOutline
        weak var outline: FootprintOutlineView?
        weak var headerMenu: NSMenu?
        var fitting: [NSObjectProtocol] = []
        private var roots: [Node] = []
        /// The order of the rows at every level, from the clicked header.
        private var sort = NSSortDescriptor(key: FileColumn.size.rawValue, ascending: false)
        private var nodesByKey: [String: Node] = [:]
        private var density = Density.current
        private var rebuilding = false
        let sorting = FootprintSorting()

        init(_ parent: FootprintOutline) { self.parent = parent }

        private var model: ProjectsModel { parent.model }

        func applyDensity(_ value: Density) {
            guard density != value, let outline else { return }
            density = value
            let anchor = TableScrollAnchor(outline) { (outline.item(atRow: $0) as? Node)?.key }
            outline.style = DS.Table.style
            outline.configureRows(height: DS.Table.compactRow)
            outline.indentationPerLevel = DS.Table.indent
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows))
            refreshCells()
            outline.updateScrollableWidth()
            anchor.restore(in: outline) { key in nodesByKey[key].map { outline.row(forItem: $0) } }
        }

        // Building

        func rebuild() {
            guard let outline else { return }
            rebuilding = true
            defer { rebuilding = false }
            let anchor = TableScrollAnchor(outline) { (outline.item(atRow: $0) as? Node)?.key }
            let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.key }
            let f = parent.footprint
            let inside = f.items.filter { $0.attribution == .inside }
            let outside = f.items.filter { $0.attribution != .inside }
            var fresh: [Node] = []
            if !inside.isEmpty {
                let s = Node(.section(String(localized: "In the project folder"), help: nil), key: "s:inside")
                s.children = sorted(inside.map(itemNode))
                fresh.append(s)
            }
            if !outside.isEmpty {
                let s = Node(.section(
                    String(localized: "Elsewhere on your Mac"),
                    help: String(localized: "Sessions and DerivedData are tied to the project by the path their tool recorded. Items in ~/Library are matched by name: their bundle ID contains “\(f.project.name)”. Check those before removing them.")),
                    key: "s:outside")
                s.children = sorted(outside.map(itemNode))
                fresh.append(s)
            }
            outline.withoutRowAnimation {
                reconcile(fresh, under: nil)
                for r in roots { outline.expandItem(r) }
                nodesByKey = [:]
                index(roots)
                outline.selectRowIndexes(IndexSet(selected.compactMap { key in
                    guard let node = nodesByKey[key] else { return nil }
                    let row = outline.row(forItem: node)
                    return row >= 0 ? row : nil
                }), byExtendingSelection: false)
                refreshCells()
                anchor.restore(in: outline) { key in nodesByKey[key].map { outline.row(forItem: $0) } }
            }
            refreshChoiceHeader()
        }

        /// Retain native item identity and open branches. A removal changes
        /// only its siblings, instead of replacing the entire detail pane.
        private func reconcile(_ fresh: [Node], under parent: Node?) {
            guard let outline else { return }
            let old = parent?.children ?? (parent == nil ? roots : [])
            let previous = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let merged = fresh.map { candidate -> Node in
                guard let retained = previous[candidate.key] else { return candidate }
                retained.descendantsNeedRefresh = retained.item != candidate.item
                retained.kind = candidate.kind
                retained.opens = candidate.opens
                retained.contentOwner = candidate.contentOwner
                return retained
            }
            if let parent { parent.children = merged } else { roots = merged }
            if let changes = TableRowChanges.between(old.map(\.key), merged.map(\.key)) {
                if !changes.removed.isEmpty || !changes.inserted.isEmpty {
                    outline.beginUpdates()
                    outline.removeItems(at: changes.removed, inParent: parent, withAnimation: [])
                    outline.insertItems(at: changes.inserted, inParent: parent, withAnimation: [])
                    outline.endUpdates()
                }
            } else {
                let open = expandedKeys()
                if let parent { outline.reloadItem(parent, reloadChildren: true) } else { outline.reloadData() }
                reopen(merged, open)
            }
            for (candidate, node) in zip(fresh, merged) {
                guard previous[node.key] != nil, node.children != nil else { continue }
                // A measured entry may be refreshing. Keep its current rows
                // until a replacement arrives, with no empty/loading flash.
                let children: [Node]?
                if case .section = node.kind { children = candidate.children ?? [] }
                else { children = freshChildren(of: node) }
                if let children { reconcile(children, under: node) }
            }
        }

        private func index(_ nodes: [Node]) {
            for node in nodes {
                nodesByKey[node.key] = node
                if let children = node.children { index(children) }
            }
        }

        private func freshChildren(of node: Node) -> [Node]? {
            switch node.kind {
            case .item(let item) where item.entries.count > 1:
                return sorted(item.entries.map { entry in
                    let key = "e:" + entry.path
                    let opens = nodesByKey[key]?.opens ?? (Self.isFolder(entry) ? entry.path : nil)
                    return Node(.entry(item, entry), key: key, opens: opens)
                }, owner: node)
            case .item(let item), .entry(let item, _):
                guard let path = node.opens else { return [] }
                if let tree = model.contents[path] {
                    guard node.sourceTree !== tree || node.descendantsNeedRefresh else { return nil }
                    node.sourceTree = tree
                    node.contentsVersion = model.contentsVersions[path, default: 0]
                    return rows(in: tree, item: item, owner: node)
                }
                // Cache eviction doesn't invalidate the rows of an open branch.
                // A move or Undo explicitly changes the entry's version.
                if node.sourceTree != nil, node.contentsVersion == model.contentsVersions[path, default: 0] { return nil }
                model.loadContents(path)
                return nil
            case .folder(let item, let folder):
                guard node.sourceTree !== folder || node.descendantsNeedRefresh else { return nil }
                node.sourceTree = folder
                return rows(in: folder, item: item, owner: node)
            default: return []
            }
        }

        private func refreshCells() {
            guard let outline else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let node = outline.item(atRow: row) as? Node else { return }
                for (index, column) in outline.tableColumns.enumerated() where !column.isHidden {
                    if let cell = rowView.view(atColumn: index) as? TreeNameCell {
                        cell.configure(node, look: self.look(node)) { [weak self] in self?.toggle(node) }
                        cell.setChoosingEnabled(self.isCurrent(node))
                    } else if let cell = rowView.view(atColumn: index) as? TreeValueCell {
                        cell.configure(node, size: column.identifier.rawValue == "size")
                    }
                }
            }
        }

        private func itemNode(_ item: FootprintItem) -> Node {
            let single = item.entries.count == 1 ? item.entries[0].path : nil
            let key = "i:" + item.id
            return Node(.item(item), key: key, opens: item.entries.count == 1 && (nodesByKey[key]?.opens == single || Self.isFolder(item.entries[0])) ? single : nil)
        }

        private func expandedKeys(in nodes: [Node]? = nil) -> Set<String> {
            guard let outline else { return [] }
            var keys = Set<String>()
            func walk(_ nodes: [Node]) {
                for n in nodes where outline.isItemExpanded(n) {
                    keys.insert(n.key)
                    walk(n.children ?? [])
                }
            }
            walk(nodes ?? roots)
            return keys
        }

        private func reopen(_ nodes: [Node], _ keys: Set<String>) {
            guard let outline, !keys.isEmpty else { return }
            for n in nodes where keys.contains(n.key) {
                outline.expandItem(n)
                reopen(n.children ?? [], keys)
            }
        }

        private static func isFolder(_ entry: FootprintEntry) -> Bool {
            if let known = entry.isDirectory { return known }
            var st = stat()
            return lstat(entry.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        }

        private func children(of n: Node) -> [Node] {
            if let c = n.children { return c }
            let made: [Node]
            switch n.kind {
            case .item(let item) where item.entries.count > 1:
                made = sorted(item.entries.map { e in
                    Node(.entry(item, e), key: "e:" + e.path, opens: Self.isFolder(e) ? e.path : nil)
                }, owner: n)
            case .item(let item), .entry(let item, _):
                made = n.opens.map { contents(of: $0, item: item, waiter: n) } ?? []
            case .folder(let item, let folder):
                n.sourceTree = folder
                made = rows(in: folder, item: item, owner: n)
            default:
                made = []
            }
            n.children = made
            index(made)
            return made
        }

        /// An entry's contents once measured; until then a placeholder row,
        /// and the row is filled in when they arrive.
        private func contents(of path: String, item: FootprintItem, waiter: Node) -> [Node] {
            if let tree = model.contents[path] {
                waiter.sourceTree = tree
                waiter.contentsVersion = model.contentsVersions[path, default: 0]
                return rows(in: tree, item: item, owner: waiter)
            }
            model.loadContents(path)
            return [Node(.loading, key: "l:" + path)]
        }

        private func rows(in folder: Folder, item: FootprintItem, owner: Node) -> [Node] {
            var nodes: [Node] = folder.subfolders.map { f in
                let opens = f.subfolders.isEmpty && f.listedFiles.isEmpty && f.smallFileCount == 0 ? nil : f.path
                return Node(.folder(item, f), key: "f:" + f.path, opens: opens)
            }
            let base = folder.path
            nodes += folder.listedFiles.map { file in
                let p = base + "/" + file.name
                return Node(.file(item, path: p, size: file.size, modified: file.modified), key: "f:" + p)
            }
            nodes = sorted(nodes, owner: owner)
            // The small files counted together stay last, whatever the order.
            if folder.smallFileCount > 0 {
                nodes.append(Node(
                    .smallFiles(item, folder: base, count: folder.smallFileCount, bytes: folder.smallFileBytes),
                    key: "m:" + base))
            }
            let owner = folder.lineage.first?.path ?? folder.path
            for node in nodes { node.contentOwner = (owner, model.contentsVersions[owner, default: 0]) }
            return nodes
        }

        /// Rows in the order of the clicked header; ties by name.
        private func sorted(_ nodes: [Node], owner: Node? = nil) -> [Node] {
            let column = FileColumn(rawValue: sort.key ?? "") ?? .size
            let ascending = sort.ascending
            if let owner {
                sorting.cancel(owner)
                if nodes.count > 512 {
                    sorting.enqueue(nodes, owner: owner, column: column, ascending: ascending, sort: parent.sortRows) { [weak self] owner, keys in
                        self?.installOrder(keys, under: owner)
                    }
                    return nodes
                }
            }
            let byKey = Dictionary(nodes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = nodes.compactMap(FootprintSorting.row)
            return parent.sortRows(rows, column, ascending).compactMap { byKey[$0.id] } + nodes.filter { !FootprintSorting.isSortable($0) }
        }

        private func installOrder(_ keys: [String], under node: Node) {
            guard let children = node.children else { return }
            let byKey = Dictionary(children.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            guard byKey.count == children.count, Set(keys).count == keys.count else { return }
            let tail = children.filter { !FootprintSorting.isSortable($0) }
            let ordered = keys.compactMap { byKey[$0] } + tail
            guard ordered.count == children.count, ordered.map(\.key) != children.map(\.key) else { return }
            let open = expandedKeys(in: children)
            let anchor = outline.map { table in TableScrollAnchor(table) { (table.item(atRow: $0) as? Node)?.key } }
            let selected = outline?.selectedRowIndexes.compactMap { outline?.item(atRow: $0) as? Node } ?? []
            node.children = ordered
            guard let outline, outline.row(forItem: node) >= 0, outline.isItemExpanded(node) else { return }
            outline.withoutRowAnimation {
                outline.reloadItem(node, reloadChildren: true)
                reopen(ordered, open)
                outline.selectRowIndexes(IndexSet(selected.compactMap { selected in
                    let row = outline.row(forItem: selected)
                    return row >= 0 ? row : nil
                }), byExtendingSelection: false)
                refreshCells()
                anchor?.restore(in: outline) { key in self.nodesByKey[key].map { outline.row(forItem: $0) } }
            }
        }

        private func sortLoadedBranches(_ nodes: [Node]) {
            for node in nodes {
                guard let children = node.children else { continue }
                let ordered = sorted(children, owner: node)
                if children.count <= 512 { installOrder(ordered.compactMap { FootprintSorting.row($0)?.id }, under: node) }
                sortLoadedBranches(children)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let first = outlineView.sortDescriptors.first, first != sort else { return }
            sort = first
            sortLoadedBranches(roots)
        }

        /// The tick boxes of the rows that have cells (those on screen and
        /// the few AppKit prepared past its edges), set in place: no cell is
        /// made again, so a click costs microseconds however big the folder.
        func refreshVisible() {
            guard let outline else { return }
            refreshChoiceHeader()
            let column = outline.column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.rawValue))
            guard column >= 0 else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let n = outline.item(atRow: row) as? Node,
                    let cell = rowView.view(atColumn: column) as? TreeNameCell
                else { return }
                cell.update(look(n))
                cell.setChoosingEnabled(self.isCurrent(n))
            }
        }

        private func refreshChoiceHeader() {
            guard let header = outline?.headerView as? TableChoiceHeader else { return }
            let items = parent.footprint.items.filter { $0.removable && !model.eligible($0).isEmpty }
            let states = items.map(model.check)
            let all = !states.isEmpty && states.allSatisfy { $0 == .on }
            let state: ListedChoices.State = all ? .on : states.contains(where: { $0 != .off }) ? .mixed : .off
            header.update(state: state, visible: true, enabled: !items.isEmpty && !model.scanning && !model.trashing,
                          help: String(localized: "Check the removable items listed for this project within the age filter. Protected data stays. Expanded contents go with their chosen parent; nothing is moved here.")) { [weak self] in
                guard let self else { return }
                model.setListedItems(items, checked: !all)
                refreshVisible()
            }
        }

        // Data source

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !rebuilding, let outline else { return }
            let node = outline.selectedRowIndexes.count == 1 ? outline.item(atRow: outline.selectedRow) as? Node : nil
            focusForRefresh(node)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !rebuilding, let node = notification.userInfo?["NSObject"] as? Node, node.opens != nil else { return }
            focusForRefresh(node)
        }

        private func focusForRefresh(_ node: Node?) {
            guard let node, let item = node.item else { model.folderFocus = nil; return }
            let path = folderToRefresh(node) ?? node.path.map { ($0 as NSString).deletingLastPathComponent }
            guard let path, let entry = item.entries.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else {
                model.folderFocus = nil
                return
            }
            if model.contents[entry.path] == nil, model.loadingContents[entry.path] == nil,
               let owner = nodesByKey["e:" + entry.path] ?? nodesByKey["i:" + item.id],
               owner.contentsVersion == model.contentsVersions[entry.path, default: 0],
               let tree = owner.sourceTree, tree.path == entry.path {
                model.keepContents(tree, at: entry.path)
            }
            model.folderFocus = .init(project: parent.footprint.id, entry: entry.path, path: path)
        }

        private func folderToRefresh(_ node: Node) -> String? {
            switch node.kind {
            case .folder(_, let folder): folder.path
            case .smallFiles(_, let folder, _, _): folder
            default: node.opens
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let n = item as? Node else { return roots.count }
            return children(of: n).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let n = item as? Node else { return roots[index] }
            return children(of: n)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? Node else { return false }
            switch n.kind {
            case .section: return true
            case .item(let i) where i.entries.count > 1: return true
            default: return n.opens != nil
            }
        }

        /// Section headings span the whole row, as group rows do in Finder.
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            if case .section = (item as? Node)?.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
            if case .section = (item as? Node)?.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            if case .section = (item as? Node)?.kind { return false }
            return true
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            switch (item as? Node)?.kind {
            case .section, .loading, nil: false
            default: true
            }
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            switch (item as? Node)?.kind {
            case .section: DS.Table.headerRow
            case .item: DS.Table.tallRow
            default: DS.Table.compactRow
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            LinedRowView.make(in: outlineView)
        }

        func outlineView(_ outlineView: NSOutlineView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            outlineView.visibleContentWidth(of: column)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node else { return nil }
            // A group row has no column: its one view spans the row.
            let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
            if id.rawValue == "name" {
                let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TreeNameCell ?? TreeNameCell(identifier: id)
                cell.configure(n, look: look(n)) { [weak self] in self?.toggle(n) }
                cell.setChoosingEnabled(isCurrent(n))
                return cell
            }
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TreeValueCell ?? TreeValueCell(identifier: id)
            cell.configure(n, size: id.rawValue == "size")
            return cell
        }

        /// How a row's tick box looks: nil hides it.
        private func look(_ n: Node) -> (check: NSControl.StateValue?, locked: Bool, whitelisted: Bool) {
            guard let item = n.item else { return (nil, false, false) }
            guard item.removable else { return (nil, { if case .item = n.kind { true } else { false } }(), item.category == .kept) }
            // Kept in Deep Clean: shown locked, never ticked.
            if let p = n.path, model.isKeptElsewhere(p) { return (nil, true, model.rules.protects(p)) }
            switch n.kind {
            case .item(let i):
                return (state(model.check(i)), false, false)
            case .smallFiles(_, let folder, _, _):
                // Small files go with their folder; they can't be chosen one by one.
                return (model.state(of: folder) == .on ? .on : .off, false, false)
            default:
                return (n.path.map { state(model.state(of: $0)) }, false, false)
            }
        }

        private func state(_ c: ProjectsModel.Check) -> NSControl.StateValue {
            switch c {
            case .on: .on
            case .mixed: .mixed
            case .off: .off
            }
        }

        private func isCurrent(_ n: Node) -> Bool {
            n.contentOwner.map { $0.version == model.contentsVersions[$0.path, default: 0] } ?? true
        }

        func toggle(_ n: Node) {
            guard isCurrent(n) else { return }
            switch n.kind {
            case .item(let i): model.toggle(i)
            case .smallFiles: break
            default: if let p = n.path { model.toggle(path: p) }
            }
            // The box shows the model's state even when the click changed
            // nothing; when it changed something, the update follows anyway.
            if parent.chosen == model.chosen { refreshVisible() }
        }

        /// Space ticks the selected rows, or unticks them when all are
        /// ticked already, so a mixed selection ends up all one way.
        func toggleSelection() {
            guard let outline else { return }
            let rows = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }.filter { tick($0) != nil }
            setTicks(rows, on: rows.contains { tick($0) == false })
        }

        @objc func doubleClicked() {
            open(row: outline?.clickedRow ?? -1)
        }

        func open(row: Int) {
            guard let outline, let n = outline.item(atRow: row) as? Node else { return }
            if outline.isExpandable(n) {
                outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
            } else if let p = n.path {
                FileActions.reveal([p])
            }
        }

        // Menu

        var selectedPaths: [String] {
            guard let outline else { return [] }
            return outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }.flatMap { node in
                node.path.map { [$0] } ?? node.item?.entries.map(\.path) ?? []
            }
        }

        func keyboardMenu() -> NSMenu {
            let menu = NSMenu()
            if let outline, let node = outline.item(atRow: outline.selectedRow) as? Node { addActions(for: node, to: menu) }
            outline?.addColumnSubmenu(to: menu)
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === headerMenu, let outline {
                menu.removeAllItems()
                outline.populateColumnHeader(menu)
                return
            }
            menu.removeAllItems()
            guard let outline else { return }
            if let n = outline.item(atRow: outline.clickedRow) as? Node { addActions(for: n, to: menu) }
            outline.addColumnSubmenu(to: menu)
        }

        private func addActions(for n: Node, to menu: NSMenu) {
            guard isCurrent(n) else {
                menu.add(FileActions.inspectionMenu(n.path.map { [$0] } ?? []))
                return
            }
            guard let item = n.item else { return }
            if let path = folderToRefresh(n), let entry = item.entries.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                let focus = ProjectsModel.FolderFocus(project: parent.footprint.id, entry: entry.path, path: path)
                if !model.refreshing, !model.trashing {
                    menu.add([.action(String(localized: "Refresh This Folder")) { [weak self] in self?.model.refreshFolder(focus) }, .divider])
                }
            }
            let target: Target
            if case .item = n.kind {
                target = .item(item)
            } else if let p = n.path {
                target = .path(item, p)
            } else {
                return
            }
            menu.add(tickEntries(clicked: n) + [.divider] + parent.menu(target))
        }

        /// The rows a menu or key acts on: the selection, or the clicked row
        /// when it's outside the selection, as in Finder.
        private func targets(clicked n: Node) -> [Node] {
            guard let outline else { return [n] }
            let picked = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
            return picked.contains(where: { $0 === n }) ? picked : [n]
        }

        /// Whether a row can be ticked, and whether it is.
        private func tick(_ n: Node) -> Bool? {
            guard isCurrent(n) else { return nil }
            let l = look(n)
            guard let state = l.check, !l.locked else { return nil }
            if case .smallFiles = n.kind { return nil }
            return state == .on
        }

        /// Ticks or unticks rows so each ends as `on`; a folder ticked goes
        /// whole, with everything inside it.
        func setTicks(_ nodes: [Node], on: Bool) {
            for n in nodes where tick(n) == !on { toggle(n) }
            refreshVisible()
        }

        private func tickEntries(clicked n: Node) -> [TableMenuEntry] {
            let rows = targets(clicked: n).filter { tick($0) != nil }
            guard !rows.isEmpty else { return [] }
            let off = rows.filter { tick($0) == false }
            let on = rows.filter { tick($0) == true }
            let opens = rows.count == 1 && outline?.isExpandable(n) == true
            var out: [TableMenuEntry] = []
            if !off.isEmpty {
                let title = opens ? String(localized: "Tick Everything Inside")
                    : off.count == 1 ? String(localized: "Tick") : String(localized: "Tick \(off.count) Selected")
                out.append(.action(title) { [weak self] in self?.setTicks(off, on: true) })
            }
            if !on.isEmpty {
                let title = opens ? String(localized: "Untick Everything Inside")
                    : on.count == 1 ? String(localized: "Untick") : String(localized: "Untick \(on.count) Selected")
                out.append(.action(title) { [weak self] in self?.setTicks(on, on: false) })
            }
            return out
        }
    }
}

extension NSMenu {
    /// Adds a table's menu entries; Quick Look is left to tables that have it.
    func add(_ entries: [TableMenuEntry]) {
        for e in entries {
            switch e {
            case .action(let title, let run): addItem(ClosureMenuItem(title, run))
            case .quickLook: continue
            case .divider:
                if let last = items.last, !last.isSeparatorItem { addItem(.separator()) }
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: title)
                sub.add(children)
                item.submenu = sub
                addItem(item)
            }
        }
        if let last = items.last, last.isSeparatorItem { removeItem(last) }
    }
}

/// The outline itself: Space ticks the selected rows.
final class FootprintOutlineView: NSOutlineView, LinedTable, UserColumnTable {
    var defaultHiddenColumns = Set<String>()
    var columnViewport: ColumnViewport?
    weak var coordinator: FootprintOutline.Coordinator?
    var lines = TableLines.none
    var lineColor = NSColor.separatorColor

    /// Where a row's disclosure slot starts. The section headings are group
    /// rows at the top level, so what's under them starts at the column's
    /// left edge, and each level below steps in by one slot and its gap. A
    /// row keeps the slot whether it opens or not, so the tick boxes of a
    /// folder's rows line up. nil for a heading.
    private func slot(atRow row: Int) -> CGFloat? {
        let level = level(forRow: row)
        let column = column(withIdentifier: NSUserInterfaceItemIdentifier(FileColumn.name.rawValue))
        guard level > 0, column >= 0 else { return nil }
        return rect(ofColumn: column).minX + intercellSpacing.width / 2 + CGFloat(level - 1) * indentationPerLevel
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        if column >= 0, tableColumns[column] === outlineTableColumn, let slot = slot(atRow: row) {
            let x = slot + DS.Table.indent
            r.size.width = max(0, r.maxX - x)
            r.origin.x = x
        }
        return r
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = super.frameOfOutlineCell(atRow: row)
        if !r.isEmpty, let slot = slot(atRow: row) {
            r.origin.x = slot
            r.size.width = DS.Table.disclosure
        }
        return r
    }

    override func keyDown(with event: NSEvent) {
        if handleFileKey(event) { return }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, event.charactersIgnoringModifiers == " " {
            coordinator?.toggleSelection()
        } else if plain, [36, 76].contains(event.keyCode) {
            coordinator?.open(row: selectedRow)
        } else {
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
}

// MARK: - Cells (laid out by hand, like the file table's)

private final class TreeNameCell: NSTableCellView, ColumnWidthProviding {
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let lock = NSImageView()
    private let icon = NSImageView()
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var onToggle: () -> Void = {}
    private var isItem = false
    private var isSection = false
    private var choiceIsEditable = true
    private var normalLockTint = NSColor.secondaryLabelColor

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateLockTint() }
    }

    private func updateLockTint() {
        lock.contentTintColor = backgroundStyle == .emphasized ? .selectedControlTextColor : normalLockTint
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.target = self
        check.action = #selector(toggled)
        check.allowsMixedState = true
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: String(localized: "Never removed from here"))
        lock.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        title.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingTail
        for t in [title, detail] { t.isSelectable = false }
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        for v in [check, lock, icon, dot, title, detail] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Only the tick box, for a change of what's chosen.
    func update(_ look: (check: NSControl.StateValue?, locked: Bool, whitelisted: Bool)) {
        if let state = look.check, check.state != state { check.state = state }
    }

    func setChoosingEnabled(_ enabled: Bool) {
        check.isEnabled = enabled && choiceIsEditable
        check.toolTip = enabled ? nil : String(localized: "Refreshing folder contents…")
    }

    func configure(_ n: FootprintOutline.Node, look: (check: NSControl.StateValue?, locked: Bool, whitelisted: Bool), onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        isItem = false
        isSection = false
        choiceIsEditable = true
        check.isHidden = look.check == nil
        check.state = look.check ?? .off
        check.isEnabled = true
        lock.isHidden = !look.locked
        normalLockTint = look.whitelisted ? .systemGreen : .secondaryLabelColor
        updateLockTint()
        lock.toolTip = look.whitelisted ? String(localized: "Whitelisted — this folder and its contents stay during cleanup.") : nil
        dot.isHidden = true
        icon.isHidden = false
        detail.isHidden = true
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        toolTip = nil
        switch n.kind {
        case .section(let text, let help):
            isSection = true
            icon.isHidden = true
            title.stringValue = text
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            toolTip = help
        case .item(let item):
            isItem = true
            icon.isHidden = true
            dot.isHidden = false
            dot.layer?.backgroundColor = NSColor(item.category.color).cgColor
            title.stringValue = item.title
            title.font = .systemFont(ofSize: 13, weight: .medium)
            detail.isHidden = false
            detail.stringValue = Self.summary(item)
            toolTip = item.attribution == .inside
                ? item.category.note : "\(item.category.note)\n\(item.location)\n\(Self.tie(item.attribution))"
        case .entry(let item, let e):
            title.stringValue = e.path == item.location && item.attribution == .inside
                ? String(localized: "Files directly in the project folder")
                : item.attribution == .inside ? String(e.path.dropFirst(item.location.count + 1)) : Self.short(e.path)
            icon.image = Self.symbol(for: e.path, folder: n.opens != nil)
            toolTip = e.path
        case .folder(_, let f):
            title.stringValue = f.name
            icon.image = Self.symbol(for: f.path, folder: true)
            toolTip = f.path
        case .file(_, let p, _, _):
            title.stringValue = (p as NSString).lastPathComponent
            icon.image = Self.symbol(for: p, folder: false)
            toolTip = p
        case .smallFiles(_, _, let count, _):
            choiceIsEditable = false
            title.stringValue = String(localized: "\(count.formatted()) smaller file\(count == 1 ? "" : "s")")
            title.textColor = .secondaryLabelColor
            icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            check.isEnabled = false
            toolTip = String(localized: "Files under 1 MB, counted together; they go with their folder.")
        case .loading:
            check.isHidden = true
            title.stringValue = String(localized: "Measuring…")
            title.textColor = .tertiaryLabelColor
            icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        }
        title.toolTip = title.stringValue
        detail.toolTip = detail.isHidden ? nil : detail.stringValue
        toolTip = [title.stringValue, detail.isHidden ? nil : detail.stringValue, toolTip].compactMap { $0 }.joined(separator: "\n")
        icon.contentTintColor = .secondaryLabelColor
        needsLayout = true
    }

    var preferredColumnWidth: CGFloat {
        let width = max((title.stringValue as NSString).size(withAttributes: [.font: title.font as Any]).width,
                        detail.isHidden ? 0 : (detail.stringValue as NSString).size(withAttributes: [.font: detail.font as Any]).width)
        return ceil(width + DS.Table.tickStep + DS.Table.iconStep + 24)
    }

    /// What the group is; when it changed is in its own column.
    private static func summary(_ item: FootprintItem) -> String {
        var s = item.category.title
        if item.entries.count > 1 { s += String(localized: " · \(item.entries.count.formatted()) items") }
        switch item.attribution {
        case .inside: break
        case .recorded: s += String(localized: " · the tool noted this project")
        case .nameMatch: s += String(localized: " · matched by name only")
        case .user: s += String(localized: " · your rule")
        }
        return s
    }

    /// How data outside the project is tied to it, and how sure that is.
    static func tie(_ a: Attribution) -> String {
        switch a {
        case .inside: String(localized: "Inside the project folder.")
        case .recorded: String(localized: "The tool that made it noted this project's path with it.")
        case .nameMatch: String(localized: "Only the name matches, so it may be another project's or app's of the same name. Never chosen for you.")
        case .user: String(localized: "Tied to the project by a rule you made.")
        }
    }

    private static func short(_ p: String) -> String {
        let home = Home.path
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    private static func symbol(for path: String, folder: Bool) -> NSImage? {
        NSImage(systemSymbolName: folder ? "folder" : "doc", accessibilityDescription: nil)
    }

    @objc private func toggled() { onToggle() }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 0
        if !check.isHidden {
            check.frame = NSRect(x: x, y: (h - 18) / 2, width: 18, height: 18)
            x += DS.Table.tickStep
        } else if !lock.isHidden {
            lock.frame = NSRect(x: x + 3, y: (h - 12) / 2, width: 12, height: 12)
            x += DS.Table.tickStep
        }
        if !dot.isHidden {
            dot.frame = NSRect(x: x + 1, y: isItem ? h / 2 + 6 : (h - 7) / 2, width: 7, height: 7)
            x += 16
        } else if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += DS.Table.iconStep
        }
        let width = max(10, bounds.width - x - 2)
        if isItem {
            let gap = Density.pick(1, 2)
            title.frame = NSRect(x: x, y: h / 2 + gap, width: width, height: 17)
            detail.frame = NSRect(x: x, y: h / 2 - 15 - gap, width: width, height: 15)
        } else {
            let lh: CGFloat = 17
            title.frame = NSRect(x: x, y: (h - lh) / 2 - (isSection ? 0 : 0), width: width, height: lh)
        }
    }
}

private final class TreeValueCell: NSTableCellView, ColumnWidthProviding {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.isSelectable = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ n: FootprintOutline.Node, size: Bool) {
        label.alignment = size ? .right : .left
        label.font = size ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        label.textColor = size ? .labelColor : .secondaryLabelColor
        let bytes: Int64?
        let date: Date?
        switch n.kind {
        case .item(let i): (bytes, date) = (i.bytes, i.latest)
        case .entry(_, let e): (bytes, date) = (e.bytes, e.modified)
        case .folder(_, let f): (bytes, date) = (f.size, f.latestChange)
        case .file(_, _, let s, let m): (bytes, date) = (s, m)
        case .smallFiles(_, _, _, let b): (bytes, date) = (b, nil)
        case .section, .loading: (bytes, date) = (nil, nil)
        }
        if size {
            label.stringValue = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            if case .item = n.kind { label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
        } else {
            label.stringValue = date.flatMap { $0 > .distantPast ? $0.listText : nil } ?? ""
        }
        label.toolTip = label.stringValue.isEmpty ? nil : (size ? label.stringValue : date.map { $0.formatted(date: .complete, time: .shortened) })
        toolTip = label.toolTip
        needsLayout = true
    }

    var preferredColumnWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width + 16)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }
}
