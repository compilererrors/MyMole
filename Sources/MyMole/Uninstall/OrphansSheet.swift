import AppKit
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// What removed apps left in the Library, opened from Uninstall. Searched
/// against a fresh metadata inventory; only caches and logs start
/// chosen. Settings, saved state and data need an explicit choice.
struct OrphansSheet: View {
    @Bindable var model: OrphansModel
    let apps: AppsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var query = ""
    @State private var kind = -1
    @State private var filtered = OffMain<[FileRow]>([])
    @State private var removed: RemovedApp?
    @State private var access: RemovedAppAccess?
    @State private var choosing = false
    @State private var chooseProblem: String?

    private struct Search: Hashable {
        let revision: UInt64
        let query: String
        let kind: Int
    }
    @State private var presentedSearch: Search?
    private var search: Search { Search(revision: model.presentationRevision, query: query, kind: kind) }
    private var visible: [FileRow] { filtered.value }

    nonisolated static func project(_ items: [Orphan], keep: SharedKeep, query: String, kind: Int) -> [FileRow] {
        let prepared = TextQuery(query)
        return items.compactMap { orphan in
            guard (kind == -1 || orphan.kind.rawValue == kind),
                  prepared.matches(orphan.bundleID, orphan.leftover.name, orphan.path, orphan.leftover.place) else { return nil }
            var row = FileRow(id: orphan.path, name: orphan.leftover.name, size: orphan.bytes,
                              kind: "\(orphan.kind.title) · \(orphan.leftover.place)",
                              location: (orphan.path as NSString).deletingLastPathComponent,
                              symbol: "folder.badge.questionmark", subtitle: orphan.bundleID)
            keep.mark(&row)
            return row
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Left by Removed Apps").font(.title2.bold())
                        DSText(
                            "Caches, settings and data in your Library named after apps that aren't on this Mac any more. Anything an installed app, a running one or another app of the same developer could still use stays.",
                            .metadata)
                    }
                    if let why = model.keep.blocker { DSNotice(.critical, why) }
                    if let why = model.searchProblem { DSNotice(.warning, why) }
                    if let why = chooseProblem { DSNotice(.warning, why) }
                    if model.stopped && model.loadedAt != nil {
                        DSNotice(.info, "Search stopped. Results from the last completed search are still shown.")
                    }
                    if !model.unreadable.isEmpty {
                        DSNotice(
                            .warning,
                            "\(model.unreadable.count) folder\(model.unreadable.count == 1 ? "" : "s") in your Library couldn't be read, so what's in \(model.unreadable.count == 1 ? "it" : "them") isn't listed: \(model.unreadable.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))."
                        )
                    }
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        HStack(spacing: DS.Space.sm) {
                            DSFilterField(String(localized: "App ID, name or folder"), text: $query).frame(minWidth: 160, maxWidth: .infinity)
                            DSFilterButton("Filter leftover files", detail: "Narrow the leftovers listed below by category. This does not run another search or change your removal choices.",
                                           count: (query.isEmpty ? 0 : 1) + (kind == -1 ? 0 : 1), clear: { query = ""; kind = -1 }) {
                                DSControlField("Leftover category") {
                                    Picker("Leftover category", selection: $kind) {
                                        Text("All Categories").tag(-1)
                                        Text("Caches and logs").tag(Leftover.Kind.rebuildable.rawValue)
                                        Text("App components").tag(Leftover.Kind.appPart.rawValue)
                                        Text("Settings").tag(Leftover.Kind.settings.rawValue)
                                        Text("App data").tag(Leftover.Kind.data.rawValue)
                                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            TableColumnsButton(scope: "uninstall.orphans").fixedSize()
                            if model.loading { Button("Stop") { model.stop() } }
                            else { Button("Scan Again") { model.load() }.disabled(model.trashing) }
                        }
                        if kind != -1 {
                            DSFilterChip(title: String(localized: "Category: \(Leftover.Kind(rawValue: kind)?.title ?? String(localized: "All types"))")) { kind = -1 }
                        }
                    }
                    HStack {
                        DSText("\(visible.count) of \(model.items.count) found · choices include hidden results", .metadata)
                        Spacer()
                        if let at = model.loadedAt {
                            DSCapsule("Scanned \(at.formatted(.relative(presentation: .named)))", symbol: "clock")
                        }
                        if model.loading || choosing || filtered.working { ProgressView().controlSize(.small) }
                    }
                    content
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text("Deleted an app in Finder?").font(.subheadline.bold())
                            DSText("Choose its copy in your Trash to verify its own files, helpers and app groups. This can find more when you still use other apps from the same developer. If the Trash was emptied, only the conservative search above is available.", .metadata)
                        }
                        Button("Choose App in Trash…") { chooseRemovedApp() }
                            .disabled(choosing || model.trashing || apps.uninstalling)
                    }
                }
                .padding(DS.Space.xl)
            }
            .frame(maxHeight: DS.Size.reviewBodyMaxHeight)
            DSActionGroup {
                DSText(
                    String(localized: "\(model.chosen.count.formatted()) chosen · \(ByteSize.format(model.chosenBytes)) to the Trash"),
                    .lead)
            } trailing: {
                Button("Close") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.trashing || apps.uninstalling)
                Button(model.trashing ? String(localized: "Moving…") : String(localized: "Move to Trash…")) { confirm = true }
                    .primaryAction()
                    .disabled(model.trashBlocker != nil)
                    .help(model.trashBlocker ?? String(localized: "Move the chosen leftovers to the Trash"))
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.xl)
        }
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard(canClose: !model.trashing && !apps.uninstalling)
        .overlay(alignment: .bottom) {
            VStack(spacing: DS.Space.sm) {
                if let n = model.notice {
                    DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
                }
                if let n = apps.notice, n.canUndo {
                    DSUndoToast(text: n.text, canUndo: apps.canUndo, undo: { apps.undoUninstall() }, dismiss: { apps.dismissNotice() })
                }
            }
            .padding(.bottom, DS.Space.lg)
        }
        .liveRefresh(every: .seconds(60), events: [.applications, .volumes]) {
            model.loadIfNeeded()
            if model.loading { await model.job?.value }
        }
        .onChange(of: apps.appListRevision) { _, _ in
            if !model.stopped, !model.loading, !model.trashing { model.load() }
        }
        .task(id: search) {
            let request = search
            let items = model.items
            let keep = model.keep
            await filtered.update(count: items.count, inlineLimit: 128) {
                Self.project(items, keep: keep, query: request.query, kind: request.kind)
            }
            if !Task.isCancelled { presentedSearch = request }
        }
        .sheet(item: $removed, onDismiss: {
            releaseAccess()
            model.load()
        }) { removed in
            UninstallSheet(model: apps, app: removed.app, removed: removed)
        }
        .onDisappear {
            model.stop()
            if removed == nil { releaseAccess(); choosing = false }
        }
        .actionConfirmation(
            String(localized: "Move \(model.chosen.count) leftover\(model.chosen.count == 1 ? "" : "s") to the Trash?"),
            isPresented: $confirm, action: .orphans,
            message: String(
                localized:
                    "\(ByteSize.format(model.chosenBytes)). Each is checked again right before it goes. You can undo right after, or put them back from the Trash later."
            )
        ) { model.trashChosen() }
    }

    private var content: some View {
        FileTable(
            rows: visible,
            columns: [.name, .size, .kind, .location],
            titles: [.kind: String(localized: "What")],
            autosave: "uninstall.orphans",
            selection: $model.selection,
            marks: model.chosen,
            onToggleMark: { model.toggle($0) },
            onOpen: { FileActions.reveal($0) },
            onMark: { model.choose($0) },
            onSetMarks: { paths, checked in
                guard !model.trashing, !apps.uninstalling else { return }
                if checked { model.choose(paths) } else { model.chosen.subtract(paths) }
            },
            bulkChoicesEnabled: !model.trashing && !apps.uninstalling,
            menu: { ids in menu(ids) })
            .frame(height: 300)
            .overlay { emptyState.allowsHitTesting(false) }
    }

    @ViewBuilder private var emptyState: some View {
        if model.loading && model.items.isEmpty {
            DSLoading("Looking through your Library…").frame(height: 300)
        } else if (model.loadedAt != nil || model.stopped) && model.items.isEmpty {
            ContentUnavailableView(
                model.stopped ? String(localized: "Search Stopped") : String(localized: "No Unclaimed Leftovers Found"), systemImage: "folder.badge.questionmark",
                description: Text("Only the searched Library folders are covered. Shared developer files stay protected. Choose an app in the Trash below for a more specific search."))
                .frame(height: 300)
        } else if visible.isEmpty && !model.items.isEmpty && presentedSearch != search {
            DSLoading("Preparing the list…").frame(height: 300)
        } else if visible.isEmpty && !model.items.isEmpty && !filtered.working {
            ContentUnavailableView("No Matching Items", systemImage: "line.3.horizontal.decrease",
                description: Text("Adjust or clear the filters above to see more files and folders."))
                .frame(height: 300)
        }
    }

    private func chooseRemovedApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Removed App")
        panel.message = String(localized: "Choose an app directly in your Trash. MyMole reads its identities to find its leftovers; the app itself stays there.")
        panel.prompt = String(localized: "Find Leftovers")
        panel.directoryURL = URL(fileURLWithPath: apps.home + "/.Trash")
        panel.allowedContentTypes = [.applicationBundle]
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        releaseAccess()
        access = RemovedAppAccess(url)
        choosing = true
        chooseProblem = nil
        let home = apps.home
        Task {
            let proof = await Task.detached(priority: .userInitiated) { RemovedApp.read(path: url.path, home: home) }.value
            guard choosing else { releaseAccess(); return }
            choosing = false
            guard let proof else {
                releaseAccess()
                chooseProblem = String(localized: "Choose a readable app directly in your Trash. Linked bundles, macOS apps and apps with an unknown identity aren't accepted.")
                return
            }
            removed = proof
        }
    }

    private func releaseAccess() {
        access = nil
    }

    private func menu(_ ids: [String]) -> [TableMenuEntry] {
        guard !ids.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook, .divider]
        if ids.contains(where: { !model.chosen.contains($0) }) {
            out.append(.action(String(localized: "Choose for Trash")) { model.choose(ids) })
        } else {
            out.append(.action(String(localized: "Unchoose")) { model.chosen.subtract(ids) })
        }
        out.append(model.keep.menuEntry(ids, keep: model.keepAlways, stop: model.stopKeeping))
        out.append(.divider)
        out += FileActions.menu(ids, canOpen: false)
        return out
    }
}

/// A temporary grant ends even if the whole parent window closes while
/// its nested review is showing. No bookmark or parent-folder grant is saved.
final class RemovedAppAccess {
    private let held: URL?
    private let stop: (URL) -> Void

    init(_ url: URL, start: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        held = start(url) ? url : nil
        self.stop = stop
    }

    deinit { if let held { stop(held) } }
}
