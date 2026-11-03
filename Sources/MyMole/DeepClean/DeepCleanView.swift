import StorageKit
import SwiftUI

/// The Deep Clean pane: caches, logs and tool downloads found by MyMole's
/// own rules, in one table. Safe items of apps that aren't running start
/// chosen; Review items, running apps' caches and kept items don't.
/// Everything chosen goes to the Trash, with Undo.
struct DeepCleanView: View {
    @Bindable var model: DeepCleanModel
    var openSystemClean: () -> Void = {}
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
        .paneToolbar("Deep Clean", subtitle: "Caches, logs and tool downloads that rebuild themselves") { tools }
        .confirmationDialog(
            "Move \(fmt(model.chosenBytes)) to the Trash?",
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) { model.trashChosen() }
        } message: {
            Text("\(model.chosen.count.formatted()) item\(model.chosen.count == 1 ? "" : "s"). Apps rebuild what they need. You can undo right after, and the space is freed when you empty the Trash.")
        }
        .onAppear { model.scanIfNeeded() }
    }

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // System Clean exists only where MyMole may ask for root.
            if Edition.current.hasSystemTasks {
                Button {
                    openSystemClean()
                } label: {
                    Label("System Items", systemImage: "lock.shield")
                }
                .help("System-wide caches need administrator rights; System Clean handles them")
            }
            if model.scanning {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop scanning; the last complete result stays")
            } else {
                Button {
                    model.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Scan again")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        DSPaneHeader {
            DSMetric(fmt(model.totalBytes), "found in \(model.candidates.count.formatted()) items")
        } actions: {
            HStack(spacing: DS.Space.sm) {
                Menu("Choose") {
                    Button("Safe Items") { model.chooseSafe() }
                    Button("Everything") { model.choose(model.candidates.map(\.path)) }
                    Divider()
                    ForEach(CleanCategory.allCases.filter { model.bytes($0) > 0 }, id: \.self) { c in
                        Button("\(c.title) · \(fmt(model.bytes(c)))") { model.choose(category: c) }
                    }
                    Divider()
                    Button("Nothing") { model.chosen = [] }
                }
                .fixedSize()
                .disabled(model.candidates.isEmpty)
            }
        } strip: {
            if model.scanning {
                DSRunningCapsule(text: model.candidates.isEmpty ? "Scanning" : "Scanning again", since: model.startedAt)
                if model.isStale, let ago {
                    DSCapsule("Showing results from \(ago)", symbol: "clock")
                }
                DSStripButton("Stop", symbol: "stop.fill") { model.stop() }
            } else if model.trashing {
                DSRunningCapsule(text: "Moving to the Trash", since: nil)
            } else if model.isStale {
                DSCapsule("From an earlier scan\(ago.map { ", \($0)" } ?? "")", symbol: "clock", tint: .orange)
                DSStripButton("Scan Again", symbol: "arrow.clockwise") { model.scan() }
            } else if let ago {
                DSCapsule("Scanned \(ago)", symbol: "checkmark", tint: .green)
            }
            let runningCount = model.candidates.filter(model.isRunning).count
            if runningCount > 0 {
                DSCountCapsule(runningCount, "in use by running apps or tools, unticked")
            }
            if !model.keep.paths.isEmpty {
                DSCountCapsule(model.keep.paths.count, "kept")
            }
            if model.candidates.contains(where: \.incomplete) {
                DSCapsule("Some folders couldn't be read; sizes are at least this", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help("Part of a cache couldn't be read. The result isn't saved as complete; give MyMole Full Disk Access or scan again.")
            }
            if !model.unreadablePlaces.isEmpty {
                DSCapsule("\(model.unreadablePlaces.count) place\(model.unreadablePlaces.count == 1 ? "" : "s") couldn't be read", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help("What's in \(model.unreadablePlaces.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) isn't listed. The result isn't saved as complete; give MyMole Full Disk Access or scan again.")
            }
            Spacer(minLength: 0)
        } detail: {
            if let error = model.keepError {
                DSNotice(.critical, "Your keep list couldn't be read (\(error)). Nothing is moved until it can be.") {
                    Button("Try Again") { model.reloadKeepList() }
                }
            }
            if let error = model.keepSaveError {
                DSNotice(.critical, "Your change to the keep list couldn't be saved (\(error)). Nothing is moved until it is saved or given up.") {
                    Button("Try Again") { model.reloadKeepList() }
                    Button("Discard Change") { model.discardKeepChange() }
                }
            }
        }
    }

    private var ago: String? {
        model.scannedAt.map { $0.formatted(.relative(presentation: .named)) }
    }

    // MARK: Table

    private var table: some View {
        let byID = Dictionary(model.candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: model.candidates.map(row),
            columns: [.name, .size, .modified, .kind, .location],
            titles: [.kind: "Category"],
            autosave: "deepClean.list",
            selection: $model.selection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .overlay {
            if model.candidates.isEmpty {
                if model.scanning {
                    DSLoading("Looking through caches and logs…")
                } else if model.scannedAt != nil {
                    ContentUnavailableView(
                        "Nothing to Clean", systemImage: "bubbles.and.sparkles",
                        description: Text("Your caches and logs are already tidy."))
                } else {
                    CenterCard(symbol: "sparkles", title: "Deep Clean", subtitle: "Finds caches, logs and tool downloads that apps rebuild by themselves.") {
                        Button("Start Scan") { model.scan() }.primaryAction()
                    }
                }
            }
        }
    }

    private func row(_ c: CleanCandidate) -> FileRow {
        var r = FileRow(
            id: c.path, name: c.name, size: c.bytes, modified: c.modified > .distantPast ? c.modified : nil,
            kind: c.category.title, location: (c.path as NSString).deletingLastPathComponent, symbol: c.category.symbol,
            tint: c.safety == .safe ? .systemGreen : .systemOrange)
        if model.keep.protects(c.path) {
            r.badge = "Kept"
            r.badgeHelp = "On your keep list; never cleaned"
        } else if model.isRunning(c) {
            r.badge = "Running"
            r.badgeHelp = "The app is open. Quit it first for a clean result."
        } else if c.safety == .review {
            r.badge = "Review"
            r.badgeHelp = c.reason
        }
        return r
    }

    private func menu(_ picked: [CleanCandidate]) -> [TableMenuEntry] {
        guard !picked.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook, .divider]
        let unchosen = picked.filter { !model.chosen.contains($0.path) && !model.keep.protects($0.path) }
        if !unchosen.isEmpty {
            out.append(.action(unchosen.count == 1 ? "Choose" : "Choose \(unchosen.count)") { model.choose(unchosen.map(\.path)) })
        }
        if picked.contains(where: { model.chosen.contains($0.path) }) {
            out.append(.action("Unchoose") { model.chosen.subtract(picked.map(\.path)) })
        }
        let kept = picked.filter { model.keep.paths.contains($0.path) }
        if kept.isEmpty {
            out.append(.action("Always Keep") { model.keepAlways(picked.map(\.path)) })
        } else {
            out.append(.action("Stop Keeping") { model.stopKeeping(kept.map(\.path)) })
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
                .disabled(model.trashBlocker != nil || model.keepError != nil)
                .help(model.keepError != nil ? "The keep list couldn't be read" : model.trashBlocker ?? "")
        }
    }
}

extension CleanCategory {
    var symbol: String {
        switch self {
        case .appCaches: "archivebox"
        case .containerCaches: "shippingbox"
        case .logs: "doc.text"
        case .developerCaches: "hammer"
        case .downloads: "paperclip"
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
