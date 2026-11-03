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
    let menu: (FootprintOutline.Target) -> [TableMenuEntry]

    /// What a row's menu is for.
    enum Target {
        case item(FootprintItem)
        case path(FootprintItem, String)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FootprintOutlineView()
        outline.coordinator = context.coordinator
        outline.style = DS.Table.style
        // Sections and spacing carry the structure; stripes on rows this
        // tall would turn every group into a block.
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.intercellSpacing = NSSize(width: DS.Table.columnGap, height: 0)
        outline.indentationPerLevel = Density.pick(14, 16)
        outline.autoresizesOutlineColumn = false
        for (id, title, width) in [("name", "Name", (100.0, 260.0, 2000.0)), ("modified", "Modified", (84, 100, 200)), ("size", "Size", (68, 76, 140))] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.minWidth = width.0
            col.width = width.1
            col.maxWidth = width.2
            col.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if id == "size" { col.headerCell.alignment = .right }
            outline.addTableColumn(col)
            if id == "name" { outline.outlineTableColumn = col }
        }
        outline.autosaveName = "projects.detail"
        outline.autosaveTableColumns = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked)
        let rowMenu = NSMenu()
        rowMenu.delegate = context.coordinator
        outline.menu = rowMenu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.rebuild()
        context.coordinator.fitting = outline.keepFitting("name")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        let old = c.parent
        c.parent = self
        if old.footprint != footprint {
            c.rebuild()
        } else {
            if old.measured != measured { c.contentsArrived() }
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

        let kind: Kind
        let key: String
        /// The folder whose contents are this row's children, when it has any.
        let opens: String?
        var children: [Node]?

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
        var fitting: [NSObjectProtocol] = []
        private var roots: [Node] = []
        /// Rows waiting for an entry's contents, by the entry's path.
        private var waiting: [String: [Node]] = [:]

        init(_ parent: FootprintOutline) { self.parent = parent }

        private var model: ProjectsModel { parent.model }

        // Building

        func rebuild() {
            guard let outline else { return }
            let open = expandedKeys()
            waiting = [:]
            let f = parent.footprint
            let inside = f.items.filter { $0.attribution == .inside }
            let outside = f.items.filter { $0.attribution != .inside }
            roots = []
            if !inside.isEmpty {
                let s = Node(.section("In the project folder", help: nil), key: "s:inside")
                s.children = inside.map(itemNode)
                roots.append(s)
            }
            if !outside.isEmpty {
                let s = Node(.section(
                    "Elsewhere on your Mac",
                    help: "Sessions and DerivedData are tied to the project by the path their tool recorded. Items in ~/Library are matched by name: their bundle ID contains “\(f.project.name)”. Check those before removing them."),
                    key: "s:outside")
                s.children = outside.map(itemNode)
                roots.append(s)
            }
            outline.reloadData()
            for r in roots { outline.expandItem(r) }
            reopen(roots, open)
        }

        private func itemNode(_ item: FootprintItem) -> Node {
            let single = item.entries.count == 1 ? item.entries[0].path : nil
            return Node(.item(item), key: "i:" + item.id, opens: single.flatMap { Self.isFolder($0) ? $0 : nil })
        }

        private func expandedKeys() -> Set<String> {
            guard let outline else { return [] }
            var keys = Set<String>()
            func walk(_ nodes: [Node]) {
                for n in nodes where outline.isItemExpanded(n) {
                    keys.insert(n.key)
                    walk(n.children ?? [])
                }
            }
            walk(roots)
            return keys
        }

        private func reopen(_ nodes: [Node], _ keys: Set<String>) {
            guard let outline, !keys.isEmpty else { return }
            for n in nodes where keys.contains(n.key) {
                outline.expandItem(n)
                reopen(n.children ?? [], keys)
            }
        }

        private static func isFolder(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        }

        private func children(of n: Node) -> [Node] {
            if let c = n.children { return c }
            let made: [Node]
            switch n.kind {
            case .item(let item) where item.entries.count > 1:
                made = item.entries.map { e in
                    Node(.entry(item, e), key: "e:" + e.path, opens: Self.isFolder(e.path) ? e.path : nil)
                }
            case .item(let item), .entry(let item, _):
                made = n.opens.map { contents(of: $0, item: item, waiter: n) } ?? []
            case .folder(let item, let folder):
                made = Self.rows(in: folder, item: item)
            default:
                made = []
            }
            n.children = made
            return made
        }

        /// An entry's contents once measured; until then a placeholder row,
        /// and the row is filled in when they arrive.
        private func contents(of path: String, item: FootprintItem, waiter: Node) -> [Node] {
            if let tree = model.contents[path] { return Self.rows(in: tree, item: item) }
            waiting[path, default: []].append(waiter)
            model.loadContents(path)
            return [Node(.loading, key: "l:" + path)]
        }

        private static func rows(in folder: Folder, item: FootprintItem) -> [Node] {
            var out: [(Int64, Node)] = folder.subfolders.map { f in
                let opens = f.subfolders.isEmpty && f.listedFiles.isEmpty && f.smallFileCount == 0 ? nil : f.path
                return (f.size, Node(.folder(item, f), key: "f:" + f.path, opens: opens))
            }
            let base = folder.path
            out += folder.listedFiles.map { file in
                let p = base + "/" + file.name
                return (file.size, Node(.file(item, path: p, size: file.size, modified: file.modified), key: "f:" + p))
            }
            out.sort { $0.0 > $1.0 }
            var nodes = out.map(\.1)
            if folder.smallFileCount > 0 {
                nodes.append(Node(
                    .smallFiles(item, folder: base, count: folder.smallFileCount, bytes: folder.smallFileBytes),
                    key: "m:" + base))
            }
            return nodes
        }

        /// Fills in the rows whose contents were measured meanwhile.
        func contentsArrived() {
            guard let outline else { return }
            for (path, nodes) in waiting where model.contents[path] != nil {
                waiting[path] = nil
                for n in nodes {
                    n.children = nil
                    outline.reloadItem(n, reloadChildren: true)
                }
            }
        }

        /// The tick boxes of the rows that have cells (those on screen and
        /// the few AppKit prepared past its edges), set in place: no cell is
        /// made again, so a click costs microseconds however big the folder.
        func refreshVisible() {
            guard let outline else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let n = outline.item(atRow: row) as? Node,
                    let cell = rowView.view(atColumn: 0) as? TreeNameCell
                else { return }
                cell.update(look(n))
            }
        }

        // Data source

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

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node else { return nil }
            // A group row has no column: its one view spans the row.
            let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
            if id.rawValue == "name" {
                let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TreeNameCell ?? TreeNameCell(identifier: id)
                cell.configure(n, look: look(n)) { [weak self] in self?.toggle(n) }
                return cell
            }
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TreeValueCell ?? TreeValueCell(identifier: id)
            cell.configure(n, size: id.rawValue == "size")
            return cell
        }

        /// How a row's tick box looks: nil hides it.
        private func look(_ n: Node) -> (check: NSControl.StateValue?, locked: Bool) {
            guard let item = n.item else { return (nil, false) }
            guard item.removable else { return (nil, { if case .item = n.kind { true } else { false } }()) }
            switch n.kind {
            case .item(let i):
                return (state(model.check(i)), false)
            case .smallFiles(_, let folder, _, _):
                // Small files go with their folder; they can't be chosen one by one.
                return (model.state(of: folder) == .on ? .on : .off, false)
            default:
                return (n.path.map { state(model.state(of: $0)) }, false)
            }
        }

        private func state(_ c: ProjectsModel.Check) -> NSControl.StateValue {
            switch c {
            case .on: .on
            case .mixed: .mixed
            case .off: .off
            }
        }

        func toggle(_ n: Node) {
            switch n.kind {
            case .item(let i): model.toggle(i)
            case .smallFiles: break
            default: if let p = n.path { model.toggle(path: p) }
            }
            // The box shows the model's state even when the click changed
            // nothing; when it changed something, the update follows anyway.
            if parent.chosen == model.chosen { refreshVisible() }
        }

        /// Space ticks or unticks the selected rows.
        func toggleSelection() {
            guard let outline else { return }
            for row in outline.selectedRowIndexes {
                if let n = outline.item(atRow: row) as? Node { toggle(n) }
            }
        }

        @objc func doubleClicked() {
            guard let outline, let n = outline.item(atRow: outline.clickedRow) as? Node else { return }
            if outline.isExpandable(n) {
                outline.isItemExpanded(n) ? outline.collapseItem(n) : outline.expandItem(n)
            } else if let p = n.path {
                FileActions.reveal([p])
            }
        }

        // Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let n = outline.item(atRow: outline.clickedRow) as? Node, let item = n.item else { return }
            let target: Target
            if case .item = n.kind {
                target = .item(item)
            } else if let p = n.path {
                target = .path(item, p)
            } else {
                return
            }
            menu.add(parent.menu(target))
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
final class FootprintOutlineView: NSOutlineView {
    weak var coordinator: FootprintOutline.Coordinator?

    // The section headings are group rows at the top level; what's under
    // them starts at the left edge rather than one indent in.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        if column == 0, level(forRow: row) > 0 {
            r.origin.x -= indentationPerLevel
            r.size.width += indentationPerLevel
        }
        return r
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var r = super.frameOfOutlineCell(atRow: row)
        if level(forRow: row) > 0 { r.origin.x -= indentationPerLevel }
        return r
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            coordinator?.toggleSelection()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Cells (laid out by hand, like the file table's)

private final class TreeNameCell: NSTableCellView {
    private let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let lock = NSImageView()
    private let icon = NSImageView()
    private let dot = NSView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var onToggle: () -> Void = {}
    private var isItem = false
    private var isSection = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.target = self
        check.action = #selector(toggled)
        check.allowsMixedState = true
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Never removed from here")
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
    func update(_ look: (check: NSControl.StateValue?, locked: Bool)) {
        if let state = look.check, check.state != state { check.state = state }
    }

    func configure(_ n: FootprintOutline.Node, look: (check: NSControl.StateValue?, locked: Bool), onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        isItem = false
        isSection = false
        check.isHidden = look.check == nil
        check.state = look.check ?? .off
        check.isEnabled = true
        lock.isHidden = !look.locked
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
            toolTip = item.attribution == .inside ? item.category.note : "\(item.category.note)\n\(item.location)"
        case .entry(let item, let e):
            title.stringValue = e.path == item.location && item.attribution == .inside
                ? "Files directly in the project folder"
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
            title.stringValue = "\(count.formatted()) smaller file\(count == 1 ? "" : "s")"
            title.textColor = .secondaryLabelColor
            icon.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            check.isEnabled = false
            toolTip = "Files under 1 MB, counted together; they go with their folder."
        case .loading:
            check.isHidden = true
            title.stringValue = "Measuring…"
            title.textColor = .tertiaryLabelColor
            icon.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        }
        icon.contentTintColor = .secondaryLabelColor
        needsLayout = true
    }

    /// What the group is; when it changed is in its own column.
    private static func summary(_ item: FootprintItem) -> String {
        var s = item.category.title
        if item.entries.count > 1 { s += " · \(item.entries.count.formatted()) items" }
        if item.attribution == .nameMatch { s += " · matched by name" }
        return s
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
        var x: CGFloat = Density.pick(0, 2)
        if !check.isHidden {
            check.frame = NSRect(x: x, y: (h - 18) / 2, width: 18, height: 18)
            x += 22
        } else if !lock.isHidden {
            lock.frame = NSRect(x: x + 3, y: (h - 12) / 2, width: 12, height: 12)
            x += 22
        }
        if !dot.isHidden {
            dot.frame = NSRect(x: x + 1, y: isItem ? h / 2 + 6 : (h - 7) / 2, width: 7, height: 7)
            x += 14
        } else if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
            x += 22
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

private final class TreeValueCell: NSTableCellView {
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
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
    }
}
