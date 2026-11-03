import StorageKit
import SwiftUI

/// One row of the Browse list: a subfolder or a listed file of the open folder.
struct DiskEntry: Identifiable {
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
    @Bindable var model: StorageModel

    var body: some View {
        if let cur = model.current {
            let all = entries(cur)
            let rows = all.filter(model.browseFilter.matches)
            VStack(spacing: 0) {
                header(cur)
                filterBar
                Divider()
                table(rows)
                Divider()
                footer(cur, rows: rows, all: all)
            }
        }
    }

    // MARK: Rows

    private func entries(_ cur: Folder) -> [DiskEntry] {
        let base = cur.path == "/" ? "" : cur.path
        var out: [DiskEntry] = []
        out.reserveCapacity(cur.subfolders.count + cur.listedFiles.count)
        for f in cur.subfolders {
            let kindTitle = f.inheritedKind.map { "\($0.title) Folder" } ?? "Folder"
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
        let rebuildable = cur.subfolders.filter { $0.rebuildable != nil && !model.isPending($0) }
        return VStack(alignment: .leading, spacing: 6) {
            DSName(cur.name, .heading)
            DSText(
                model.scanning && cur.parent == nil
                    ? "\(ByteCountFormatter.string(fromByteCount: model.chartedSize(cur), countStyle: .file)) so far"
                    : "\(ByteCountFormatter.string(fromByteCount: cur.size, countStyle: .file)) · \(cur.fileCount.formatted()) files",
                .metadata)
            if !rebuildable.isEmpty {
                Button {
                    model.markRebuildable()
                } label: {
                    Label(
                        "Mark \(rebuildable.count) rebuildable (\(ByteCountFormatter.string(fromByteCount: rebuildable.reduce(0) { $0 + $1.size }, countStyle: .file)))",
                        systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.md)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSFilterField("Filter by name", text: $model.browseFilter.query)
            HStack(spacing: DS.Space.sm) {
                DateFilterControl(filter: $model.browseFilter.date)
                Menu {
                    Picker("Kind", selection: $model.browseFilter.kind) {
                        Text("All Kinds").tag(FileKind?.none)
                        Divider()
                        ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag(FileKind?.some($0)) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(model.browseFilter.kind?.title ?? "Kind", systemImage: "square.grid.2x2")
                }
                .fixedSize()
                .help("Show only one kind of item; a folder counts as the kind most of its space is")
                Spacer(minLength: 0)
                if model.browseFilter.isActive {
                    Button("Clear") { model.browseFilter = BrowseFilter() }
                        .buttonStyle(.borderless)
                        .fixedSize()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.md)
        .padding(.bottom, DS.Space.sm)
    }

    // MARK: Table

    private func table(_ rows: [DiskEntry]) -> some View {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: rows.map(fileRow),
            columns: [.name, .size, .modified, .kind, .items],
            hiddenByDefault: [.modified, .kind, .items],
            autosave: "diskMap.browse.2",
            selection: $model.selection,
            marks: Set(model.marked.keys),
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
            symbol: f == nil ? e.kind.symbol : (f?.inheritedKind?.symbol ?? "folder.fill"),
            subtitle: modified.map { f == nil ? $0.listText : "\($0.listText) · \(e.items.formatted()) files" },
            tint: f == nil ? NSColor(ChartColors.kind(e.kind)) : NSColor(Theme.accent),
            badge: f?.rebuildable == nil ? nil : "Rebuildable",
            badgeHelp: f?.rebuildable.map { "\($0.label): \($0.reason)" },
            locked: !e.pending && f?.unreadable == true)
    }

    // MARK: Actions

    private func menu(_ chosen: [DiskEntry], rows: [DiskEntry]) -> [TableMenuEntry] {
        guard !chosen.isEmpty else { return [] }
        var out: [TableMenuEntry] = []
        if chosen.count == 1, let f = chosen[0].folder { out.append(.action("Open") { model.open(f) }) }
        out.append(.quickLook)
        out.append(.divider)
        let unmarked = chosen.filter { !model.isMarked($0.path) }
        if !unmarked.isEmpty {
            out.append(.action(unmarked.count == 1 ? "Mark for Removal" : "Mark \(unmarked.count) for Removal") {
                model.mark(unmarked.map(\.marked))
            })
        }
        if unmarked.count < chosen.count {
            out.append(.action("Unmark") { model.unmark(chosen.map(\.path)) })
        }
        if chosen.count == 1, chosen[0].modified > .distantPast {
            let date = chosen[0].modified
            let ready = rows.filter { !$0.pending }
            out.append(.divider)
            out.append(.submenu("Select by Date", [
                .action("Changed On or Before \(date.listText)") { model.selection = Set(ready.filter { $0.modified <= date }.map(\.id)) },
                .action("Changed On or After \(date.listText)") { model.selection = Set(ready.filter { $0.modified >= date }.map(\.id)) },
                .action("Changed the Same Day") {
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

    private func footer(_ cur: Folder, rows: [DiskEntry], all: [DiskEntry]) -> some View {
        let selected = rows.filter { model.selection.contains($0.id) }
        let selectedBytes = selected.reduce(0) { $0 + $1.size }
        return HStack(spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: 1) {
                DSText(
                    selected.isEmpty
                        ? (rows.count == all.count ? "\(all.count) items" : "\(rows.count) of \(all.count) items")
                        : "\(selected.count) of \(rows.count) selected · \(ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file))",
                    .metadata)
                if cur.smallFileCount > 0 {
                    DSText(
                        "+ \(cur.smallFileCount.formatted()) smaller files · \(ByteCountFormatter.string(fromByteCount: cur.smallFileBytes, countStyle: .file))",
                        .metadata)
                }
            }
            Spacer(minLength: DS.Space.sm)
            Button("Select All") { model.selection = Set(rows.filter { !$0.pending }.map(\.id)) }
                .disabled(rows.isEmpty)
                .fixedSize()
            Button("Mark") { markSelection(rows) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected.isEmpty)
                .help("Mark the selected items for removal (⌘⌫)")
                .fixedSize()
        }
        .controlSize(.small)
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
        if cal.isDateInToday(self) { return "Today \(time)" }
        if cal.isDateInYesterday(self) { return "Yesterday \(time)" }
        return formatted(date: .abbreviated, time: .omitted)
    }
}

/// A thin proportional bar under a row.
struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            Capsule()
                .fill(Theme.accent.opacity(0.55))
                .frame(width: max(2, g.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: 3)
    }
}
