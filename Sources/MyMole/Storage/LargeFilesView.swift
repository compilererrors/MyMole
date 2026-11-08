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
            folder(home: home).map { f.folder == $0 || f.folder.hasPrefix($0 + "/") } ?? true
        }
    }

    /// The files the filters let through, worked out off the main thread.
    @State private var filtered = OffMain<[LargeFile]>([])
    private var rows: [LargeFile] { filtered.value }

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
            DSControlBar(
                "Find large files",
                detail: "Filters change this list of files of 1 MB or more. Choosing only ticks files for review before they move."
            ) {
                DSControlField("Filter by name or folder") {
                    DSFilterField(String(localized: "Filter by name or folder"), text: $query)
                        .frame(width: 240)
                }
                DSControlField("File kind") {
                    Picker("Kind", selection: $kind) {
                        Text("All Kinds").tag(FileKind?.none)
                        Divider()
                        ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag(FileKind?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                DSControlField("Location") {
                    Picker("Place", selection: $place) {
                        ForEach(Place.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Only files in this folder; with Older than, old downloads")
                    if place == .downloads {
                        Button("Every Download…") { reviewingDownloads = true }
                            .fixedSize()
                            .help("Go through everything in Downloads, small files too, oldest first")
                    }
                }
                DSControlField("Last modified") {
                    DateFilterControl(filter: $date, showsLabel: false)
                }
                DSControlField("Results") {
                    HStack(spacing: DS.Space.xs) {
                        if model.scanning { PulseDot() }
                        DSText(counts(shown: shown, picked: picked), .metadata).keepWhole()
                    }
                    if model.largeFiles.count >= StorageModel.largeFileLimit {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help(
                                "Only the \(StorageModel.largeFileLimit.formatted()) largest files of the scan are listed. Open a folder in Browse to see the rest."
                            )
                            .accessibilityLabel("Only the largest files are listed")
                    }
                }
                // Choosing ticks rows for the Trash; selecting (⌘A, ⇧-click) only highlights them.
                DSControlField("Choose for removal") {
                    HStack(spacing: DS.Space.sm) {
                        Button("Choose All") { model.mark(shown.map(\.marked)) }
                            .disabled(shown.allSatisfy { model.marked[$0.path] != nil })
                            .help("Tick every file listed for the Trash. Nothing moves until you review and confirm.")
                            .fixedSize()
                        Button(picked.isEmpty ? "Choose Selected" : "Choose \(picked.count) Selected") {
                            // ⌘⌫ in the filter field deletes the text, as everywhere else.
                            if MyMoleApp.sendToTextField(#selector(NSResponder.deleteToBeginningOfLine(_:))) { return }
                            model.mark(picked.map(\.marked))
                        }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .help("Tick the highlighted rows for the Trash (⌘⌫). Select rows with a click, ⇧ or ⌘, or ⌘A for all.")
                        .disabled(picked.isEmpty)
                        .fixedSize()
                    }
                }
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.vertical, DS.Space.md)

            FileTable(
                rows: shown.map(fileRow),
                columns: [.name, .size, .modified, .kind, .location],
                hiddenByDefault: [.kind],
                autosave: "diskMap.largeFiles",
                selection: $selection,
                marks: Set(model.marked.keys),
                onToggleMark: { id in byID[id].map { model.toggle($0.marked) } },
                onOpen: { ids in FileActions.reveal(ids) },
                onMark: { ids in model.mark(ids.compactMap { byID[$0] }.map(\.marked)) },
                menu: { ids in menu(ids.compactMap { byID[$0] }, rows: shown) })
        }
        .task(id: FilterKey(files: model.largeFiles, kind: kind, place: place, date: date, query: query)) { await refilter() }
        .sheet(isPresented: $reviewingDownloads) { DownloadsReviewSheet(model: model) }
        .overlay {
            if !model.largeFiles.isEmpty, shown.isEmpty, !filtered.working {
                ContentUnavailableView.search(text: query)
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
            ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
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
                    menu: { ids in
                        var out: [TableMenuEntry] = [.quickLook, .action(String(localized: "Show in Finder")) { FileActions.reveal(ids) }]
                        if canChoose {
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
        .task {
            let folder = folder
            let read = await Task.detached(priority: .userInitiated) { DownloadsReview.list(folder) }.value
            items = read.items
            truncated = read.truncated
        }
    }
}
