import AppKit
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// What removed apps left in the Library, opened from Uninstall. Searched
/// against a fresh metadata inventory; caches and window states start
/// chosen, settings and data stay unless the user picks them.
struct OrphansSheet: View {
    @Bindable var model: OrphansModel
    let apps: AppsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var query = ""
    @State private var kind = -1
    @State private var filtered = OffMain<[Orphan]>([])
    @State private var removed: RemovedApp?
    @State private var access: RemovedAppAccess?
    @State private var choosing = false
    @State private var chooseProblem: String?

    private struct Search: Hashable {
        let items: [Orphan]
        let query: String
        let kind: Int

        func matches() -> [Orphan] {
            let prepared = TextQuery(query)
            return items.filter {
                (kind == -1 || $0.kind.rawValue == kind)
                    && prepared.matches($0.bundleID, $0.leftover.name, $0.path, $0.leftover.place)
            }
        }
    }

    private var search: Search { Search(items: model.items, query: query, kind: kind) }
    private var visible: [Orphan] { model.items.count <= OffMain<[Orphan]>.inline ? search.matches() : filtered.value }

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
                    DSControlBar("Find old app files", detail: "Search the results by app ID, file name or folder. Settings and data are never chosen automatically.") {
                        DSControlField("Search leftovers") {
                            DSFilterField(String(localized: "App ID, name or folder"), text: $query).frame(width: 260)
                        }
                        DSControlField("File type") {
                            Picker("File type", selection: $kind) {
                                Text("All types").tag(-1)
                                Text("Caches and logs").tag(Leftover.Kind.rebuildable.rawValue)
                                Text("App components").tag(Leftover.Kind.appPart.rawValue)
                                Text("Settings").tag(Leftover.Kind.settings.rawValue)
                                Text("App data").tag(Leftover.Kind.data.rawValue)
                            }.labelsHidden().fixedSize()
                        }
                        DSControlField("Refresh results") {
                            if model.loading { Button("Stop") { model.stop() } }
                            else { Button("Scan Again") { model.load() }.disabled(model.trashing) }
                        }
                    }
                    HStack {
                        DSText("\(visible.count) of \(model.items.count) found · choices include hidden results", .metadata)
                        Spacer()
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
                Button(model.trashing ? String(localized: "Moving…") : String(localized: "Move to Trash…")) { confirm = true }
                    .primaryAction()
                    .disabled(model.trashBlocker != nil)
                    .help(model.trashBlocker ?? String(localized: "Move the chosen leftovers to the Trash"))
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.xl)
        }
        .frame(width: DS.Size.reviewWidth)
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
        .task { model.load() }
        .task(id: search) {
            let request = search
            await filtered.update(count: request.items.count) { request.matches() }
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

    @ViewBuilder private var content: some View {
        if model.loading && model.items.isEmpty {
            DSLoading("Looking through your Library…").frame(height: 300)
        } else if (model.loadedAt != nil || model.stopped) && model.items.isEmpty {
            ContentUnavailableView(
                model.stopped ? String(localized: "Search Stopped") : String(localized: "No Unclaimed Leftovers Found"), systemImage: "folder.badge.questionmark",
                description: Text("Only the searched Library folders are covered. Shared developer files stay protected. Choose an app in the Trash below for a more specific search."))
                .frame(height: 300)
        } else if visible.isEmpty && !model.items.isEmpty && !filtered.working {
            ContentUnavailableView.search(text: query).frame(height: 300)
        } else {
            FileTable(
                rows: visible.map(row),
                columns: [.name, .size, .kind, .location],
                titles: [.kind: String(localized: "What")],
                autosave: "uninstall.orphans",
                selection: $model.selection,
                marks: model.chosen,
                onToggleMark: { model.toggle($0) },
                onOpen: { FileActions.reveal($0) },
                onMark: { model.choose($0) },
                menu: { ids in menu(ids) })
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

    private func row(_ o: Orphan) -> FileRow {
        var r = FileRow(
            id: o.path, name: o.leftover.name, size: o.bytes, kind: "\(o.kind.title) · \(o.leftover.place)",
            location: (o.path as NSString).deletingLastPathComponent, symbol: "folder.badge.questionmark",
            subtitle: o.bundleID)
        model.keep.mark(&r)
        return r
    }

    private func menu(_ ids: [String]) -> [TableMenuEntry] {
        guard !ids.isEmpty else { return [] }
        var out: [TableMenuEntry] = [.quickLook, .action(String(localized: "Show in Finder")) { FileActions.reveal(ids) }, .divider]
        if ids.contains(where: { !model.chosen.contains($0) }) {
            out.append(.action(String(localized: "Choose for Trash")) { model.choose(ids) })
        } else {
            out.append(.action(String(localized: "Unchoose")) { model.chosen.subtract(ids) })
        }
        out.append(model.keep.menuEntry(ids, keep: model.keepAlways, stop: model.stopKeeping))
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
