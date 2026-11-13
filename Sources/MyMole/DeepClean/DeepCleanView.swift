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
    @State private var explaining: CleanCandidate?
    /// Kept while you go to other panes and back, as the window's own state.
    @SceneStorage("deepClean.filter") private var query = ""

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
        .paneToolbar("Deep Clean", subtitle: "Caches, logs and tool downloads that rebuild themselves") { tools }
        .alert(
            explaining?.name ?? "", isPresented: Binding(get: { explaining != nil }, set: { if !$0 { explaining = nil } }),
            presenting: explaining
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { c in
            Text([
                String(localized: "Found by: \(c.reason)"), model.choiceReason(c), String(localized: "If it goes: \(c.consequence)"),
            ].joined(separator: "\n\n"))
        }
        .confirmationKeyboard(isPresented: Binding(get: { explaining != nil }, set: { if !$0 { explaining = nil } }))
        .actionConfirmation(
            String(localized: "Move \(fmt(model.chosenBytes)) to the Trash?"),
            isPresented: $confirming, action: .deepClean, message: confirmationText
        ) { model.trashChosen() }
        .onAppear { model.scanIfNeeded() }
        .liveRefresh(every: .seconds(5)) { await model.refreshActivity() }
        .onChange(of: model.chosen) { _, _ in confirming = false }
    }

    private var confirmationText: String {
        let costs = Array(Set(model.chosenCandidates.map(\.consequence))).sorted()
        return String(localized: "\(model.chosen.count.formatted()) item\(model.chosen.count == 1 ? "" : "s"). You can undo right after, and the space is freed when you empty the Trash.")
            + "\n\n" + costs.joined(separator: "\n")
    }

    @PaneToolsBuilder private var tools: [PaneTool] {
        // System Clean exists only where MyMole may ask for root.
        if Edition.current.hasSystemTasks {
            PaneTool.button("deep-clean.system", "System Items", symbol: "lock.shield",
                            help: "System-wide caches need administrator rights; System Clean handles them") { openSystemClean() }
        }
        if model.scanning {
            PaneTool.button("deep-clean.scan", "Stop", symbol: "stop.fill", help: "Stop scanning; the last complete result stays") { model.stop() }
        } else {
            PaneTool.button("deep-clean.scan", "Rescan", symbol: "arrow.clockwise", help: "Scan again") { model.scan() }
        }
    }

    // MARK: Header

    private var header: some View {
        DSPaneHeader {
            if showsPreview {
                DSMetric(fmt(model.preview.reduce(0) { $0 + $1.bytes }), "found so far in \(model.preview.count.formatted()) items")
            } else {
                DSMetric(fmt(model.totalBytes), "found in \(model.candidates.count.formatted()) items")
            }
        } actions: {
            DSControlField("Filter results") {
                DSFilterField(String(localized: "Filter by name or folder"), text: $query)
                    .frame(minWidth: 180, idealWidth: 280, maxWidth: .infinity)
                    .disabled(listed.isEmpty)
            }
            DSControlField("Choose for removal") {
                Menu("Choose Items…") {
                    Button("Choose Safe Items") { model.chooseSafe() }
                    Button("Choose Everything") { model.choose(model.candidates.map(\.path)) }
                    Divider()
                    ForEach(CleanCategory.allCases.filter { model.bytes($0) > 0 }, id: \.self) { c in
                        Button("\(c.title) · \(fmt(model.bytes(c)))") { model.choose(category: c) }
                    }
                    Divider()
                    Button("Unchoose All") { model.chosen = [] }
                }
                .fixedSize()
                .disabled(model.candidates.isEmpty)
            }
        } strip: {
            if model.scanning {
                DSRunningCapsule(
                    text: model.candidates.isEmpty ? String(localized: "Scanning") : String(localized: "Scanning again"),
                    since: model.startedAt)
                DSScanProgress(fraction: model.scanFraction)
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
                DSStatusFact("\(runningCount) in use by running apps or tools", symbol: "app.badge")
                    .help("Not chosen automatically. Quit the app first for a clean result.")
            }
            let busy = model.candidates.filter { !model.isRunning($0) && model.isJustWritten($0) }.count
            if busy > 0 {
                DSStatusFact("\(busy) recently written", symbol: "clock")
                    .help("Not chosen automatically because something may still be using them.")
            }
            if !model.keep.paths.isEmpty {
                DSStatusFact("\(model.keep.paths.count) kept", symbol: "lock")
            }
            if model.candidates.contains(where: \.incomplete) {
                DSCapsule("Some folders couldn't be read; sizes are at least this", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    .help(
                        "Part of a cache couldn't be read. The result isn't saved as complete; give MyMole Full Disk Access or scan again.")
            }
            if !model.unreadablePlaces.isEmpty {
                DSCapsule(
                    "\(model.unreadablePlaces.count) place\(model.unreadablePlaces.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(
                    "What's in \(model.unreadablePlaces.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) isn't listed. The result isn't saved as complete; give MyMole Full Disk Access or scan again."
                )
            }
            Spacer(minLength: 0)
        } detail: {
            if let error = model.keepError {
                DSNotice(.critical, "Your keep list couldn't be read (\(error.description)). Nothing is moved until it can be.") {
                    Button("Try Again") { model.reloadKeepList() }
                    CopyErrorCodeButton(error.code)
                }
            }
            if let error = model.keepSaveError {
                DSNotice(
                    .critical,
                    "Your change to the keep list couldn't be saved (\(error.description)). Nothing is moved until it is saved or given up."
                ) {
                    Button("Try Again") { model.reloadKeepList() }
                    Button("Discard Change") { model.discardKeepChange() }
                    CopyErrorCodeButton(error.code)
                }
            }
        }
        .contextualControls(
            "Review cleanup results",
            detail: "Filtering only changes this list. Choose Items works across all scan results. Review ticked items before pressing Move to Trash.")
    }

    private var ago: String? {
        model.scannedAt.map { $0.formatted(.relative(presentation: .named)) }
    }

    // MARK: Table

    /// The first scan's finds while it runs, before anything else is listed.
    private var showsPreview: Bool { model.candidates.isEmpty && model.scanning && !model.preview.isEmpty }
    private var listed: [CleanCandidate] { showsPreview ? model.preview : model.candidates }

    /// What the filter lets through; choices it hides stay chosen.
    private var shown: [CleanCandidate] {
        let search = TextQuery(query)
        return search.isEmpty ? listed : listed.filter { search.matches($0.name, $0.path) }
    }

    private var table: some View {
        let byID = Dictionary(model.candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: shown.map(row),
            columns: [.name, .size, .modified, .kind, .location],
            titles: [.kind: String(localized: "Category")],
            autosave: "deepClean.list",
            selection: $model.selection,
            // Found so far isn't offered for choosing: the list is complete first.
            marks: showsPreview ? nil : model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            onSetMarks: { paths, checked in
                guard !model.trashing else { return }
                if checked { model.choose(paths) } else { model.chosen.subtract(paths) }
            },
            bulkChoicesEnabled: !model.trashing,
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .dsEmptyOverlay(showing: shown.isEmpty) {
            if !listed.isEmpty, shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if listed.isEmpty {
                if model.scanning {
                    DSLoading("Looking through caches and logs…")
                } else if model.scannedAt != nil, !model.unreadablePlaces.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "Caches or Logs"), unreadable: model.unreadablePlaces) { model.scan() }
                } else if model.scannedAt != nil {
                    ContentUnavailableView(
                        String(localized: "Nothing to Clean"), systemImage: "bubbles.and.sparkles",
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
            subtitle: c.consequence,
            tint: c.safety == .safe ? .systemGreen : .systemOrange)
        if model.keep.protects(c.path) {
            r.badge = String(localized: "Kept")
            r.badgeHelp = String(localized: "On your keep list; never cleaned")
            r.badgeTint = .secondaryLabelColor
            r.canChoose = false
            r.choiceHelp = r.badgeHelp
        } else if model.keptInProjects.protects(c.path) {
            r.badge = String(localized: "Kept")
            r.badgeHelp = String(localized: "Kept in Projects, or holds something that is; never cleaned from here")
            r.badgeTint = .secondaryLabelColor
            r.canChoose = false
            r.choiceHelp = r.badgeHelp
        } else if model.isRunning(c) {
            r.badge = String(localized: "Running")
            r.badgeHelp = String(localized: "The app is open. Quit it first for a clean result.")
            r.badgeTint = .systemOrange
        } else if model.isJustWritten(c) {
            r.badge = String(localized: "In use")
            r.badgeHelp = String(
                localized:
                    "Written in the last few minutes, probably by something running in the background. Left unticked; tick it yourself if it can go."
            )
            r.badgeTint = .systemOrange
        } else if c.safety == .review {
            r.badge = String(localized: "Review")
            r.badgeHelp = c.reason
            r.badgeTint = .systemOrange
        }
        return r
    }

    private func menu(_ picked: [CleanCandidate]) -> [TableMenuEntry] {
        guard !picked.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook]
        if picked.count == 1 { out.append(.action(String(localized: "Why This Was Found…")) { explaining = picked[0] }) }
        out.append(.divider)
        let unchosen = picked.filter { !model.chosen.contains($0.path) && !model.isKept($0.path) }
        if !unchosen.isEmpty {
            out.append(.action(unchosen.count == 1 ? String(localized: "Choose") : String(localized: "Choose \(unchosen.count)")) { model.choose(unchosen.map(\.path)) })
        }
        if picked.contains(where: { model.chosen.contains($0.path) }) {
            out.append(.action(String(localized: "Unchoose")) { model.chosen.subtract(picked.map(\.path)) })
        }
        let kept = picked.filter { model.keep.paths.contains($0.path) }
        if kept.isEmpty {
            out.append(.action(String(localized: "Always Keep")) { model.keepAlways(picked.map(\.path)) })
        } else {
            out.append(.action(String(localized: "Stop Keeping")) { model.stopKeeping(kept.map(\.path)) })
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
                .disabled(model.trashBlocker != nil || model.keepError != nil)
                .help(model.keepError != nil ? String(localized: "The keep list couldn't be read") : model.trashBlocker ?? "")
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
        case .devices: "iphone"
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
