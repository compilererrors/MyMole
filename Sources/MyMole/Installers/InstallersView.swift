import StorageKit
import SwiftUI

/// The Installers pane: disk images, packages, Xcode archives and device
/// software left in Downloads, Desktop, Documents, Homebrew's download cache
/// and Finder's device updates, and macOS installers in Applications. Nothing is
/// chosen for you; what you tick goes to the Trash, with Undo.
struct InstallersView: View {
    @Bindable var model: InstallersModel
    @State private var confirming = false
    /// Kept while you go to other panes and back, as the window's own state.
    @SceneStorage("installers.filter") private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .dsBottom(showing: !model.chosen.isEmpty) {
            actionBar
        } toast: {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
            }
        }
        .paneToolbar("Installers", subtitle: "Disk images and packages left after installing") { tools }
        .actionConfirmation(
            String(localized: "Move \(model.chosen.count.formatted()) installer\(model.chosen.count == 1 ? "" : "s") to the Trash?"),
            isPresented: $confirming, action: .installers,
            message: String(localized: "\(fmt(model.chosenBytes)). You can undo right after, or put them back from the Trash later.")
        ) { model.trashChosen() }
        .onAppear { model.scanIfNeeded() }
        .alert(model.problem ?? "", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") {}
        }
    }

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Looking in") {
                    ForEach(model.locations, id: \.path) { loc in
                        Button(String(localized: "\(Breakable.path(loc.path).replacingOccurrences(of: "\u{200B}", with: "")) · \(loc.depth) level\(loc.depth == 1 ? "" : "s") deep")) {
                            FileActions.reveal([loc.path])
                        }
                    }
                }
                if let at = model.scannedAt {
                    Text("Last read \(at.formatted(.relative(presentation: .named)))")
                }
                Divider()
                Button("Add Folder…") { model.addFolder() }
                if !model.addedFolders.isEmpty {
                    Menu("Stop Looking In") {
                        ForEach(model.addedFolders.sorted(), id: \.self) { p in
                            Button((p as NSString).abbreviatingWithTildeInPath) { model.removeFolder(p) }
                        }
                    }
                }
            } label: {
                Label("Searched Folders", systemImage: "folder")
            }
            .help("The folders searched for installers")
            if model.scanning {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop looking; the last complete result stays")
            } else {
                Button {
                    model.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Look for installers again")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        DSPaneHeader {
            DSMetric(fmt(model.totalBytes), "in \(model.files.count.formatted()) installer\(model.files.count == 1 ? "" : "s")")
        } actions: {
            DSControlField("Filter installers") {
                DSFilterField(String(localized: "Filter by name or folder"), text: $query)
                    .frame(width: 280)
                    .disabled(model.files.isEmpty)
            }
            DSControlField("Choose for removal") {
                Button("Choose All") { model.chooseAll() }
                    .disabled(model.files.isEmpty)
                    .fixedSize()
            }
        } strip: {
            if model.scanning {
                DSRunningCapsule(
                    text: model.files.isEmpty ? String(localized: "Looking") : String(localized: "Looking again"), since: model.startedAt)
                if model.isStale, let ago {
                    DSCapsule("Showing results from \(ago)", symbol: "clock")
                }
                DSStripButton("Stop", symbol: "stop.fill") { model.stop() }
            } else if model.isStale {
                DSCapsule("From an earlier scan\(ago.map { ", \($0)" } ?? "")", symbol: "clock", tint: .orange)
                DSStripButton("Scan Again", symbol: "arrow.clockwise") { model.scan() }
            } else if let ago {
                DSCapsule("Scanned \(ago)", symbol: "checkmark", tint: .green)
            }
            if model.files.contains(where: \.incomplete) {
                DSCapsule("Some folders couldn't be read; sizes are at least this", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help("Part of a package folder couldn't be read. The result isn't saved as complete.")
            }
            if !model.unreadableFolders.isEmpty {
                DSCapsule(
                    "\(model.unreadableFolders.count) folder\(model.unreadableFolders.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(
                    "Installers in \(model.unreadableFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) aren't shown. The result isn't saved as complete."
                )
            }
            Spacer(minLength: 0)
        }
        .contextualControls(
            "Review installers", detail: "Choose All ticks all installers from this scan, including those hidden by the filter. Review your choice before moving anything.")
    }

    private var ago: String? {
        model.scannedAt.map { $0.formatted(.relative(presentation: .named)) }
    }

    // MARK: Table

    /// What the filter lets through; choices it hides stay chosen.
    /// The files matching the filter, worked out off the main thread.
    @State private var filtered = OffMain<[InstallerFile]>([])
    private var shown: [InstallerFile] { filtered.value }

    private struct FilterKey: Equatable {
        let files: [InstallerFile]
        let query: String
    }

    private var table: some View {
        let byID = Dictionary(model.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: shown.map(row),
            columns: [.name, .size, .modified, .kind, .location],
            autosave: "installers.list",
            selection: $model.selection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .task(id: FilterKey(files: model.files, query: query)) {
            let (files, query) = (model.files, query)
            let search = TextQuery(query)
            await filtered.update(count: files.count) {
                search.isEmpty ? files : files.filter { search.matches($0.name, $0.path) }
            }
        }
        .overlay {
            if !model.files.isEmpty, shown.isEmpty, !filtered.working {
                ContentUnavailableView.search(text: query)
            } else if model.files.isEmpty {
                if model.scanning {
                    DSLoading("Looking for installers…")
                } else if model.scannedAt != nil, !model.unreadableFolders.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "Installers"), unreadable: model.unreadableFolders) { model.scan() }
                } else if model.scannedAt != nil {
                    ContentUnavailableView(
                        String(localized: "No Installers"), systemImage: "opticaldisc",
                        description: Text("No disk images or installer packages in the searched folders."))
                } else {
                    CenterCard(symbol: "opticaldisc", title: "Installers", subtitle: "Finds .dmg, .iso, .pkg, .xip and .ipsw files, and macOS installers, left after installing.") {
                        Button("Start Scan") { model.scan() }.primaryAction()
                    }
                }
            }
        }
    }

    private func row(_ f: InstallerFile) -> FileRow {
        var r = FileRow(
            id: f.path, name: f.name, size: f.bytes, modified: f.modified, kind: f.kind.title,
            location: f.folder, symbol: f.kind.symbol)
        model.keep.mark(&r)
        return r
    }

    private func menu(_ picked: [InstallerFile]) -> [TableMenuEntry] {
        guard !picked.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook, .divider]
        let unchosen = picked.filter { !model.chosen.contains($0.path) && !model.keep.protects($0.path) }
        if !unchosen.isEmpty {
            out.append(.action(unchosen.count == 1 ? String(localized: "Choose for Trash") : String(localized: "Choose \(unchosen.count) for Trash")) {
                model.choose(unchosen.map(\.path))
            })
        }
        if picked.contains(where: { model.chosen.contains($0.path) }) {
            out.append(.action(String(localized: "Unchoose")) { model.chosen.subtract(picked.map(\.path)) })
        }
        out.append(model.keep.menuEntry(picked.map(\.path), keep: model.keepAlways, stop: model.stopKeeping))
        if picked.count == 1 {
            let d = picked[0].modified
            out.append(.action(String(localized: "Choose All Changed On or Before \(d.listText)")) {
                model.choose(model.files.filter { $0.modified <= d }.map(\.path))
            })
        }
        out.append(.divider)
        out += FileActions.menu(picked.map(\.path))
        return out
    }

    // MARK: Action bar

    private var actionBar: some View {
        DSActionBar {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.sm) {
                    DSText("\(model.chosen.count.formatted()) chosen · \(fmt(model.chosenBytes))"
                        + DSFilterField.hiddenNote(chosen: model.chosen, shown: Set(shown.map(\.path))), .lead)
                        .keepWhole()
                    Button("Clear") { model.chosen = [] }
                .accessibilityLabel("Clear the choice")
                        .controlSize(.small)
                }
                Label("Moved to the Trash — you can undo.", systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        } trailing: {
            Button("Move to Trash…") { confirming = true }
                .primaryAction()
                .disabled(model.trashBlocker != nil)
                .help(model.trashBlocker ?? "")
        }
    }
}

extension InstallerFile.Kind {
    var symbol: String {
        switch self {
        case .diskImage: "opticaldisc"
        case .package: "shippingbox"
        case .archive: "doc.zipper"
        case .firmware: "iphone"
        case .macOSInstaller: "macwindow"
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
