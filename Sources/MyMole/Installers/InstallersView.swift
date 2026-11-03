import StorageKit
import SwiftUI

/// The Installers pane: disk images, packages and Xcode archives left in
/// Downloads, Desktop, Documents and Homebrew's download cache. Nothing is
/// chosen for you; what you tick goes to the Trash, with Undo.
struct InstallersView: View {
    @Bindable var model: InstallersModel
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            if !model.chosen.isEmpty { actionBar }
        }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
                    .padding(.bottom, model.chosen.isEmpty ? 16 : 70)
            }
        }
        .paneToolbar("Installers", subtitle: "Disk images and packages left after installing") { tools }
        .confirmationDialog(
            "Move \(model.chosen.count.formatted()) installer\(model.chosen.count == 1 ? "" : "s") to the Trash?",
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) { model.trashChosen() }
        } message: {
            Text("\(fmt(model.chosenBytes)). You can undo right after, or put them back from the Trash later.")
        }
        .onAppear { model.scanIfNeeded() }
    }

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Looking in") {
                    ForEach(model.locations, id: \.path) { loc in
                        Button(Breakable.path(loc.path).replacingOccurrences(of: "\u{200B}", with: "")) {
                            FileActions.reveal([loc.path])
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
            Button("Choose All") { model.chooseAll() }
                .disabled(model.files.isEmpty)
                .fixedSize()
        } strip: {
            if model.scanning {
                DSRunningCapsule(text: model.files.isEmpty ? "Looking" : "Looking again", since: model.startedAt)
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
                DSCapsule("\(model.unreadableFolders.count) folder\(model.unreadableFolders.count == 1 ? "" : "s") couldn't be read", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help("Installers in \(model.unreadableFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) aren't shown. The result isn't saved as complete.")
            }
            Spacer(minLength: 0)
        }
    }

    private var ago: String? {
        model.scannedAt.map { $0.formatted(.relative(presentation: .named)) }
    }

    // MARK: Table

    private var table: some View {
        let byID = Dictionary(model.files.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: model.files.map(row),
            columns: [.name, .size, .modified, .kind, .location],
            autosave: "installers.list",
            selection: $model.selection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .overlay {
            if model.files.isEmpty {
                if model.scanning {
                    DSLoading("Looking for installers…")
                } else if model.scannedAt != nil {
                    ContentUnavailableView(
                        "No Installers", systemImage: "opticaldisc",
                        description: Text("No disk images or installer packages in the searched folders."))
                } else {
                    CenterCard(symbol: "opticaldisc", title: "Installers", subtitle: "Finds .dmg, .pkg and .xip files left after installing.") {
                        Button("Start Scan") { model.scan() }.primaryAction()
                    }
                }
            }
        }
    }

    private func row(_ f: InstallerFile) -> FileRow {
        FileRow(
            id: f.path, name: f.name, size: f.bytes, modified: f.modified, kind: f.kind.title,
            location: f.folder, symbol: f.kind.symbol)
    }

    private func menu(_ picked: [InstallerFile]) -> [TableMenuEntry] {
        guard !picked.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook, .divider]
        let unchosen = picked.filter { !model.chosen.contains($0.path) }
        if !unchosen.isEmpty {
            out.append(.action(unchosen.count == 1 ? "Choose for Trash" : "Choose \(unchosen.count) for Trash") {
                model.choose(unchosen.map(\.path))
            })
        }
        if unchosen.count < picked.count {
            out.append(.action("Unchoose") { model.chosen.subtract(picked.map(\.path)) })
        }
        if picked.count == 1 {
            let d = picked[0].modified
            out.append(.action("Choose All Changed On or Before \(d.listText)") {
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
                    DSText("\(model.chosen.count.formatted()) chosen · \(fmt(model.chosenBytes))", .lead)
                        .keepWhole()
                    Button("Clear") { model.chosen = [] }
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
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
