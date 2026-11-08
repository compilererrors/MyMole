import StorageKit
import SwiftUI

/// The Duplicates pane: files with the same content in the user's own
/// folders. The groups are on the left, the copies of the selected groups
/// on the right; what's ticked goes to the Trash, with Undo, and one copy
/// of every group always stays.
struct DuplicatesView: View {
    @Bindable var model: DuplicatesModel
    @State private var confirming = false
    /// Kept while you go to other panes and back, as the window's own state.
    @SceneStorage("duplicates.filter") private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !model.groups.isEmpty {
                        DSListHeading("Duplicate groups", detail: "Select a group to compare its copies.")
                    }
                    groups
                }.frame(minWidth: 300, maxWidth: .infinity)
                if !model.groups.isEmpty {
                    Divider()
                    VStack(spacing: 0) {
                        DSListHeading("Copies in selected groups", detail: "Tick copies for removal. One copy always stays.")
                        copies
                    }.frame(minWidth: 320, maxWidth: .infinity)
                }
            }
        }
        .dsBottom(showing: !model.chosen.isEmpty) {
            DSActionBar {
                DSText("\(model.chosen.count.formatted()) chosen · \(fmt(model.chosenBytes))", .lead)
            } trailing: {
                Button("Unchoose All") { model.chosen = [] }
                Button("Move to Trash…") { confirming = true }
                    .primaryAction()
                    .disabled(model.trashBlocker != nil)
                    .help(model.trashBlocker ?? String(localized: "Move the chosen copies to the Trash"))
            }
        } toast: {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
            }
        }
        .paneToolbar("Duplicates", subtitle: "Files with the same content in your own folders") { tools }
        .actionConfirmation(
            String(localized: "Move \(model.chosen.count.formatted()) cop\(model.chosen.count == 1 ? "y" : "ies") to the Trash?"),
            isPresented: $confirming, action: .duplicates,
            message: String(
                localized:
                    "\(fmt(model.chosenBytes)). One copy of each file stays where it is. You can undo right after, or put them back from the Trash later."
            )
        ) { model.trashChosen() }
    }

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        DuplicatesShowPicker()
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Looking in") {
                    ForEach(model.roots, id: \.self) { root in
                        Button(Breakable.path(root).replacingOccurrences(of: "\u{200B}", with: "")) { FileActions.reveal([root]) }
                    }
                }
            } label: {
                Label("Searched Folders", systemImage: "folder")
            }
            .help("The folders searched for duplicates")
            if model.scanning {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop searching; the last complete result stays")
            } else {
                Button {
                    model.scan()
                } label: {
                    Label("Search Again", systemImage: "arrow.clockwise")
                }
                .help("Search for duplicates again")
            }
        }
    }

    private var header: some View {
        DSPaneHeader {
            DSMetric(
                fmt(model.spareBytes), "in spare copies of \(model.groups.count.formatted()) file\(model.groups.count == 1 ? "" : "s")")
        } actions: {
            DSControlField("Filter duplicate groups") {
                DSFilterField(String(localized: "Filter by name or folder"), text: $query)
                    .frame(width: 280)
                    .disabled(model.groups.isEmpty)
            }
            DSControlField("Choose copies for removal") {
                Menu("Choose Copies") {
                    Button("All but the Newest") { model.chooseAll(keeping: .newest) }
                    Button("All but the Oldest") { model.chooseAll(keeping: .oldest) }
                    Button("All but the Copy in a Folder…") { model.chooseKeepingCopiesIn() }
                }
                .disabled(model.groups.isEmpty)
                .help("In the selected files, or in all when none is selected")
                .fixedSize()
            }
        } strip: {
            if model.scanning {
                DSRunningCapsule(text: stepText, since: model.startedAt)
                if let s = model.step, s.phase == .comparing, s.total > 0 { DSScanProgress(fraction: Double(s.done) / Double(s.total)) }
                DSStripButton("Stop", symbol: "stop.fill") { model.stop() }
            } else if let at = model.scannedAt {
                DSCapsule("Searched \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark", tint: .green)
            }
            Menu {
                Section("Searched folders") {
                    ForEach(model.roots, id: \.self) { r in
                        if model.addedRoots.contains(r) {
                            Button(String(localized: "Stop Searching \((r as NSString).abbreviatingWithTildeInPath)")) {
                                model.removeRoot(r)
                            }
                        } else {
                            Text((r as NSString).abbreviatingWithTildeInPath)
                        }
                    }
                }
                Button("Add Folder…") { model.addRoot() }
                Section("Smallest file") {
                    ForEach(DuplicatesModel.minimums, id: \.self) { m in
                        Toggle(fmt(m), isOn: Binding(get: { model.minimum == m }, set: { if $0 { model.setMinimum(m) } }))
                    }
                }
            } label: {
                Label("\(model.roots.count) folders · files of \(fmt(model.minimum)) and more", systemImage: "ruler")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.scanning || model.trashing)
            .help(
                "Smaller files, hidden files, apps and libraries (Photos, Music), Git repositories and dependency folders are left out, and so are cloud files that aren't downloaded. A folder inside another is searched once."
            )
            if model.uncompared > 0 {
                DSCapsule(
                    "\(model.uncompared) file\(model.uncompared == 1 ? "" : "s") couldn't be compared",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(
                    "They couldn't be read through, or changed while they were read, so whether they have copies isn't known. Search again to try them."
                )
            }
            if !model.unreadable.isEmpty {
                DSCapsule(
                    "\(model.unreadable.count) folder\(model.unreadable.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(model.unreadable.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
            }
        }
        .contextualControls(
            "Review duplicate copies",
            detail:
                "Filter by name or folder. Choose Copies applies to selected groups, or all groups when none is selected; one copy always stays."
        )
    }

    private var stepText: String {
        switch model.step?.phase {
        case .comparing: String(localized: "Comparing files")
        case .listing: String(localized: "Listing files: \((model.step?.done ?? 0).formatted())")
        case nil: String(localized: "Listing files")
        }
    }

    // MARK: Lists

    /// The groups matching the filter, worked out off the main thread.
    @State private var filtered = OffMain<[DuplicateGroup]>([])
    private var shown: [DuplicateGroup] { filtered.value }

    private struct FilterKey: Equatable {
        let groups: [DuplicateGroup]
        let query: String
    }

    private var groups: some View {
        FileTable(
            rows: shown.map { g in
                FileRow(
                    id: g.id, name: g.files[0].name, size: g.bytes, freeable: g.spare, items: g.files.count, symbol: "doc.on.doc",
                    subtitle: String(localized: "\(g.files.count) copies · \(folders(g))"))
            },
            columns: [.name, .freeable, .items, .size],
            hiddenByDefault: [.size],
            titles: [.items: String(localized: "Copies"), .size: String(localized: "Each")],
            autosave: "duplicates.groups",
            defaultSort: .freeable,
            selection: $model.selection,
            marks: nil,
            onOpen: { ids in FileActions.reveal(model.groups.filter { ids.contains($0.id) }.flatMap { $0.files.map(\.path) }) })
        .task(id: FilterKey(groups: model.groups, query: query)) {
            let (groups, query) = (model.groups, query)
            let search = TextQuery(query)
            await filtered.update(count: groups.count) {
                search.isEmpty ? groups : groups.filter { g in g.files.contains { search.matches($0.name, $0.path) } }
            }
        }
        .overlay {
            if !model.groups.isEmpty, shown.isEmpty, !filtered.working {
                ContentUnavailableView.search(text: query)
            } else if model.groups.isEmpty {
                if model.scanning {
                    DSLoading("Searching for duplicates…")
                } else if model.scannedAt != nil, !model.unreadable.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "Duplicates"), unreadable: model.unreadable) { model.scan() }
                } else if model.scannedAt != nil {
                    ContentUnavailableView(
                        String(localized: "No Duplicates"), systemImage: Pane.duplicates.symbol,
                        description: Text("No two files of 1 MB or more in the searched folders have the same content."))
                } else {
                    CenterCard(symbol: Pane.duplicates.symbol, title: "Duplicates", subtitle: "Finds files with the same content in Desktop, Documents, Downloads, Movies, Music and Pictures. Files are only read.") {
                        Button("Start Search") { model.scan() }.primaryAction()
                    }
                }
            }
        }
    }

    private var copies: some View {
        let byPath = Dictionary(model.shownGroups.flatMap { g in g.files.map { ($0.path, g) } }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: model.shownGroups.flatMap { g in
                g.files.map { f in
                    var r = FileRow(id: f.path, name: f.name, size: g.bytes, modified: f.modified, location: f.folder, symbol: "doc")
                    let clones = g.clones(of: f.path)
                    if clones > 0 {
                        r.badge = String(localized: "Clone")
                        r.badgeTint = .systemGray
                        r.badgeHelp = String(localized: "Shares its space with \(clones) other cop\(clones == 1 ? "y" : "ies") here: moving it frees space only when they all go.")
                    }
                    model.keep.mark(&r)
                    return r
                }
            },
            columns: [.name, .location, .modified, .size],
            hiddenByDefault: [.size],
            autosave: "duplicates.copies",
            defaultSort: .name,
            selection: $model.fileSelection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in
                let paths = ids.filter { byPath[$0] != nil }
                return [
                    .quickLook,
                    .action(String(localized: "Show in Finder")) { FileActions.reveal(paths) },
                    .divider,
                    paths.contains(where: { !model.chosen.contains($0) })
                        ? .action(String(localized: "Choose for Removal")) { model.choose(paths) }
                        : .action(String(localized: "Unchoose")) { model.chosen.subtract(paths) },
                    model.keep.menuEntry(paths, keep: model.keepAlways, stop: model.stopKeeping),
                ]
            })
        .overlay {
            if model.shownGroups.isEmpty, !model.groups.isEmpty {
                ContentUnavailableView(
                    String(localized: "No File Selected"), systemImage: "doc.on.doc",
                    description: Text("Select a file on the left to see its copies."))
            }
        }
    }

    /// "Documents, Downloads": the folders a group's copies are in, by name.
    private func folders(_ g: DuplicateGroup) -> String {
        var seen: [String] = []
        for f in g.files {
            let name = (f.folder as NSString).lastPathComponent
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.prefix(3).joined(separator: ", ") + (seen.count > 3 ? "…" : "")
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
