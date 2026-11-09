import ServiceManagement
import StorageKit
import SwiftUI

/// The Startup Items pane: what launchd starts by itself, at login, at boot
/// or on a schedule. The user's own agents can be chosen and moved to the
/// Trash, with Undo; the ones that need an administrator are shown and left.
struct StartupView: View {
    @Bindable var model: StartupModel
    @State private var confirming = false
    /// Kept while you go to other panes and back, as the window's own state.
    @SceneStorage("startup.filter") private var query = ""
    @AppStorage("startup.show") private var show: Show = .jobs

    enum Show: String, CaseIterable, Identifiable {
        case jobs, plugins
        var id: String { rawValue }
        var title: String { self == .jobs ? String(localized: "Startup Items") : String(localized: "Plug-ins") }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
        }
        .dsBottom(showing: !model.chosen.isEmpty) {
            DSActionBar {
                DSText("\(model.chosen.count.formatted()) chosen", .lead)
            } trailing: {
                Button("Unchoose All") { model.chosen = [] }
                Button("Move to Trash…") { confirming = true }
                    .primaryAction()
                    .disabled(model.trashBlocker != nil)
                    .help(model.trashBlocker ?? String(localized: "Move the chosen agents' files to the Trash"))
            }
        } toast: {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
            }
        }
        .paneToolbar("Startup Items", subtitle: "What starts by itself, and the plug-ins apps added") {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $show) {
                    ForEach(Show.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Read the launch folders again")
            }
        }
        .actionConfirmation(
            String(localized: "Move \(model.chosen.count.formatted()) startup item\(model.chosen.count == 1 ? "" : "s") to the Trash?"),
            isPresented: $confirming,
            message: String(localized: "\(model.chosenItems.map(\.label).sorted().joined(separator: ", ")). They stop starting from the next login; one that's running now keeps running until then, or until you quit its app. You can undo right after, or put them back from the Trash later.")
        ) { model.trashChosen() }
        .onAppear { model.load() }
        .liveRefresh(every: .seconds(3)) { await model.refreshLive() }
    }

    private var header: some View {
        DSPaneHeader {
            if show == .jobs {
                DSMetric(
                    jobs.count.formatted(),
                    "item\(jobs.count == 1 ? "" : "s") start\(jobs.count == 1 ? "s" : "") by \(jobs.count == 1 ? "itself" : "themselves")")
            } else {
                DSMetric(plugins.count.formatted(), "plug-in\(plugins.count == 1 ? "" : "s") in your Library and the one for every user")
            }
        } actions: {
            DSControlField("Filter startup items and plug-ins") {
                DSFilterField(String(localized: "Filter by name or program"), text: $query)
                    .frame(minWidth: 180, idealWidth: 280, maxWidth: .infinity)
                    .disabled(model.items.isEmpty)
            }
            DSControlField("Choose for removal") {
                Button("Choose Leftovers") { model.chooseLeftovers() }
                    .disabled(!model.items.contains { $0.programMissing && model.isRemovable($0) })
                    .help("Choose your own agents whose program is gone")
                    .fixedSize()
            }
        } strip: {
            if model.loading {
                DSCapsule("Reading", live: true)
                DSStripButton("Stop", symbol: "stop.fill") { model.stop() }
            } else if let at = model.loadedAt {
                DSCapsule("Read \(at.formatted(.relative(presentation: .named)))", symbol: "checkmark", tint: .green)
            }
            if model.leftovers > 0 {
                DSCountCapsule(model.leftovers, "leftover\(model.leftovers == 1 ? "" : "s"): the program is gone", tint: .orange)
            }
            if show == .jobs {
                DSCapsule("Apps' own login items are in System Settings", symbol: "gearshape")
                    .help(
                        "Jobs an app registers from inside itself aren't files, so they aren't listed here. Turn those off in System Settings → General → Login Items & Extensions."
                    )
                DSStripButton("Open Login Items", symbol: "arrow.up.forward.app") { SMAppService.openSystemSettingsLoginItems() }
                if model.live != nil {
                    DSCapsule("Running or not: as launchd says now", symbol: "bolt.horizontal")
                        .help(
                            "What each file says (starts at login, turned off) is what should happen; \"running now\" and \"not loaded now\" are what launchd has for your session. Jobs for every user and the system aren't seen from here."
                        )
                }
            }
            if !model.broken.isEmpty {
                DSCapsule(
                    "\(model.broken.count) job list\(model.broken.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(
                    "Not shown: \(model.broken.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")). They may be damaged; launchd ignores a list it can't read."
                )
            }
            if !model.unreadable.isEmpty {
                DSCapsule(
                    "\(model.unreadable.count) folder\(model.unreadable.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(model.unreadable.joined(separator: ", "))
            }
        }
        .contextualControls(
            "Review startup components",
            detail:
                "Filter by name or program. Choose Leftovers only ticks your startup items whose program is missing; nothing is removed yet."
        )
    }

    private var jobs: [StartupItem] { model.items.filter { $0.plugin == nil } }
    private var plugins: [StartupItem] { model.items.filter { $0.plugin != nil } }

    private var shown: [StartupItem] {
        let list = show == .jobs ? jobs : plugins
        return query.isEmpty ? list : list.filter { DSFilterField.matches(query, $0.label, $0.program ?? "") }
    }

    private var table: some View {
        let byID = Dictionary(model.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: shown.map(row),
            columns: [.name, .kind, .location, .modified],
            titles: [.location: show == .jobs ? String(localized: "Program") : String(localized: "Bundle ID")],
            autosave: "startup.list",
            defaultSort: .kind,
            selection: $model.selection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            menu: { ids in menu(ids.compactMap { byID[$0] }) })
        .overlay {
            if !model.items.isEmpty, shown.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if shown.isEmpty {
                if model.loading || model.loadedAt == nil {
                    DSLoading("Reading the launch folders…")
                } else if !model.unreadable.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "Startup items"), unreadable: model.unreadable) { model.load() }
                } else {
                    ContentUnavailableView(
                        show == .jobs ? String(localized: "No Startup Items") : String(localized: "No Plug-ins"), systemImage: Pane.startup.symbol,
                        description: Text(show == .jobs ? "Nothing in the launch folders starts by itself." : "No Quick Look, Spotlight, audio or other plug-ins are in your Library or the one for every user."))
                }
            }
        }
    }

    private func row(_ item: StartupItem) -> FileRow {
        var r = FileRow(
            id: item.path, name: item.label,
            // Without a size the row's tick box is off: it can't be moved from here.
            size: model.isRemovable(item) ? item.bytes : nil,
            modified: item.modified,
            kind: item.plugin.map { item.scope == .user ? $0.title : String(localized: "\($0.title) · all users") } ?? item.scope.title,
            location: item.program,
            symbol: item.plugin != nil ? "puzzlepiece.extension" : item.programMissing ? "questionmark.app.dashed" : item.app == nil ? "gearshape.2" : "app.badge",
            subtitle: ([item.app].compactMap { $0 } + [item.summary] + [liveText(item)].compactMap { $0 }).joined(separator: " · "))
        if item.programMissing {
            r.tint = .systemOrange
            r.badge = String(localized: "Leftover")
            r.badgeTint = .systemOrange
            r.badgeHelp = String(localized: "The program it starts isn't there any more.")
        } else if model.keep.protects(item.path) {
            model.keep.mark(&r)
        } else if !model.isRemovable(item) {
            r.badge = String(localized: "Needs admin")
            r.badgeTint = .systemGray
            r.badgeHelp = String(localized: "Installed for every user or the system. Remove it with its app's own uninstaller.")
        }
        return r
    }

    /// What launchd says now, apart from what the file says should happen.
    private func liveText(_ item: StartupItem) -> String? {
        guard item.plugin == nil, item.scope == .user, let live = model.live else { return nil }
        switch live[item.label] {
        case .running(let pid)?: return String(localized: "running now (pid \(pid))")
        case .loaded?: return String(localized: "loaded now, not running")
        case nil: return String(localized: "not loaded now")
        }
    }

    private func menu(_ picked: [StartupItem]) -> [TableMenuEntry] {
        let removable = picked.filter(model.isRemovable).map(\.path)
        var out = FileActions.menu(picked.map(\.path), canOpen: false)
        let programs = picked.compactMap(\.program).filter { $0.hasPrefix("/") }
        if !programs.isEmpty { out.append(.submenu(String(localized: "Program"), FileActions.menu(programs, canOpen: false))) }
        if !removable.isEmpty {
            out.append(.divider)
            if removable.contains(where: { !model.chosen.contains($0) }) {
                out.append(.action(String(localized: "Choose for Removal")) { model.choose(removable) })
            } else {
                out.append(.action(String(localized: "Unchoose")) { model.chosen.subtract(removable) })
            }
        }
        // Only the user's own agents can be kept; the others never move from here.
        let own = picked.filter { $0.scope == .user }.map(\.path)
        if !own.isEmpty { out.append(model.keep.menuEntry(own, keep: model.keepAlways, stop: model.stopKeeping)) }
        return out
    }
}
