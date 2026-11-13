import StorageKit
import SwiftUI

/// Every file of 1 MB or more in the scan, in one Finder-style table
/// (`FileTable`): filter by kind, place, date or name, sort by any column, tick as
/// many as you like. Files appear while the scan is still running.
struct LargeFilesView: View {
    @Bindable var model: StorageModel
    /// Kept while you go to other panes and back, as the window's own state.
    @SceneStorage("largeFiles.filter") private var query = ""
    @State private var kind: FileKind?
    @State private var date = DateFilter()
    @State private var place: Place = .anywhere
    @State private var reviewingDownloads = false
    @State private var selection = Set<String>()
    /// The rows a list kept on disk shows now, in order.
    @State private var spilledOrder: [UInt32] = []

    /// Where the files are: anywhere in the map, or in one of the folders
    /// downloads and old work pile up in. With "Older than" it finds old downloads.
    enum Place: String, CaseIterable, Identifiable {
        case anywhere, downloads, desktop, documents
        var id: String { rawValue }

        var title: String {
            switch self {
            case .anywhere: String(localized: "Anywhere")
            case .downloads: String(localized: "In Downloads")
            case .desktop: String(localized: "On the Desktop")
            case .documents: String(localized: "In Documents")
            }
        }

        nonisolated func folder(home: String) -> String? {
            switch self {
            case .anywhere: nil
            case .downloads: home + "/Downloads"
            case .desktop: home + "/Desktop"
            case .documents: home + "/Documents"
            }
        }

        nonisolated func contains(_ f: LargeFile, home: String = Home.path) -> Bool {
            contains(folder: f.folder, home: home)
        }

        nonisolated func contains(folder path: String, home: String = Home.path) -> Bool {
            folder(home: home).map { path == $0 || path.hasPrefix($0 + "/") } ?? true
        }
    }

    /// The files the filters let through, worked out off the main thread.
    @State private var filtered = OffMain<[LargeFile]>([])
    private var rows: [LargeFile] { model.largeFiles.isEmpty ? [] : filtered.value }

    private struct FilterKey: Equatable {
        let files: [LargeFile]
        let kind: FileKind?
        let place: Place
        let date: DateFilter
        let query: String
    }

    private func refilter() async {
        let (files, kind, place, date, query) = (model.largeFiles, kind, place, date, query)
        let search = TextQuery(query)
        await filtered.update(count: files.count) {
            files.filter { f in
                (kind == nil || f.kind == kind)
                    && place.contains(f)
                    && date.matches(f.modified)
                    && search.matches(f.name, f.folder)
            }
        }
    }

    var body: some View {
        let shown = rows
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = shown.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    DSFilterField(String(localized: "Filter by name or folder"), text: $query)
                        .frame(minWidth: 140, maxWidth: .infinity)
                    DSFilterButton("Filter large files", detail: "Narrow this list of files of 1 MB or more. The disk map and your removal choices stay the same.",
                                   count: filterCount, clear: clearFilters) { criteria }
                    TableColumnsButton(scope: "diskMap.largeFiles").fixedSize()
                }
                DSFlow(spacing: DS.Space.xs) {
                    if let kind { DSFilterChip(title: String(localized: "Kind: \(kind.title)")) { self.kind = nil } }
                    if place != .anywhere { DSFilterChip(title: place.title) { place = .anywhere } }
                    if date.isActive { DSFilterChip(title: String(localized: "Modified: \(date.summary)")) { date = DateFilter() } }
                    if place == .downloads {
                        Button("Review All Downloads…") { reviewingDownloads = true }
                            .help("Includes small downloads too. Opens a separate review; nothing is chosen for you.")
                    }
                }
                DSText("Every file of 1 MB or more from the current scan", .metadata)
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.vertical, DS.Space.md)
            Divider()

            if let spill = model.largeFilesSpill {
                spilledList(spill)
            } else {
                FileTable(
                    rows: shown.map(fileRow),
                    columns: [.name, .size, .modified, .kind, .location],
                    hiddenByDefault: [.kind],
                    autosave: "diskMap.largeFiles",
                    selection: $selection,
                    marks: model.opened == nil ? Set(model.marked.keys) : nil,
                    onToggleMark: { id in byID[id].map { model.toggle($0.marked) } },
                    onOpen: { ids in FileActions.reveal(ids) },
                    onMark: { ids in model.mark(ids.compactMap { byID[$0] }.map(\.marked)) },
                    onSetMarks: { ids, checked in
                        if checked { model.mark(ids.compactMap { byID[$0] }.map(\.marked)) }
                        else { model.unmark(ids) }
                    },
                    menu: { ids in menu(ids.compactMap { byID[$0] }, rows: shown) })
                    .dsEmptyOverlay(showing: rows.isEmpty) { emptyState.allowsHitTesting(false) }
                Divider()
                DSActionGroup {
                    HStack(spacing: DS.Space.sm) {
                        if model.scanning || filtered.working { PulseDot() }
                        DSText(counts(shown: shown, picked: picked), .metadata)
                    }
                } trailing: {
                    Button("Check All Listed") { model.mark(shown.map(\.marked)) }
                        .disabled(shown.isEmpty || shown.allSatisfy { model.marked[$0.path] != nil })
                        .help("Choose only the files shown by the current filters. Nothing moves until you confirm.")
                    Button(picked.isEmpty ? "Choose Selected" : "Choose \(picked.count) Selected") {
                        if MyMoleApp.sendToTextField(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                        model.mark(picked.map(\.marked))
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(picked.isEmpty)
                }
                .controlSize(.small)
                .padding(.horizontal, DS.Space.page)
                .padding(.vertical, DS.Space.sm)
            }
        }
        .task(id: FilterKey(files: model.largeFiles, kind: kind, place: place, date: date, query: query)) { await refilter() }
        .sheet(isPresented: $reviewingDownloads) { DownloadsReviewSheet(model: model) }
    }

    private struct SpillKey: Hashable {
        let table: ObjectIdentifier
        let kind: FileKind?
        let place: Place
        let date: DateFilter
        let query: String
        let removed: [String]
    }

    /// The list kept on disk because it's past the memory budget of Large
    /// results: the same filters and choices, read a page at a time.
    @ViewBuilder private func spilledList(_ spill: SpillTable) -> some View {
        let (kind, place, date, search, inMap) = (kind, place, date, TextQuery(query), model.spillKeep)
        let home = Home.path
        let keep: @Sendable (SpillTable.Row) -> Bool = { r in
            inMap(r) && (kind == nil || r.kind == kind) && place.contains(folder: r.folder, home: home)
                && date.matches(r.modified) && search.matches(r.name, r.folder)
        }
        PagedFileTable(
            table: spill, columns: [.name, .size, .modified, .kind, .location], hiddenByDefault: [.kind],
            autosave: "diskMap.largeFiles",
            filterKey: AnyHashable(SpillKey(table: ObjectIdentifier(spill), kind: kind, place: place, date: date, query: query, removed: model.spillRemoved)),
            keep: keep, selection: $selection,
            marks: model.opened == nil ? Set(model.marked.keys) : nil,
            onToggleMark: { r in model.toggle(Marked(path: r.path, name: r.name, size: r.size, isFolder: false)) },
            onOpen: { FileActions.reveal($0) },
            menu: { ids in
                var entries: [TableMenuEntry] = []
                if model.opened == nil {
                    entries += [.action(ids.count == 1 ? String(localized: "Choose for Removal") : String(localized: "Choose \(ids.count) for Removal")) {
                        chooseSpilled(Set(ids), from: spill)
                    }, .divider]
                }
                return entries + FileActions.menu(ids)
            },
            onOrdered: { spilledOrder = $0 })
        Divider()
        DSActionGroup {
            HStack(spacing: DS.Space.sm) {
                if model.scanning { PulseDot() }
                DSText(String(localized: "\(spilledOrder.count.formatted()) files · kept on disk, past the memory set in Large results"), .metadata)
            }
        } trailing: {
            Button("Check All Listed") { chooseSpilled(nil, from: spill) }
                .disabled(spilledOrder.isEmpty || model.opened != nil)
                .help("Choose only the files shown by the current filters. Nothing moves until you confirm.")
            Button(selection.isEmpty ? "Choose Selected" : "Choose \(selection.count) Selected") {
                if MyMoleApp.sendToTextField(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                chooseSpilled(selection, from: spill)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection.isEmpty || model.opened != nil)
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.sm)
    }

    /// Chooses the listed rows whose paths are in `paths` (every listed row
    /// for nil), read from the table off the main thread.
    private func chooseSpilled(_ paths: Set<String>?, from spill: SpillTable) {
        let order = spilledOrder
        Task {
            let chosen = await Task.detached(priority: .userInitiated) { () -> [Marked] in
                order.compactMap { n in
                    guard let r = spill.row(at: Int(n)), paths?.contains(r.path) ?? true else { return nil }
                    return Marked(path: r.path, name: r.name, size: r.size, isFolder: false)
                }
            }.value
            guard model.largeFilesSpill === spill else { return }
            model.mark(chosen)
        }
    }

    @ViewBuilder private var emptyState: some View {
            if !model.largeFiles.isEmpty, rows.isEmpty, !filtered.working {
                ContentUnavailableView("No Matching Files", systemImage: "line.3.horizontal.decrease",
                    description: Text("Try another name, kind, date or location, or clear the filters above."))
            } else if model.largeFiles.isEmpty {
                if model.scanning {
                    CenterCard(symbol: nil, title: "Looking for large files…", subtitle: "They appear here as the scan finds them.") {}
                } else {
                    ContentUnavailableView(
                        "No Large Files", systemImage: "doc.badge.ellipsis",
                        description: Text("Nothing of 1 MB or more in this scan."))
                }
            }
    }

    private var filterCount: Int { (query.isEmpty ? 0 : 1) + (kind == nil ? 0 : 1) + (place == .anywhere ? 0 : 1) + (date.isActive ? 1 : 0) }
    private func clearFilters() { query = ""; kind = nil; place = .anywhere; date = DateFilter() }

    private var criteria: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSControlField("File kind") {
                Picker("File kind", selection: $kind) {
                    Text("All Kinds").tag(FileKind?.none)
                    ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag(FileKind?.some($0)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            DSControlField("Location within this scan") {
                Picker("Location", selection: $place) {
                    ForEach(Place.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                DSText("Choose a familiar folder to narrow the scanned results.", .metadata)
                if place == .downloads {
                    DSText("Review All Downloads above the list also includes smaller files.", .metadata)
                }
            }
            DSControlField("Last modified") {
                DateFilterControl(filter: $date, showsLabel: false)
                DSText("An old modification date doesn't mean a file is safe to remove.", .metadata)
            }
        }
    }

    private func fileRow(_ f: LargeFile) -> FileRow {
        FileRow(
            id: f.path, name: f.name, size: f.size, modified: f.modified, kind: f.kind.title,
            location: f.folder, symbol: f.kind.symbol, tint: NSColor(ChartColors.kind(f.kind)))
    }

    /// "1,204 files · 38 GB", "so far" while the scan still adds to them,
    /// or how many of them are selected.
    private func counts(shown: [LargeFile], picked: [LargeFile]) -> String {
        func size(_ files: [LargeFile]) -> String {
            let bytes = files.reduce(0) { $0 + $1.size }
            guard files.contains(where: { $0.reclaim != nil }) else { return ByteSize.format(bytes) }
            return Freeing.phrase(bytes, frees: files.reduce(Reclaim()) { $0 + ($1.reclaim ?? Reclaim(bytes: $1.size)) }.bytes)
        }
        let all = shown.count.formatted()
        guard picked.isEmpty else {
            return String(localized: "\(picked.count.formatted()) of \(all) selected · \(size(picked))")
        }
        return model.scanning
            ? String(localized: "\(all) files · \(size(shown)) so far") : String(localized: "\(all) files · \(size(shown))")
    }

    private func menu(_ chosen: [LargeFile], rows: [LargeFile]) -> [TableMenuEntry] {
        guard !chosen.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook]
        if chosen.count == 1, !model.scanning {
            out.append(.action(String(localized: "Show in Disk Map")) { model.show(folder: chosen[0].folder, select: chosen[0].path) })
        }
        out.append(.divider)
        let unmarked = chosen.filter { !model.isMarked($0.path) }
        if !unmarked.isEmpty {
            out.append(.action(unmarked.count == 1 ? String(localized: "Choose for Removal") : String(localized: "Choose \(unmarked.count) for Removal")) {
                model.mark(unmarked.map(\.marked))
            })
        }
        if unmarked.count < chosen.count {
            out.append(.action(String(localized: "Unchoose")) { model.unmark(chosen.map(\.path)) })
        }
        if chosen.count == 1 {
            let d = chosen[0].modified
            let folder = chosen[0].folder
            out.append(.divider)
            out.append(.submenu(String(localized: "Select by Date"), [
                .action(String(localized: "Changed On or Before \(d.listText)")) { selection = Set(rows.filter { $0.modified <= d }.map(\.id)) },
                .action(String(localized: "Changed On or After \(d.listText)")) { selection = Set(rows.filter { $0.modified >= d }.map(\.id)) },
                .action(String(localized: "Changed the Same Day")) {
                    selection = Set(rows.filter { Calendar.current.isDate($0.modified, inSameDayAs: d) }.map(\.id))
                },
            ]))
            out.append(.action(String(localized: "Select All in This Folder")) { selection = Set(rows.filter { $0.folder == folder }.map(\.id)) })
        }
        out.append(.divider)
        out += FileActions.menu(chosen.map(\.path))
        return out
    }
}

/// Everything in Downloads, small files too, oldest first, a page at a
/// time. Nothing starts chosen, and age is only shown, never taken as a
/// sign that something can go.
struct DownloadsReviewSheet: View {
    let model: StorageModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DownloadsReview.Item]?
    @State private var truncated = false
    @State private var shown = DownloadsReviewSheet.page
    @State private var selection = Set<String>()
    @State private var date = DateFilter()
    static let page = 500

    private var folder: String { Home.path + "/Downloads" }
    /// Chosen items go through the Disk Map's review, so only while it maps Downloads.
    private var canChoose: Bool {
        model.opened == nil && !model.scanning && (folder == model.rootPath || folder.hasPrefix(model.rootPath + "/"))
    }

    var body: some View {
        let all = (items ?? []).filter { date.matches($0.modified) }
        let page = Array(all.prefix(shown))
        let byID = Dictionary(page.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Every Download").font(.title2.bold())
            DSText(
                "Everything in Downloads, oldest first. An old file isn't junk for being old: look at it first. Nothing is chosen for you.",
                .metadata)
            DSControlField("Last modified") {
                DateFilterControl(filter: $date, showsLabel: false)
            }
            if items == nil {
                DSLoading("Reading Downloads…").frame(height: 360)
            } else {
                FileTable(
                    rows: page.map { i in
                        FileRow(
                            id: i.path, name: i.name, size: i.bytes, modified: i.modified, kind: i.kind.title,
                            location: (i.path as NSString).deletingLastPathComponent, symbol: i.kind.symbol)
                    },
                    columns: [.name, .size, .modified, .kind, .location], hiddenByDefault: [.location],
                    autosave: "downloads.review", defaultSort: .modified, selection: $selection, marks: canChoose ? Set(model.marked.keys) : nil,
                    onToggleMark: { id in
                        if canChoose, let i = byID[id] {
                            model.toggle(Marked(path: i.path, name: i.name, size: i.bytes, isFolder: i.isFolder))
                        }
                    },
                    onOpen: { FileActions.reveal($0) },
                    onSetMarks: { ids, checked in
                        guard canChoose else { return }
                        if checked {
                            model.mark(ids.compactMap { byID[$0] }.map {
                                Marked(path: $0.path, name: $0.name, size: $0.bytes, isFolder: $0.isFolder)
                            })
                        } else { model.unmark(ids) }
                    },
                    menu: { ids in
                        var out: [TableMenuEntry] = [.quickLook, .divider] + FileActions.menu(ids)
                        if canChoose {
                            out.append(.divider)
                            out.append(
                                .action(String(localized: "Choose for Removal")) {
                                    model.mark(
                                        ids.compactMap { byID[$0] }.map {
                                            Marked(path: $0.path, name: $0.name, size: $0.bytes, isFolder: $0.isFolder)
                                        })
                                })
                        }
                        return out
                    }
                )
                .frame(height: 360)
            }
            DSActionGroup {
                DSText(
                    String(localized: "\(page.count.formatted()) of \(all.count.formatted())")
                        + (truncated ? String(localized: " · only the first \(DownloadsReview.limit.formatted()) items were read") : ""),
                    .metadata)
                if !canChoose {
                    DSText("Map your home folder in Disk Map to choose from here.", .metadata)
                }
            } trailing: {
                if all.count > shown { Button("Show \(min(Self.page, all.count - shown)) More") { shown += Self.page } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        .dialogKeyboard()
        .task {
            let folder = folder
            let read = await Task.detached(priority: .userInitiated) { DownloadsReview.list(folder) }.value
            items = read.items
            truncated = read.truncated
        }
    }
}
