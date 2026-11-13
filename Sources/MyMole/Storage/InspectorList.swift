import StorageKit
import SwiftUI

/// One row of the Browse list: a subfolder or a listed file of the open folder.
struct DiskEntry: Identifiable, Sendable {
    let path: String
    let name: String
    let size: Int64
    /// A file's modification date; for a folder, the latest change of
    /// anything inside it.
    let modified: Date
    /// A file's kind; for a folder, the kind holding most of its bytes.
    let kind: FileKind
    let kindTitle: String
    let items: Int
    let folder: Folder?
    let pending: Bool
    var id: String { path }
    var marked: Marked { Marked(path: path, name: name, size: size, isFolder: folder != nil) }
}

/// The open folder's contents as a Finder-style table (`FileTable`): sort by
/// any column, filter by name, kind and date, select with ⌘-click, ⇧-click,
/// ⇧-arrows or ⌘A, and act on the selection from the context menu. Selected
/// folders light up in the chart; hover a row and its segment does too.
struct InspectorList: View {
    @Environment(\.palette) private var palette
    @AppStorage("diskMap.folderView") private var folderView = DiskFolderView.tree
    @Bindable var model: StorageModel
    /// The folder whose smaller files are being listed.
    @State private var smallFilesOf: String?
    @State private var treeState = DiskOutline.State()

    var body: some View {
        if let cur = model.current {
            VStack(spacing: 0) {
                header(cur)
                filterBar
                Divider()
                if model.browseFilter.wholeScan, let index = model.index {
                    WholeScanSearch(model: model, index: index)
                } else if folderView == .tree, !model.browseFilter.isActive {
                    tree(cur)
                } else {
                    let all = entries(cur)
                    let rows = all.filter(model.browseFilter.matches)
                    table(rows)
                        .dsEmptyOverlay(showing: rows.isEmpty && !model.scanning || model.currentIsEmpty) {
                            if rows.isEmpty, !all.isEmpty, !model.scanning {
                                ContentUnavailableView("No Matching Items", systemImage: "line.3.horizontal.decrease",
                                    description: Text("Adjust or clear the filters above to see more files and folders."))
                                    .allowsHitTesting(false)
                            } else if model.currentIsEmpty {
                                emptyFolder
                            }
                        }
                    Divider()
                    footer(cur, rows: rows, all: all)
                }
            }
            .sheet(item: Binding(get: { smallFilesOf.map(SmallFilesSheet.Target.init) }, set: { smallFilesOf = $0?.path })) { t in
                SmallFilesSheet(folder: t.path, readOnly: model.opened != nil)
            }
        }
    }

    // MARK: Rows

    private func entries(_ cur: Folder) -> [DiskEntry] {
        let base = cur.path == "/" ? "" : cur.path
        var out: [DiskEntry] = []
        out.reserveCapacity(cur.subfolders.count + cur.listedFiles.count)
        for f in cur.subfolders {
            let kindTitle = f.inheritedKind.map { String(localized: "\($0.title) Folder") } ?? String(localized: "Folder")
            // A pending folder is still being written by the scanner: only
            // its immutable fields may be read.
            if model.isPending(f) {
                out.append(
                    DiskEntry(
                        path: base + "/" + f.name, name: f.name, size: 0, modified: .distantPast,
                        kind: f.inheritedKind ?? .other, kindTitle: kindTitle, items: 0, folder: f, pending: true))
                continue
            }
            guard f.size > 0 else { continue }
            out.append(
                DiskEntry(
                    path: base + "/" + f.name, name: f.name, size: f.size,
                    modified: f.latestChange, kind: f.inheritedKind ?? ChartColors.dominantKind(.folder(f)),
                    kindTitle: kindTitle, items: f.fileCount, folder: f, pending: false))
        }
        for item in cur.listedFiles {
            out.append(
                DiskEntry(
                    path: base + "/" + item.name, name: item.name, size: item.size, modified: item.modified,
                    kind: item.kind, kindTitle: item.kind.title, items: 1, folder: nil, pending: false))
        }
        return out
    }

    // MARK: Header and filters

    private func header(_ cur: Folder) -> some View {
        let rebuildable = cur.subfolders.filter { $0.rebuildable != nil && model.isReady($0) }
        return VStack(alignment: .leading, spacing: 6) {
            DSName(cur.name, .heading)
            DSText(
                model.showingLive && cur.parent == nil
                    ? "\(ByteCountFormatter.string(fromByteCount: model.chartedSize(cur), countStyle: .file)) so far"
                    : "\(ByteCountFormatter.string(fromByteCount: cur.size, countStyle: .file)) · \(cur.fileCount.formatted()) files",
                .metadata)
            if !rebuildable.isEmpty {
                Button {
                    model.markRebuildable()
                } label: {
                    Label(
                        String(localized: "Choose \(rebuildable.count) rebuildable (\(ByteCountFormatter.string(fromByteCount: rebuildable.reduce(0) { $0 + $1.size }, countStyle: .file)))"),
                        systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                // Wraps in a narrow list rather than running past its edge,
                // as a longer translation would.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
    }

    private var searchingWholeScan: Bool { model.browseFilter.wholeScan && model.index != nil }
    private var columnScope: String {
        if searchingWholeScan { return "diskMap.search" }
        return folderView == .tree && !model.browseFilter.isActive ? "diskMap.tree" : "diskMap.browse.2"
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                DSFilterField(String(localized: "Filter files and folders by name"), text: $model.browseFilter.query)
                    .frame(minWidth: 100, maxWidth: .infinity)
                DSFilterButton("Filter files and folders", detail: "Narrow the results below. The disk map and your removal choices stay the same.",
                               count: model.browseFilter.criteriaCount, clear: { model.browseFilter.clearCriteria() }) {
                    browseCriteria
                }
            }
            DSFlow(spacing: DS.Space.sm) {
                folderViewControl
                sortControl
                TableColumnsButton(scope: columnScope).fixedSize()
            }
            DSFlow(spacing: DS.Space.xs) {
                if let kind = model.browseFilter.kind {
                    DSFilterChip(title: String(localized: "Kind: \(kind.title)")) { model.browseFilter.kind = nil }
                }
                if model.browseFilter.date.isActive {
                    DSFilterChip(title: String(localized: "Modified: \(model.browseFilter.date.summary)")) { model.browseFilter.date = DateFilter() }
                }
            }
            Label(searchingWholeScan ? String(localized: "Results from the entire scan") : String(localized: "Results in this folder"),
                  systemImage: searchingWholeScan ? "internaldrive" : "folder")
                .font(.caption).foregroundStyle(.secondary)
            if folderView == .tree, model.browseFilter.isActive || searchingWholeScan {
                DSText("Filtered results use a list. Clear the filters and choose This Folder to return to the tree.", .metadata)
            }
            if !model.skipped.isEmpty {
                Label("\(model.skipped.count) folders excluded from the scan", systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(model.skipped.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
            }
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
        .controlSize(.small)
    }

    private var folderViewControl: some View {
        Picker("Folder View", selection: Binding(
            get: { model.browseFilter.isActive || searchingWholeScan ? .list : folderView },
            set: { if !model.browseFilter.isActive && !searchingWholeScan { folderView = $0 } }
        )) {
            Label("Tree", systemImage: "list.bullet.indent").tag(DiskFolderView.tree)
            Label("List", systemImage: "list.bullet").tag(DiskFolderView.list)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 118)
        .disabled(model.browseFilter.isActive || searchingWholeScan)
        .help("Tree opens several folder levels together. List shows one folder at a time. Filters show matching results as a list.")
    }

    private var sortControl: some View {
        Menu {
            Button("Largest First") { model.browseSort = .init(column: .size, ascending: false) }
            Button("Smallest First") { model.browseSort = .init(column: .size, ascending: true) }
            Divider()
            Button("Newest First") { model.browseSort = .init(column: .modified, ascending: false) }
            Button("Oldest First") { model.browseSort = .init(column: .modified, ascending: true) }
            Divider()
            Button("Name, A to Z") { model.browseSort = .init(column: .name, ascending: true) }
            Button("Kind") { model.browseSort = .init(column: .kind, ascending: true) }
            Button("Most Files First") { model.browseSort = .init(column: .items, ascending: false) }.disabled(searchingWholeScan)
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        .fixedSize()
        .help("Sort the results below. A folder's date is the latest change anywhere inside it.")
    }

    private var browseCriteria: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSControlField("Search in") {
                Picker("Search in", selection: $model.browseFilter.wholeScan) {
                    Text("This Folder").tag(false)
                    Text("Entire Scan").tag(true).disabled(model.index == nil)
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("disk.filter.scope")
                if model.index == nil {
                    DSText("Entire Scan becomes available when scanning finishes.", .metadata)
                } else {
                    DSText("Entire Scan includes folders and individual files of 1 MB or more. Smaller files are counted inside folders.", .metadata)
                }
            }
            DSControlField("Last modified") {
                DateFilterControl(filter: $model.browseFilter.date, showsLabel: false)
                DSText("For a folder, this is the newest change anywhere inside it.", .metadata)
            }
            DSControlField("Item kind") {
                Picker("Item kind", selection: $model.browseFilter.kind) {
                    Text("All Kinds").tag(FileKind?.none)
                    ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag(FileKind?.some($0)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("disk.filter.kind")
                DSText("A folder's kind is the type using most of its space.", .metadata)
            }
            Divider()
            SavedFiltersMenu(filter: $model.browseFilter)
            DSText("Saved filters remember these criteria and the name filter for reuse. They don't save, move or delete files.", .metadata)
        }
    }

    // MARK: Table

    private func tree(_ root: Folder) -> some View {
        let current = treeState.rootID == root.id && treeState.revision == model.revision
        let visible = current ? treeState.visible : []
        let selected = current ? model.selection.compactMap { treeState.byPath[$0] } : []
        let marks = Set(model.marked.keys)
        let allChosen = current && visible.allSatisfy { $0.pending || marks.contains($0.path) || Marked.parent(of: $0.path, in: marks) != nil }
        return VStack(spacing: 0) {
            DiskOutline(
                root: root, revision: model.revision, ready: model.isReady,
                state: treeState, selection: $model.selection, expanded: $model.treeExpanded,
                marks: model.opened == nil ? Set(model.marked.keys) : nil,
                row: fileRow,
                onToggle: { model.toggle($0.marked) },
                onOpen: { entries in
                    if entries.count == 1, let folder = entries[0].folder { model.open(folder) }
                    else { FileActions.reveal(entries.map(\.path)) }
                },
                onMark: { model.mark($0.map(\.marked)) },
                onSetMarks: { entries, checked in model.setListedMarks(entries.map(\.marked), checked: checked) },
                onHover: { entry in model.hovered = entry?.folder.map(Segment.folder) },
                menu: menu, onSmallFiles: { smallFilesOf = $0 }, sortRequest: model.browseSort)
            .dsEmptyOverlay(showing: model.currentIsEmpty) { emptyFolder }
            Divider()
            footer(root, rows: visible, all: visible, treeSelection: selected,
                   allChosen: !current || allChosen)
        }
    }

    private var emptyFolder: some View {
        ContentUnavailableView("No Items", systemImage: "folder",
            description: Text("This folder has no mapped contents."))
            .allowsHitTesting(false)
    }

    private func table(_ rows: [DiskEntry]) -> some View {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: rows.map(fileRow),
            columns: [.name, .size, .modified, .kind, .items, .location],
            hiddenByDefault: [.kind, .items, .location],
            autosave: "diskMap.browse.2",
            sortRequest: model.browseSort,
            selection: $model.selection,
            marks: model.opened == nil ? Set(model.marked.keys) : nil,
            onToggleMark: { id in byID[id].map { model.toggle($0.marked) } },
            onOpen: { ids in
                let chosen = ids.compactMap { byID[$0] }.filter { !$0.pending }
                if chosen.count == 1, let f = chosen[0].folder {
                    model.open(f)
                } else if !chosen.isEmpty {
                    FileActions.reveal(chosen.map(\.path))
                }
            },
            onMark: { ids in model.mark(ids.compactMap { byID[$0] }.filter { !$0.pending }.map(\.marked)) },
            onSetMarks: { ids, checked in
                if checked { model.mark(ids.compactMap { byID[$0] }.filter { !$0.pending }.map(\.marked)) }
                else { model.setListedMarks(ids.compactMap { byID[$0]?.marked }, checked: false) }
            },
            onHover: { id in
                let seg = id.flatMap { byID[$0]?.folder }.map(Segment.folder)
                if model.hovered != seg { model.hovered = seg }
            },
            menu: { ids in menu(ids.compactMap { byID[$0] }.filter { !$0.pending }, rows: rows) })
    }

    private func fileRow(_ e: DiskEntry) -> FileRow {
        let f = e.folder
        let modified = e.pending || e.modified == .distantPast ? nil : e.modified
        return FileRow(
            id: e.path, name: e.name, size: e.pending ? nil : e.size,
            modified: modified,
            kind: e.kindTitle, items: e.pending ? nil : e.items,
            location: (e.path as NSString).deletingLastPathComponent,
            symbol: f == nil ? e.kind.symbol : (f?.inheritedKind?.symbol ?? "folder.fill"),
            subtitle: modified.map { f == nil ? $0.listText : "\($0.listText) · \(e.items.formatted()) files" },
            tint: f == nil ? NSColor(ChartColors.kind(e.kind)) : palette.accentText.ns,
            badge: f?.rebuildable == nil ? nil : String(localized: "Rebuildable"),
            badgeHelp: f?.rebuildable.map { "\($0.label): \($0.reason)" },
            locked: !e.pending && f?.unreadable == true,
            choiceHelp: f?.wasNotScanned == true ? String(localized: "Not scanned before stopping. Scan Again to include this folder.") : nil,
            sizePlaceholder: f?.wasNotScanned == true ? String(localized: "Not scanned") : nil)
    }

    // MARK: Actions

    private func menu(_ chosen: [DiskEntry], rows: [DiskEntry]) -> [TableMenuEntry] {
        guard !chosen.isEmpty else { return [] }
        if model.opened != nil { return [.quickLook, .divider] + FileActions.menu(chosen.map(\.path)) }
        var out: [TableMenuEntry] = []
        if chosen.count == 1, let f = chosen[0].folder { out.append(.action(String(localized: "Open")) { model.open(f) }) }
        if chosen.count == 1, chosen[0].folder != nil, !model.scanning {
            let path = chosen[0].path
            out.append(.action(String(localized: "Don't Scan This Folder")) { model.skipFromNowOn(path) })
        }
        out.append(.quickLook)
        out.append(.divider)
        let readyPaths = Set(rows.filter { !$0.pending }.map(\.path))
        out.append(.action(String(localized: "Select All Listed")) { model.selection = readyPaths })
        out.append(.action(String(localized: "Invert Selection")) { model.selection = readyPaths.subtracting(model.selection) })
        out.append(.action(String(localized: "Check All Listed")) { model.setListedMarks(rows.filter { !$0.pending }.map(\.marked), checked: true) })
        out.append(.action(String(localized: "Uncheck All Listed")) { model.setListedMarks(rows.filter { !$0.pending }.map(\.marked), checked: false) })
        out.append(.divider)
        let marks = Set(model.marked.keys)
        let parents = Set(chosen.compactMap { Marked.parent(of: $0.path, in: marks) })
        let unmarked = chosen.filter { !model.isMarked($0.path) && Marked.parent(of: $0.path, in: marks) == nil }
        if !unmarked.isEmpty {
            out.append(.action(unmarked.count == 1 ? String(localized: "Choose for Removal") : String(localized: "Choose \(unmarked.count) for Removal")) {
                model.mark(unmarked.map(\.marked))
            })
        }
        if chosen.contains(where: { model.isMarked($0.path) }) {
            out.append(.action(String(localized: "Unchoose")) { model.unmark(chosen.map(\.path)) })
        }
        if !parents.isEmpty {
            out.append(.action(String(localized: "Unchoose Containing Folder")) { model.unmark(parents) })
        }
        if chosen.count == 1, chosen[0].modified > .distantPast {
            let date = chosen[0].modified
            let ready = rows.filter { !$0.pending }
            out.append(.divider)
            out.append(.submenu(String(localized: "Select by Date"), [
                .action(String(localized: "Changed On or Before \(date.listText)")) { model.selection = Set(ready.filter { $0.modified <= date }.map(\.id)) },
                .action(String(localized: "Changed On or After \(date.listText)")) { model.selection = Set(ready.filter { $0.modified >= date }.map(\.id)) },
                .action(String(localized: "Changed the Same Day")) {
                    model.selection = Set(ready.filter { Calendar.current.isDate($0.modified, inSameDayAs: date) }.map(\.id))
                },
            ]))
        }
        out.append(.divider)
        out += FileActions.menu(chosen.map(\.path))
        return out
    }

    private func markSelection(_ rows: [DiskEntry]) {
        model.mark(rows.filter { model.selection.contains($0.id) && !$0.pending }.map(\.marked))
    }

    // MARK: Footer

    private func footer(_ cur: Folder, rows: [DiskEntry], all: [DiskEntry], treeSelection: [DiskEntry]? = nil, allChosen: Bool? = nil)
        -> some View
    {
        let selected = treeSelection ?? rows.filter { model.selection.contains($0.id) }
        let outer = Set(Trasher.outermost(selected.map(\.path)))
        let selectedBytes = selected.filter { outer.contains($0.path) }.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                DSText(
                    selected.isEmpty
                        ? (rows.count == all.count ? "\(all.count) items" : "\(rows.count) of \(all.count) items")
                        : "\(selected.count) of \(rows.count) selected · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))",
                    .metadata)
                if cur.smallFileCount > 0 {
                    HStack(spacing: DS.Space.xs) {
                        DSText(
                            "+ \(cur.smallFileCount.formatted()) smaller files · \(ByteCountFormatter.string(fromByteCount: cur.smallFileBytes, countStyle: .file))",
                            .metadata)
                        Button("List") { smallFilesOf = cur.path }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .help("Read the files under 1 MB in this folder, a page at a time")
                    }
                }
            }
            DSFlow(spacing: DS.Space.sm) {
                Button(model.choosingContents ? "Reading Contents…" : "Choose All Contents") {
                    Task { await model.chooseAllContents() }
                }
                .disabled(model.opened != nil || model.choosingContents || model.trashing)
                .help("Choose every direct item in this folder, including hidden and smaller files. Filters don't limit this choice. The folder itself stays; nothing moves until you review and confirm.")
                .fixedSize()
                // Choosing ticks rows for the Trash; selecting (⌘A, ⇧-click) only highlights them.
                Button("Check All Listed") { model.mark(rows.filter { !$0.pending }.map(\.marked)) }
                    .disabled(model.opened != nil || (allChosen ?? rows.allSatisfy { $0.pending || model.isMarked($0.path) }))
                    .help("Tick every item listed here for the Trash. Nothing moves until you review and confirm.")
                    .fixedSize()
                Button(selected.isEmpty ? "Choose Selected" : "Choose \(selected.count) Selected") {
                    // ⌘⌫ in the filter field deletes the text, as everywhere else.
                    if MyMoleApp.sendToTextField(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                    model.mark(selected.filter { !$0.pending }.map(\.marked))
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.opened != nil || selected.allSatisfy(\.pending))
                .help("Tick the highlighted rows for the Trash (⌘⌫). Select rows with a click, ⇧ or ⌘, or ⌘A for all.")
                .fixedSize()
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
    }
}

extension Date {
    /// Finder's list style: "Today 08:42", "Yesterday 17:03", else the date.
    var listText: String {
        guard self > .distantPast else { return "—" }
        let cal = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(self) { return String(localized: "Today \(time)") }
        if cal.isDateInYesterday(self) { return String(localized: "Yesterday \(time)") }
        return formatted(date: .abbreviated, time: .omitted)
    }
}

/// A thin proportional bar under a row.
struct ShareBar: View {
    @Environment(\.palette) private var palette
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(palette.accentText.color.opacity(0.55))
                .frame(width: max(2, g.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: 3)
    }
}

/// One match of a search through the whole scan.
struct ScanHit: Sendable, Identifiable {
    let path: String
    let name: String
    let size: Int64
    let modified: Date
    let kind: FileKind
    let isFolder: Bool
    var id: String { path }
    var marked: Marked { Marked(path: path, name: name, size: size, isFolder: isFolder) }
}

/// The Browse filter applied to every folder and listed file of the scan,
/// worked out off the main thread from the scan's index.
private struct WholeScanSearch: View {
    @Bindable var model: StorageModel
    let index: ScanIndex
    /// The matches in memory, or on disk once they're past the memory set in Large results.
    @State private var result = OffMain<(hits: [ScanHit], more: Bool, spill: SpillTable?)>(([], false, nil))

    private struct Key: Equatable {
        let filter: BrowseFilter
        let revision: Int
    }

    var body: some View {
        // What a move since took out of the map isn't offered.
        let hits = result.value.hits
        let byID = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            if let spill = result.value.spill {
                spilledMatches(spill)
            } else {
                FileTable(
                    rows: hits.map(row),
                    columns: [.name, .size, .modified, .kind, .location],
                    hiddenByDefault: [.modified, .kind],
                    autosave: "diskMap.search",
                    sortRequest: model.browseSort,
                    selection: $model.selection,
                    marks: model.opened == nil ? Set(model.marked.keys) : nil,
                    onToggleMark: { id in byID[id].map { model.toggle($0.marked) } },
                    onOpen: { ids in
                        let chosen = ids.compactMap { byID[$0] }
                        if chosen.count == 1, chosen[0].isFolder {
                            model.browseFilter = BrowseFilter()
                            model.show(folder: chosen[0].path)
                        } else if !chosen.isEmpty {
                            FileActions.reveal(chosen.map(\.path))
                        }
                    },
                    onMark: { ids in model.mark(ids.compactMap { byID[$0] }.map(\.marked)) },
                    onSetMarks: { ids, checked in
                        if checked { model.mark(ids.compactMap { byID[$0] }.map(\.marked)) }
                        else { model.setListedMarks(ids.compactMap { byID[$0]?.marked }, checked: false) }
                    },
                    menu: { ids in
                        let chosen = ids.compactMap { byID[$0] }
                        guard !chosen.isEmpty else { return [] }
                        return [
                            .quickLook,
                            .action(String(localized: "Show in Map")) {
                                let target = chosen[0]
                                model.browseFilter = BrowseFilter()
                                model.show(folder: target.isFolder ? target.path : (target.path as NSString).deletingLastPathComponent, select: target.isFolder ? nil : target.path)
                            },
                            .divider,
                            .action(String(localized: "Choose for Removal")) { model.mark(chosen.map(\.marked)) },
                            .divider,
                        ] + FileActions.menu(chosen.map(\.path))
                    })
                .overlay {
                    if hits.isEmpty, result.value.spill == nil, !result.working {
                        ContentUnavailableView("No Matching Items", systemImage: "line.3.horizontal.decrease",
                            description: Text("Adjust or clear the filters above to see more files and folders."))
                            .allowsHitTesting(false)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 1) {
                DSText(String(localized: "\((result.value.spill?.count ?? hits.count).formatted()) found in the whole scan"), .metadata)
                DSText(String(localized: "Files under 1 MB are counted per folder, not searched."), .metadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
        }
        .task(id: Key(filter: model.browseFilter, revision: model.revision)) {
            let (index, filter, root) = (index, model.browseFilter, model.root)
            let (budget, base) = (model.largeResultBudget(), model.spillBase)
            await result.update(count: index.entries.count) {
                // Every match, however many; only what's still in the map
                // after a move, checked here rather than on every redraw.
                let r = index.search(filter.query, limit: .max) { e in
                    (filter.kind == nil || e.kind == filter.kind) && filter.date.matches(e.modified)
                }
                let hits = r.found.compactMap { i -> ScanHit? in
                    let e = index.entries[i]
                    let path = index.path(i)
                    guard let root, StorageModel.holds(root, path) else { return nil }
                    return ScanHit(path: path, name: e.name, size: e.size, modified: e.modified, kind: e.kind, isFolder: e.isFolder)
                }
                // Past the budget the matches go to disk; a failed write keeps them in memory.
                if let budget, ResultSize.memoryCost(pathBytes: hits.reduce(0) { $0 + $1.path.utf8.count }, rows: hits.count) > budget,
                   let spill = try? SpillTable(writing: hits.lazy.map {
                       SpillTable.Row(path: $0.path, size: $0.size, modified: $0.modified, kind: $0.kind, isFolder: $0.isFolder)
                   }, in: base) {
                    return ([], r.more, spill)
                }
                return (hits, r.more, nil)
            }
        }
    }

    /// The matches kept on disk: the same choices, read a page at a time.
    @ViewBuilder private func spilledMatches(_ spill: SpillTable) -> some View {
        PagedFileTable(
            table: spill, columns: [.name, .size, .modified, .kind, .location], hiddenByDefault: [.modified, .kind],
            autosave: "diskMap.search", filterKey: AnyHashable(ObjectIdentifier(spill)), keep: { _ in true },
            selection: $model.selection,
            marks: model.opened == nil ? Set(model.marked.keys) : nil,
            onToggleMark: { r in model.toggle(Marked(path: r.path, name: r.name, size: r.size, isFolder: r.isFolder)) },
            onOpen: { paths in
                if paths.count == 1, let path = paths.first, model.root?.find(path: path) != nil {
                    model.browseFilter = BrowseFilter()
                    model.show(folder: path)
                } else {
                    FileActions.reveal(paths)
                }
            },
            menu: { ids in
                guard !ids.isEmpty else { return [] }
                return [
                    .action(String(localized: "Choose for Removal")) { chooseSpilled(Set(ids), from: spill) },
                    .divider,
                ] + FileActions.menu(ids)
            })
    }

    /// Chooses the matches whose paths are in `paths`, read from the table off the main thread.
    private func chooseSpilled(_ paths: Set<String>, from spill: SpillTable) {
        Task {
            let chosen = await Task.detached(priority: .userInitiated) { () -> [Marked] in
                (0..<spill.count).compactMap { i in
                    guard let r = spill.row(at: i), paths.contains(r.path) else { return nil }
                    return Marked(path: r.path, name: r.name, size: r.size, isFolder: r.isFolder)
                }
            }.value
            guard result.value.spill === spill else { return }
            model.mark(chosen)
        }
    }

    private func row(_ h: ScanHit) -> FileRow {
        FileRow(
            id: h.path, name: h.name, size: h.size, modified: h.modified == .distantPast ? nil : h.modified,
            kind: h.isFolder ? String(localized: "Folder") : h.kind.title,
            location: (h.path as NSString).deletingLastPathComponent,
            symbol: h.isFolder ? "folder.fill" : h.kind.symbol)
    }
}

/// The Browse filters the user saved: apply one, save the one in use, or
/// forget one.
private struct SavedFiltersMenu: View {
    @Binding var filter: BrowseFilter
    @State private var saved = SavedFilter.all()

    var body: some View {
        Menu {
            if saved.isEmpty { Text("No Saved Filters") }
            ForEach(saved) { s in Button(s.name) { filter = s.filter } }
            if !saved.isEmpty { Divider() }
            Button("Save Current Filter") {
                let name = SavedFilter.name(for: filter)
                saved = saved.filter { $0.name != name } + [SavedFilter(name: name, filter: filter)]
                SavedFilter.save(saved)
            }
            .disabled(!filter.isActive)
            if !saved.isEmpty {
                Menu("Remove Saved Filter") {
                    ForEach(saved) { s in
                        Button(s.name) {
                            saved.removeAll { $0.name == s.name }
                            SavedFilter.save(saved)
                        }
                    }
                }
            }
        } label: {
            Label("Saved Filters", systemImage: "bookmark")
        }
        .fixedSize()
        .help("Filters you saved, and saving the one in use")
    }
}

/// The files under 1 MB in one folder, which a scan only counts: read from
/// the disk when asked, a page at a time, so a folder of a hundred
/// thousand small files never makes one long list at once.
struct SmallFilesSheet: View {
    struct Target: Identifiable {
        let path: String
        var id: String { path }
    }

    let folder: String
    /// A scan opened from a file: the folder may not be on this Mac.
    let readOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String]?
    @State private var shown = 0
    @State private var rows: [FileRow] = []
    @State private var selection = Set<String>()
    @State private var problem: String?
    static let page = 500

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Smaller Files").font(.title2.bold())
            DSPath(folder, .mono)
            DSText(
                "Visible files using less than 1 MB on disk, read a page at a time. Use Quick Look to inspect them; this list is for browsing.", .metadata)
            if let problem {
                DSNotice(.warning, problem)
            } else if names == nil {
                DSLoading("Reading the folder…").frame(height: 320)
            } else {
                FileTable(
                    rows: rows, columns: [.name, .size, .modified, .location], hiddenByDefault: [.location],
                    autosave: "diskMap.smallFiles", selection: $selection, marks: nil,
                    onOpen: { FileActions.reveal($0) },
                    menu: { ids in FileActions.inspectionMenu(ids) }
                )
                .frame(height: 320)
            }
            DSActionGroup {
                if let names {
                    DSText(String(localized: "\(min(shown, names.count).formatted()) of \(names.count.formatted()) names read"), .metadata)
                }
            } trailing: {
                if let names, shown < names.count {
                    Button("Read \(min(Self.page, names.count - shown)) More") { Task { await readPage() } }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogKeyboard()
        .task { await start() }
    }

    private func start() async {
        let folder = folder
        let listed = await Task.detached(priority: .userInitiated) { DirectoryListing.names(folder) }.value
        guard let listed else {
            problem = readOnly
                ? String(localized: "This folder isn't on this Mac, or can't be read: a saved scan only knows how many small files it had.")
                : String(localized: "The folder couldn't be read.")
            return
        }
        names = listed.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        await readPage()
    }

    /// The next page of names, measured; only plain files under 1 MB.
    private func readPage() async {
        guard let names else { return }
        let slice = Array(names[shown..<min(names.count, shown + Self.page)])
        let folder = folder
        let more = await Task.detached(priority: .userInitiated) { () -> [FileRow] in
            slice.compactMap { name in
                let path = folder + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
                let bytes = Int64(st.st_blocks) * 512
                guard bytes < Folder.listedFileSize else { return nil }
                return FileRow(
                    id: path, name: name, size: bytes, modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                    location: folder, symbol: Classifier.kind(ofFile: name).symbol)
            }
        }.value
        shown += slice.count
        rows += more
    }
}
