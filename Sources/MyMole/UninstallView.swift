import AppKit
import PrivilegedKit
import StorageKit
import SwiftUI

/// `NSWorkspace.icon(forFile:)` hits Launch Services each call; grid cells
/// re-render on every search keystroke, so icons are fetched once per path.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

struct UninstallView: View {
    @Bindable var model: AppsModel
    @State private var query = ""
    @State private var selected: AppBundle?
    @AppStorage("uninstall.sort") private var sort: Sort = .size

    enum Sort: String, CaseIterable, Identifiable {
        case size, name
        var id: String { rawValue }
        var title: String { self == .size ? "Size" : "Name" }
    }

    private var filtered: [AppBundle] {
        let shown = query.isEmpty ? model.apps : model.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return switch sort {
        case .size: shown.sorted { $0.bytes > $1.bytes }
        case .name: shown.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        Group {
            if model.apps.isEmpty && model.loading {
                DSLoading("Finding your apps…")
            } else if filtered.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No Apps Found", systemImage: "app.dashed")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            } else {
                VStack(spacing: 0) {
                DSPaneHeader {
                    DSMetric(filtered.count.formatted(), "apps · \(ByteSize.format(filtered.reduce(0) { $0 + $1.bytes })) on disk")
                } actions: {
                    EmptyView()
                } strip: {
                    if model.loading {
                        DSRunningCapsule(text: "Updating the list", since: nil)
                    } else if model.isStale {
                        DSCapsule("From an earlier listing", symbol: "clock", tint: .orange)
                    }
                    DSCapsule("Sorted by \(sort.title.lowercased())", symbol: "arrow.up.arrow.down")
                    DSCapsule("Apps and their leftovers go to the Trash", symbol: "trash")
                    if !model.unreadableFolders.isEmpty {
                        DSCapsule("\(model.unreadableFolders.count) folder\(model.unreadableFolders.count == 1 ? "" : "s") couldn't be read", symbol: "exclamationmark.triangle.fill", tint: .orange)
                            .help("Apps in \(model.unreadableFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) aren't listed.")
                    }
                    if !query.isEmpty { DSCapsule("Matching “\(query)”", symbol: "magnifyingglass", tint: Theme.accent) }
                } detail: {
                    if !model.systemProblems.isEmpty {
                        let problems = model.systemProblems.map { (path: $0.path, reason: $0.reason) }
                        DSNotice(.warning, problemText(problems)) {
                            Button("Copy") { copyProblems(problems) }
                            Button("Dismiss") { model.dismissSystemProblems() }
                        }
                    }
                }
                Divider()
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: Theme.gap)], spacing: Theme.gap) {
                        ForEach(filtered) { item in
                            Button { selected = item } label: { card(item) }
                                .buttonStyle(.plain)
                                .disabled(item.isProtected)
                                .contextMenu {
                                    if !item.isProtected { Button("Uninstall…") { selected = item } }
                                    Divider()
                                    FileMenuItems(paths: [item.path])
                                }
                        }
                    }
                    .frame(maxWidth: DS.Size.pageMaxWidth)
                    .padding(.horizontal, DS.Space.page)
                    .padding(.vertical, DS.Space.lg)
                    .frame(maxWidth: .infinity)
                }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search apps")
        .paneToolbar("Uninstall", subtitle: "\(filtered.count) apps · leftovers go to the Trash too") {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Sort apps by size or name")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.load()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload the app list")
                .disabled(model.loading)
            }
        }
        .overlay(alignment: .bottom) {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoUninstall() }, dismiss: { model.dismissNotice() })
                    .padding(.bottom, 16)
            }
        }
        .onAppear { model.loadIfNeeded() }
        .sheet(item: $selected) { item in
            UninstallSheet(model: model, app: item)
        }
    }

    private func card(_ app: AppBundle) -> some View {
        VStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(app.path))
                .resizable()
                .frame(width: 56, height: 56)
            DSName(app.name, .lead, lines: 2, reservesSpace: true)
                .multilineTextAlignment(.center)
            if app.isProtected {
                DSValue("Part of macOS", .metadata)
            } else if app.bytes > 0 {
                DSValue(bytes: app.bytes, .metadata)
            } else {
                DSValue(" ", .metadata)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 12)
        .opacity(app.isProtected ? 0.5 : 1)
        .contentShape(.rect(cornerRadius: Theme.radius))
    }
}

/// Lists the app and everything it left in the Library and system-wide,
/// then moves what's chosen to the Trash on confirmation; the privileged
/// tool deletes the chosen system-wide items. Caches and parts of the app
/// start chosen; settings, data and shared data stay unless the user picks
/// them. A running app is refused until it's quit.
struct UninstallSheet: View {
    let model: AppsModel
    let app: AppBundle
    @Environment(\.dismiss) private var dismiss
    @State private var leftovers: [Leftover]?
    @State private var chosen = Set<String>()
    @State private var selection = Set<String>()
    @State private var confirm = false
    @State private var problem: String?
    @State private var running = false
    @State private var uninstaller: String?
    @State private var mentions: [AppMention] = []
    @State private var unchecked = false
    @State private var system: [SystemLeftover] = []
    @State private var systemChosen = Set<String>()
    @State private var systemSelection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcons.icon(app.path))
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.bold())
                    DSPath(app.path, .mono)
                    Text([app.bundleID, app.version.map { "version \($0)" }, app.fromAppStore ? "App Store" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if running {
                DSNotice(.warning, "\(app.name) is open. Quit it before uninstalling.") {
                    Button("Quit \(app.name)") {
                        model.quit(app)
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            running = model.running(app)
                        }
                    }
                }
            }
            if let uninstaller {
                DSNotice(.warning, "\(app.name) comes with its own uninstaller, which also removes parts MyMole can't see. Use it instead.") {
                    Button("Show Uninstaller") { FileActions.reveal([uninstaller]) }
                }
            }
            if !mentions.isEmpty {
                DSNotice(.info, mentionText) {
                    Button("Show") { FileActions.reveal(Array(Set(mentions.map(\.file))).sorted()) }
                }
            }
            if let problem {
                DSNotice(.critical, problem)
            }
            if unchecked {
                DSNotice(.warning, "MyMole couldn't look up other copies of \(app.name) on this Mac, so none of its leftovers are offered. The app itself can still go.")
            }
            if let leftovers {
                if !unchecked {
                    DSText(leftovers.isEmpty ? "No leftovers found in your Library." : "Leftovers in your Library. Caches and parts of the app are chosen; settings and data stay unless you choose them.", .metadata)
                }
                if let worry = worry(leftovers) {
                    DSNotice(.warning, worry)
                }
                FileTable(
                    rows: rows(leftovers),
                    columns: [.name, .size, .kind, .location],
                    titles: [.kind: "What"],
                    autosave: "uninstall.leftovers",
                    selection: $selection,
                    marks: chosen.union([app.path]),
                    onToggleMark: { id in
                        guard id != app.path else { return }
                        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                    },
                    onOpen: { FileActions.reveal($0) })
                .frame(height: system.isEmpty ? 240 : 170)
                if !system.isEmpty { systemSection }
            } else {
                DSLoading("Finding everything \(app.name) left behind…").frame(height: 240)
            }
            HStack {
                DSText("\(fmt(total)) to the Trash" + (systemBytes > 0 ? " · \(fmt(systemBytes)) deleted for good" : ""), .lead)
                Spacer()
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(model.uninstalling ? "Uninstalling…" : "Uninstall", role: .destructive) { confirm = true }
                    .primaryAction()
                    .tint(.red)
                    .disabled(leftovers == nil || running || uninstaller != nil || model.uninstalling)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 640)
        .task {
            running = model.running(app)
            uninstaller = model.ownUninstaller(of: app)
            mentions = await model.mentions(of: app)
            let found = await model.leftovers(for: app)
            unchecked = found == nil
            system = await model.systemLeftovers(for: app)
            systemChosen = model.canRemoveSystemLeftovers ? Set(system.filter(\.kind.chosenByDefault).map(\.path)) : []
            leftovers = found ?? []
            chosen = Set((found ?? []).filter(\.kind.chosenByDefault).map(\.path))
        }
        .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { uninstall() }
        } message: {
            Text("The app and \(chosen.count) leftover\(chosen.count == 1 ? "" : "s") are moved to the Trash. You can undo right after."
                + (systemChosen.isEmpty ? "" : " \(systemChosen.count) system-wide item\(systemChosen.count == 1 ? " is" : "s are") deleted for good and can't be undone."))
        }
    }

    /// What the app left outside your Library, for the privileged tool to delete.
    @ViewBuilder private var systemSection: some View {
        if model.canRemoveSystemLeftovers {
            DSText("Outside your Library, deleted for good after macOS asks for an administrator's password. Launch jobs, helpers, caches and installer records are chosen; settings and data stay unless you choose them.", .metadata)
            if system.contains(where: { systemChosen.contains($0.path) && !$0.kind.chosenByDefault }) {
                DSNotice(.warning, "System-wide settings or data are chosen. They're deleted for good, not moved to the Trash.")
            }
        } else {
            DSNotice(.info, "\(system.count) item\(system.count == 1 ? "" : "s") outside your Library, such as launch jobs or a privileged helper, need administrator rights to remove, which App Store apps may not ask for. The direct edition of MyMole removes them, or you can remove them yourself.")
        }
        FileTable(
            rows: system.map {
                FileRow(id: $0.path, name: $0.name, size: $0.bytes, kind: "\($0.kind.title) · \($0.place)",
                        location: ($0.path as NSString).deletingLastPathComponent, symbol: "lock.shield")
            },
            columns: [.name, .size, .kind, .location],
            titles: [.kind: "What"],
            autosave: "uninstall.system",
            selection: $systemSelection,
            marks: systemChosen,
            onToggleMark: { id in
                guard model.canRemoveSystemLeftovers else { return }
                if systemChosen.contains(id) { systemChosen.remove(id) } else { systemChosen.insert(id) }
            },
            onOpen: { FileActions.reveal($0) })
        .frame(height: 120)
    }

    private var systemBytes: Int64 { system.filter { systemChosen.contains($0.path) }.reduce(0) { $0 + $1.bytes } }

    private var total: Int64 {
        app.bytes + (leftovers ?? []).filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    private var mentionText: String {
        let home = model.home
        let places = mentions.prefix(4).map { m in
            (m.file.hasPrefix(home + "/") ? "~" + m.file.dropFirst(home.count) : m.file) + ":\(m.line)"
        }
        let more = mentions.count > 4 ? " and \(mentions.count - 4) more" : ""
        return "Named in your settings at \(places.joined(separator: ", "))\(more). MyMole doesn't change these files; edit them yourself if needed."
    }

    /// What a chosen leftover would cost, when it's more than a cache.
    private func worry(_ leftovers: [Leftover]) -> String? {
        let picked = leftovers.filter { chosen.contains($0.path) }
        if picked.contains(where: { $0.kind == .shared }) {
            return "Shared data is chosen. The developer's other apps may use it too."
        }
        if picked.contains(where: { $0.kind == .data }) {
            return "Your data is chosen: documents and databases the app made go with it."
        }
        if picked.contains(where: { $0.kind == .settings }) {
            return "Settings are chosen. A reinstall would start from defaults."
        }
        return nil
    }

    private func rows(_ leftovers: [Leftover]) -> [FileRow] {
        [FileRow(id: app.path, name: app.name, size: app.bytes, kind: "App", location: (app.path as NSString).deletingLastPathComponent, symbol: "app")]
            + leftovers.map {
                FileRow(id: $0.path, name: $0.name, size: $0.bytes, kind: "\($0.kind.title) · \($0.place)", location: ($0.path as NSString).deletingLastPathComponent, symbol: "folder")
            }
    }

    private func uninstall() {
        let picked = (leftovers ?? []).filter { chosen.contains($0.path) }
        let pickedSystem = system.filter { systemChosen.contains($0.path) }
        Task {
            switch await model.uninstall(app, leftovers: picked, system: pickedSystem) {
            case .done: dismiss()
            case .refused(let why), .failed(let why):
                problem = why
                running = model.running(app)
            }
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
