import AppKit
import PrivilegedKit
import StorageKit
import SwiftUI

/// `NSWorkspace.icon(forFile:)` hits Launch Services each call; grid cells
/// re-render on every search keystroke, so icons are fetched once per path.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    /// In the order they were fetched, so the oldest go first.
    private static var order: [String] = []
    /// More icons than any app list shows at once.
    static let limit = 300

    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        order.append(path)
        if order.count > limit {
            for old in order.prefix(order.count - limit) { cache[old] = nil }
            order.removeFirst(order.count - limit)
        }
        return i
    }

    static var count: Int { cache.count }
}

/// The apps on the Mac, as cards. Click one to uninstall it; ⌘-click,
/// or click once some are chosen, to choose several and uninstall them
/// together. Apps dropped on the pane or on MyMole's icon open the same
/// way, wherever they are; one on a mounted disk image offers its image.
/// macOS's own apps, shown when asked for, can only be reset.
struct UninstallView: View {
    @Environment(\.palette) private var palette
    @Bindable var model: AppsModel
    let orphans: OrphansModel
    var selfRemoval: SelfRemovalModel?
    /// Kept while you go to other panes and back, as the window's own state.
    @SceneStorage("uninstall.filter") private var query = ""
    @State private var selected: AppBundle?
    @State private var showOrphans = false
    @State private var showCopies = false
    @State private var showPackages = false
    /// Apps chosen to uninstall together.
    @State private var picked = Set<String>()
    @State private var batch: BatchRequest?
    @State private var dropTargeted = false
    /// Apps running now, by path, for the "Open" mark.
    @State private var runningPaths = Set<String>()
    @AppStorage("uninstall.sort") private var sort: Sort = .size
    @AppStorage(Self.showMacOSKey) private var showMacOS = false
    /// A table instead of icons, to compare many apps and choose them with the keyboard.
    @AppStorage("uninstall.asList") private var asList = false
    @State private var tableSelection = Set<String>()
    @State private var projected = OffMain<[AppBundle]>([])

    static let showMacOSKey = "uninstall.showMacOS"

    struct BatchRequest: Identifiable {
        let id = UUID()
        let apps: [AppBundle]
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case size, name
        var id: String { rawValue }
        var title: String { self == .size ? String(localized: "Size") : String(localized: "Name") }
    }

    private struct FilterKey: Equatable {
        let apps: [AppBundle]
        let query: String
        let sort: Sort
        let showMacOS: Bool
    }

    private var hiddenMacOS: Int { showMacOS ? 0 : model.apps.filter(\.isProtected).count }

    private var filtered: [AppBundle] {
        model.apps.count > OffMain<[AppBundle]>.inline
            ? projected.value : Self.project(model.apps, query: query, sort: sort, showMacOS: showMacOS)
    }

    nonisolated static func project(_ apps: [AppBundle], query: String, sort: Sort, showMacOS: Bool) -> [AppBundle] {
        let search = TextQuery(query)
        let matching = apps.filter { (showMacOS || !$0.isProtected) && search.matches($0.name) }
        return switch sort {
        case .size: matching.sorted {
            if $0.sizePending != $1.sizePending { return !$0.sizePending }
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        case .name: matching.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        }
    }

    private var pickedApps: [AppBundle] { model.apps.filter { picked.contains($0.path) } }

    /// The list is filtered and sorted once a drawing, and handed to every
    /// part that shows it.
    var body: some View { page(filtered) }

    private func header(_ filtered: [AppBundle]) -> some View {
        DSPaneHeader {
            if model.apps.isEmpty && model.loading {
                DSMetric("—", "apps · finding the first results…")
            } else if filtered.contains(where: \.sizePending) {
                DSMetric(filtered.count.formatted(), "apps · measuring sizes…")
            } else {
                DSMetric(filtered.count.formatted(), "apps · \(ByteSize.format(filtered.reduce(0) { $0 + $1.bytes })) on disk")
            }
        } actions: {
            DSControlField("Filter apps") {
                DSFilterField(String(localized: "Filter by app name"), text: $query).frame(width: 280)
            }
            DSControlField("Sort apps by") {
                Picker("Sort By", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            DSControlField("Show apps as") {
                Picker("Show As", selection: $asList) {
                    Text("Icons").tag(false)
                    Text("List").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            DSControlField("App scope") {
                Toggle("Include macOS apps", isOn: $showMacOS)
                    .toggleStyle(.checkbox)
                    .fixedSize()
                    .help("macOS apps stay installed; only resetting their caches and settings is offered.")
            }
            DSControlField("Removed apps") {
                Button("Left by Removed Apps…", systemImage: "folder.badge.questionmark") { showOrphans = true }
                    .help("Find caches, settings and data left after an app was deleted in Finder")
            }
            DSControlField("Copies and test builds") {
                Button("App Copies & Integrations…", systemImage: "square.on.square") { showCopies = true }
                    .help("Find other versions, test builds and apps that declare menu integrations")
            }
        } strip: {
            if model.loading {
                DSRunningCapsule(text: "Updating the list", since: nil)
                DSStripButton("Stop", symbol: "stop.fill") { model.stop() }
            } else if model.isStale {
                DSCapsule("From an earlier listing", symbol: "clock", tint: .orange)
            }
            DSStatusFact("Apps and their leftovers go to the Trash", symbol: "trash")
            if hiddenMacOS > 0 {
                DSStatusFact("\(hiddenMacOS) apps of macOS hidden", symbol: "eye.slash")
            }
            if !model.unreadableFolders.isEmpty {
                DSCapsule(
                    "\(model.unreadableFolders.count) folder\(model.unreadableFolders.count == 1 ? "" : "s") couldn't be read",
                    symbol: "exclamationmark.triangle.fill", tint: .orange
                )
                .help(
                    "Apps in \(model.unreadableFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) aren't listed."
                )
            }
        } detail: {
            if !model.systemProblems.isEmpty {
                let problems = model.systemProblems.map { (path: $0.path, reason: $0.reason) }
                DSNotice(.warning, problemText(problems)) {
                    Button("Copy") { copyProblems(problems) }
                    Button("Dismiss") { model.dismissSystemProblems() }
                        .accessibilityLabel("Dismiss these problems")
                }
            }
        }
        .contextualControls(
            "Find an app",
            detail:
                "Click an app to review it. ⌘-click starts a batch choice; further clicks add or remove apps. Review leftovers before uninstalling."
        )
    }

    private func page(_ filtered: [AppBundle]) -> some View {
        VStack(spacing: 0) {
            header(filtered)
            Divider()
            Group {
                if model.apps.isEmpty && model.loading {
                    DSLoading("Finding your apps…")
                } else if filtered.isEmpty {
                    if query.isEmpty, !model.unreadableFolders.isEmpty {
                        DSIncompleteEmpty(what: String(localized: "Apps"), unreadable: model.unreadableFolders) { model.load() }
                    } else if query.isEmpty {
                        ContentUnavailableView(
                            "No Apps Found", systemImage: "app.dashed", description: Text("Drop an app here to uninstall it."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else if asList {
                    appTable(filtered)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: Theme.gap)], spacing: Theme.gap) {
                            ForEach(filtered) { item in
                                Button {
                                    click(item)
                                } label: {
                                    card(item)
                                }
                                .buttonStyle(.plain)
                                .disabled(item.sizePending)
                                .help(cardHelp(item))
                                .contextMenu {
                                    Button(item.isProtected ? "Reset…" : "Uninstall…") { selected = item }
                                        .disabled(item.sizePending)
                                    if !item.isProtected {
                                        Button(picked.contains(item.path) ? "Unchoose" : "Choose to Uninstall Together") { toggle(item) }
                                            .disabled(item.sizePending)
                                    }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(palette.accent.color, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(DS.Space.sm)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: {
            dropTargeted = $0
        }
        .paneToolbar("Uninstall", subtitle: "\(filtered.count) apps · leftovers go to the Trash too") {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showOrphans = true
                } label: {
                    Label("Left by Removed Apps…", systemImage: "folder.badge.questionmark")
                }
                .help("Caches, settings and data of apps that aren't on this Mac any more")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPackages = true
                } label: {
                    Label("Installed Packages…", systemImage: "shippingbox")
                }
                .help("What Homebrew and installer packages put on the Mac, to look at")
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
        .dsBottom(showing: !picked.isEmpty) {
            DSActionBar {
                DSText(
                    "\(pickedApps.count.formatted()) app\(pickedApps.count == 1 ? "" : "s") chosen · \(ByteSize.format(pickedApps.reduce(0) { $0 + $1.bytes }))",
                    .lead)
            } trailing: {
                Button("Unchoose All") { picked = [] }
                Button("Uninstall \(pickedApps.count.formatted())…") { batch = BatchRequest(apps: pickedApps) }
                    .primaryAction()
                    .disabled(pickedApps.isEmpty || model.uninstalling)
            }
        } toast: {
            if let n = model.notice {
                DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoLatest() }, dismiss: { model.dismissNotice() })
            }
        }
        .onAppear { model.loadIfNeeded() }
        .task(id: FilterKey(apps: model.apps, query: query, sort: sort, showMacOS: showMacOS)) {
            let (apps, query, sort, showMacOS) = (model.apps, query, sort, showMacOS)
            await projected.update(count: apps.count) { Self.project(apps, query: query, sort: sort, showMacOS: showMacOS) }
        }
        .sheet(item: $selected) { item in
            if model.isSelf(item), let selfRemoval {
                SelfRemovalSheet(model: selfRemoval)
            } else {
                UninstallSheet(model: model, app: item)
            }
        }
        .sheet(item: $batch) { request in
            BatchUninstallSheet(model: model, apps: request.apps) { picked = [] }
        }
        .sheet(item: $model.droppedImage) { item in
            DiskImageSheet(model: model, item: item)
        }
        .sheet(isPresented: $showPackages) { PackagesSheet() }
        .sheet(isPresented: $showCopies) { AppCopiesSheet(apps: model) }
        .sheet(isPresented: $showOrphans) {
            OrphansSheet(model: orphans, apps: model)
        }
        .onChange(of: orphans.requested, initial: true) { _, asked in
            guard asked else { return }
            orphans.requested = false
            showOrphans = true
        }
        .onChange(of: model.dropped, initial: true) { _, apps in
            guard !apps.isEmpty else { return }
            model.dropped = []
            if apps.count == 1, let app = apps.first {
                selected = app
            } else {
                batch = BatchRequest(apps: apps.filter { !$0.isProtected })
            }
        }
        .onChange(of: model.apps) { picked.formIntersection(Set(model.apps.map(\.path))) }
        .task { readRunning() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in readRunning()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            readRunning()
        }
    }

    /// The apps as a table: name, size, version, where it is and whether
    /// it's open. Ticks choose apps to uninstall together; opening a row
    /// opens the same sheet a card does.
    private func appTable(_ apps: [AppBundle]) -> some View {
        let byPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return FileTable(
            rows: apps.map { a in
                var r = FileRow(
                    id: a.path, name: a.name, size: a.isProtected || a.sizePending ? nil : a.bytes, kind: a.version.map { String(localized: "version \($0)") },
                    location: (a.path as NSString).deletingLastPathComponent, symbol: "macwindow")
                if a.isProtected {
                    r.badge = String(localized: "Part of macOS")
                    r.badgeTint = .secondaryLabelColor
                } else if model.isSelf(a) {
                    r.badge = String(localized: "This app")
                    r.badgeHelp = String(localized: "Review this copy and its data before it goes to the Trash.")
                } else if runningPaths.contains(a.path) {
                    r.badge = String(localized: "Open")
                    r.badgeTint = .systemOrange
                    r.badgeHelp = String(localized: "Quit it before uninstalling")
                } else if a.fromAppStore {
                    r.badge = String(localized: "App Store")
                    r.badgeTint = .systemBlue
                }
                return r
            },
            columns: [.name, .size, .kind, .location],
            titles: [.kind: String(localized: "Version")],
            autosave: "uninstall.table",
            selection: $tableSelection,
            marks: picked,
            onToggleMark: { id in byPath[id].map(toggle) },
            onOpen: { ids in
                let chosen = ids.compactMap { byPath[$0] }.filter { !$0.sizePending }
                if chosen.count == 1 { selected = chosen[0] } else if !chosen.isEmpty { batch = BatchRequest(apps: chosen.filter { !$0.isProtected }) }
            },
            onMark: { ids in for a in ids.compactMap({ byPath[$0] }) where !picked.contains(a.path) { toggle(a) } },
            menu: { ids in
                let chosen = ids.compactMap { byPath[$0] }.filter { !$0.sizePending }
                guard let first = chosen.first else { return [] }
                return [
                    .action(chosen.count == 1 ? (first.isProtected ? String(localized: "Reset…") : String(localized: "Uninstall…")) : String(localized: "Uninstall \(chosen.count)…")) {
                        if chosen.count == 1 { selected = first } else { batch = BatchRequest(apps: chosen.filter { !$0.isProtected }) }
                    },
                    .action(String(localized: "Show in Finder")) { FileActions.reveal(chosen.map(\.path)) },
                ]
            })
    }

    /// A click opens the app, or chooses it once some are chosen or with ⌘ or ⇧ held.
    private func click(_ app: AppBundle) {
        guard !app.sizePending else { return }
        let choosing = !picked.isEmpty || !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
        if choosing, !app.isProtected { toggle(app) } else { selected = app }
    }

    private func toggle(_ app: AppBundle) {
        guard !app.isProtected, !app.sizePending else { return }
        if picked.contains(app.path) { picked.remove(app.path) } else { picked.insert(app.path) }
    }

    private func readRunning() {
        runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    private func cardHelp(_ app: AppBundle) -> String {
        let version = app.version.map { String(localized: "version \($0)") }
        return [app.name, version, (app.path as NSString).abbreviatingWithTildeInPath].compactMap { $0 }.joined(separator: " · ")
    }

    private func card(_ app: AppBundle) -> some View {
        let isPicked = picked.contains(app.path)
        return VStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(app.path))
                .resizable()
                .frame(width: 56, height: 56)
            DSName(app.name, .lead, lines: 2, reservesSpace: true)
                .multilineTextAlignment(.center)
            if app.isProtected {
                DSValue(String(localized: "Part of macOS"), .metadata)
            } else if app.sizePending {
                DSValue(String(localized: "Measuring…"), .metadata)
            } else if app.bytes > 0 {
                DSValue(bytes: app.bytes, .metadata)
            } else {
                DSValue(" ", .metadata)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 12)
        .overlay {
            if isPicked {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(palette.accent.color, lineWidth: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPicked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, palette.accent.color)
                    .padding(6)
                    .accessibilityLabel("Chosen")
            }
        }
        .overlay(alignment: .topLeading) {
            if runningPaths.contains(app.path), !model.isSelf(app) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .help("Open: quit it before uninstalling")
                    .accessibilityLabel("Open")
            }
        }
        .opacity(app.isProtected ? 0.6 : 1)
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
    var removed: RemovedApp? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var leftovers: [Leftover]?
    @State private var related = RelatedComponents.Report()
    @State private var relatedSelection = Set<String>()
    @State private var chosen = Set<String>()
    @State private var selection = Set<String>()
    @State private var confirm = false
    @State private var confirmReset = false
    @State private var problem: String?
    @State private var running = false
    @State private var uninstaller: String?
    @State private var mentions: [AppMention] = []
    @State private var unchecked = false
    @State private var checking: UUID?
    @State private var system: [SystemLeftover] = []
    @State private var systemChosen = Set<String>()
    @State private var systemSelection = Set<String>()
    /// What the user's keep lists protect among the app and its leftovers:
    /// shown, never chosen.
    @State private var kept = Set<String>()
    /// The keep lists couldn't be read: nothing is uninstalled until they can be.
    @State private var keepsUnreadable = false
    /// Locked in Finder among the app and its leftovers: unlocked to move.
    @State private var locked = Set<String>()
    /// Also what a looser match finds; never chosen. Kept between apps.
    @AppStorage(AppsModel.deepKey) private var deep = false

    /// Part of macOS: it stays, and only a reset of its caches and settings is offered.
    private var macOS: Bool { app.isProtected }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcons.icon(app.path))
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.title2.bold())
                    DSPath(app.path, .mono)
                    Text(
                        [
                            app.bundleID, app.version.map { String(localized: "version \($0)") },
                            app.fromAppStore ? String(localized: "App Store") : nil,
                        ]
                        .compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if macOS {
                DSNotice(
                    .info,
                    "\(app.name) is part of macOS, so it stays. Its caches, saved state and settings can be reset; its data is never offered."
                )
            }
            if removed != nil {
                DSNotice(.info, "This app is already in the Trash. Only the chosen leftovers move; shared identities still used by installed apps stay. Settings and personal data stay unless you choose them.")
            }
            if running {
                DSNotice(
                    .warning, macOS ? "\(app.name) is open. Quit it before resetting." : "\(app.name) is open. Quit it before uninstalling."
                ) {
                    Button("Quit App") {
                        model.quit(app)
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            running = model.running(app)
                        }
                    }
                    .help("Quit \(app.name) before continuing")
                }
            }
            if let uninstaller {
                DSNotice(.warning, "\(app.name) comes with its own uninstaller, which also removes parts MyMole can't see. Use it instead.")
                {
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
                DSNotice(
                    .warning,
                    removed == nil
                        ? "MyMole couldn't verify who owns \(app.name)'s leftovers, so none are offered. You can still uninstall the app itself."
                        : "The app in the Trash or the ownership of its leftovers couldn't be verified. Nothing is offered. Choose the app again and reload the app list."
                )
            }
            if keepsUnreadable {
                DSNotice(
                    .critical,
                    "Your keep lists couldn't be read, so nothing is uninstalled until they can be. Look at the lists in Settings and your rules in Projects."
                )
            } else if kept.contains(app.path) {
                DSNotice(.warning, "\(app.name) is on one of your keep lists, or holds something that is, so it stays.")
            }
            if let leftovers {
                DSText("Each folder row includes its contents. Your data stays unless you choose it.", .metadata)
                if RelatedComponents.isChrome(app) {
                    DSText("Chrome profile folders can contain bookmarks, history and extensions. Custom profile locations outside the searched folders aren't discovered automatically.", .metadata)
                }
                if !unchecked {
                    DSText(
                        leftovers.isEmpty
                            ? String(localized: "No leftovers found in your Library.")
                            : String(
                                localized:
                                    "Leftovers in your Library, each with how it's tied to the app. Caches and parts of the app are chosen; settings, data and what's found by the app's name only stay unless you choose them."
                            ), .metadata)
                }
                if let worry = worry(leftovers) {
                    DSNotice(.warning, worry)
                }
                FileTable(
                    rows: rows(leftovers),
                    columns: [.name, .size, .kind, .location],
                    titles: [.kind: String(localized: "What")],
                    autosave: "uninstall.leftovers",
                    selection: $selection,
                    marks: macOS || removed != nil ? chosen : chosen.union([app.path]),
                    onToggleMark: { id in
                        guard id != app.path, !kept.contains(id) else { return }
                        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                    },
                    onOpen: { FileActions.reveal($0) }
                )
                .frame(height: system.isEmpty ? 240 : 170)
                Toggle(isOn: $deep) {
                    Text("Search deeper")
                    Text(
                        "Also the app's name inside longer names, one folder further down, and hidden folders in your home folder such as ~/.config. What it finds is never chosen for you."
                    )
                }
                .controlSize(.small)
                if !system.isEmpty { systemSection }
                relatedSection
            } else {
                DSLoading("Finding everything \(app.name) left behind…").frame(height: 240)
            }
            DSActionGroup {
                DSText(
                    String(localized: "\(fmt(total)) to the Trash")
                        + (systemBytes > 0 ? String(localized: " · \(fmt(systemBytes)) deleted for good") : ""), .lead)
            } trailing: {
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                if removed != nil {
                    Button("Move to Trash…") { confirmReset = true }
                        .primaryAction()
                        .disabled(leftovers == nil || checking != nil || chosen.isEmpty || running || model.uninstalling || keepsUnreadable || unchecked)
                } else if macOS {
                    Button("Reset…") { confirmReset = true }
                        .primaryAction()
                        .help("Move the chosen caches and settings of \(app.name) to the Trash, so it starts over with them")
                        .disabled(leftovers == nil || checking != nil || chosen.isEmpty || running || model.uninstalling || keepsUnreadable)
                } else {
                    Button("Reset…") { confirmReset = true }
                        .controlSize(.large)
                        .help("Keep \(app.name) and move only the chosen leftovers to the Trash, so it starts over as on its first launch")
                        .disabled(leftovers == nil || checking != nil || chosen.isEmpty || running || model.uninstalling || keepsUnreadable)
                    Button(model.uninstalling ? String(localized: "Uninstalling…") : String(localized: "Uninstall"), role: .destructive) {
                        confirm = true
                    }
                    .primaryAction()
                    .tint(.red)
                    .disabled(
                        leftovers == nil || checking != nil || running || uninstaller != nil || model.uninstalling || keepsUnreadable
                            || kept.contains(app.path))
                }
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.reviewWidth)
        // Turning the deeper search on or off looks again; what was ticked stays ticked.
        .task(id: deep) {
            let run = UUID()
            checking = run
            defer { if checking == run { checking = nil } }
            let before = chosen
            let foundUninstaller = removed == nil ? await model.ownUninstaller(of: app) : nil
            let foundMentions = removed == nil ? await model.mentions(of: app) : []
            let found: [Leftover]?
            if let removed { found = await model.leftovers(for: removed, deep: deep) }
            else { found = await model.leftovers(for: app, deep: deep) }
            let foundSystem = removed == nil ? await model.systemLeftovers(for: app) : []
            let foundRelated = removed == nil ? await model.relatedComponents(for: app) : RelatedComponents.Report()
            // What a keep list protects is shown as kept and starts unchosen.
            let keptHere = await model.kept(among: [app.path] + (found ?? []).map(\.path))
            let keptSystem = await model.kept(among: foundSystem.map(\.path), system: true)
            let paths = [app.path] + (found ?? []).map(\.path)
            let foundLocked = await Task.detached(priority: .userInitiated) { Set(paths.filter(Locks.isLocked)) }.value
            guard !Task.isCancelled, checking == run else { return }
            running = model.running(app)
            uninstaller = foundUninstaller
            mentions = foundMentions
            unchecked = found == nil
            system = foundSystem
            related = foundRelated
            keepsUnreadable = keptHere == nil || keptSystem == nil
            kept = (keptHere ?? []).union(keptSystem ?? [])
            systemChosen = model.canRemoveSystemLeftovers ? Set(system.filter(\.kind.chosenByDefault).map(\.path)).subtracting(kept) : []
            locked = foundLocked
            leftovers = found ?? []
            let present = Set((found ?? []).map(\.path))
            chosen = Set((found ?? []).filter(\.chosenByDefault).map(\.path)).union(before.intersection(present)).subtracting(kept)
        }
        .actionConfirmation(
            String(localized: "Uninstall \(app.name)?"), isPresented: $confirm,
            action: .uninstall, always: !systemChosen.isEmpty, message: confirmText
        ) { uninstall() }
        .actionConfirmation(
            removed == nil ? String(localized: "Reset \(app.name)?") : String(localized: "Move leftovers of \(app.name) to the Trash?"), isPresented: $confirmReset,
            action: removed == nil ? .reset : .orphans, button: removed == nil ? String(localized: "Reset") : String(localized: "Move to Trash"),
            message: (removed == nil ? String(
                localized:
                    "\(app.name) stays. The \(chosen.count) chosen leftover\(chosen.count == 1 ? "" : "s") (\(fmt(chosenLeftoverBytes))) go to the Trash, so it starts over as on its first launch. You can undo right after."
            ) : String(localized: "The \(chosen.count) chosen leftover\(chosen.count == 1 ? "" : "s") (\(fmt(chosenLeftoverBytes))) go to the Trash. The app already there stays untouched. Ownership and keep rules are checked again. You can undo right after.")) + lockedText(among: chosen)
        ) { reset() }
    }

    /// Related shared components are informational, outside the choice set.
    @ViewBuilder private var relatedSection: some View {
        let covered = (leftovers ?? []).map(\.path) + system.map(\.path)
        let components = related.components.filter { item in
            !covered.contains { item.path == $0 || item.path.hasPrefix($0 + "/") }
        }
        if !components.isEmpty {
            DisclosureGroup("Shared updater components (\(components.count))") {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    DSText("These components may serve other Google products or installations. They aren't attributed exclusively to this app and aren't separate removal choices here.", .metadata)
                    FileTable(
                        rows: components.map {
                            FileRow(id: $0.path, name: ($0.path as NSString).lastPathComponent,
                                    kind: $0.scope == .user ? String(localized: "Shared · your Library") : String(localized: "Shared · system Library"),
                                    location: ($0.path as NSString).deletingLastPathComponent,
                                    symbol: $0.kind == .updater ? "arrow.triangle.2.circlepath" : "gearshape")
                        }, columns: [.name, .kind, .location], autosave: "uninstall.related",
                        selection: $relatedSelection, marks: nil, onOpen: { FileActions.reveal($0) },
                        menu: { paths in [.action(String(localized: "Show in Finder")) { FileActions.reveal(paths) }] })
                        .frame(height: 150)
                }.padding(.top, DS.Space.sm)
            }
        }
        if !related.unreadable.isEmpty {
            DSText("Some known shared-component locations couldn't be inspected. This isn't a complete installation manifest.", .metadata)
        }
    }

    /// What the confirmation says goes where: to the Trash, and for good.
    private var confirmText: String {
        let trash = String(localized: "The app and \(chosen.count) leftover\(chosen.count == 1 ? "" : "s") are moved to the Trash. You can undo right after.")
            + lockedText(among: chosen.union([app.path]))
        guard !systemChosen.isEmpty else { return trash }
        let forGood = systemChosen.count == 1
            ? String(localized: "1 system-wide item is deleted for good and can't be undone.")
            : String(localized: "\(systemChosen.count) system-wide items are deleted for good and can't be undone.")
        return trash + " " + forGood
    }

    /// Said when items locked in Finder are among those going.
    private func lockedText(among paths: Set<String>) -> String {
        let n = locked.intersection(paths).count
        return n == 0 ? "" : " " + String(localized: "\(n) of them \(n == 1 ? "is" : "are") locked in Finder and unlocked to move.")
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
                keptBadge(FileRow(id: $0.path, name: $0.name, size: $0.bytes, kind: "\($0.kind.title) · \($0.place)",
                                  location: ($0.path as NSString).deletingLastPathComponent, symbol: "lock.shield"))
            },
            columns: [.name, .size, .kind, .location],
            titles: [.kind: String(localized: "What")],
            autosave: "uninstall.system",
            selection: $systemSelection,
            marks: systemChosen,
            onToggleMark: { id in
                guard model.canRemoveSystemLeftovers, !kept.contains(id) else { return }
                if systemChosen.contains(id) { systemChosen.remove(id) } else { systemChosen.insert(id) }
            },
            onOpen: { FileActions.reveal($0) })
        .frame(height: 120)
    }

    private var systemBytes: Int64 { system.filter { systemChosen.contains($0.path) }.reduce(0) { $0 + $1.bytes } }

    private var total: Int64 {
        (macOS || removed != nil ? 0 : app.bytes) + (leftovers ?? []).filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    private var mentionText: String {
        let home = model.home
        let places = mentions.prefix(4).map { m in
            (m.file.hasPrefix(home + "/") ? "~" + m.file.dropFirst(home.count) : m.file) + ":\(m.line)"
        }
        let more = mentions.count > 4 ? String(localized: " and \(mentions.count - 4) more") : ""
        return String(localized: "Named in your settings at \(places.joined(separator: ", "))\(more). MyMole doesn't change these files; edit them yourself if needed.")
    }

    /// What a chosen leftover would cost, when it's more than a cache.
    private func worry(_ leftovers: [Leftover]) -> String? {
        let picked = leftovers.filter { chosen.contains($0.path) }
        if picked.contains(where: { $0.kind == .shared }) {
            return String(localized: "Shared data is chosen. The developer's other apps may use it too.")
        }
        if picked.contains(where: { $0.kind == .data }) {
            return String(localized: "Your data is chosen: documents and databases the app made go with it.")
        }
        if picked.contains(where: { $0.kind == .settings }) {
            return String(localized: "Settings are chosen. A reinstall would start from defaults.")
        }
        return nil
    }

    private func rows(_ leftovers: [Leftover]) -> [FileRow] {
        (macOS || removed != nil ? [] : [keptBadge(FileRow(
            id: app.path, name: app.name, size: app.bytes, kind: String(localized: "App"),
            location: (app.path as NSString).deletingLastPathComponent, symbol: "macwindow", canChoose: false,
            choiceHelp: String(localized: "Uninstall includes the app. Reset keeps the app and only moves the chosen data.")))])
            + leftovers.map {
                keptBadge(
                    FileRow(
                        id: $0.path, name: $0.name, size: $0.bytes, kind: "\($0.kind.title) · \($0.place)",
                        location: ($0.path as NSString).deletingLastPathComponent,
                        symbol: "folder", subtitle: String(localized: "Found \($0.evidence.title)")))
            }
    }

    /// The row marked as kept when a keep list protects it, or as locked in Finder.
    private func keptBadge(_ row: FileRow) -> FileRow {
        var r = row
        if kept.contains(row.id) {
            r.badge = String(localized: "Kept")
            r.badgeTint = .secondaryLabelColor
            r.canChoose = false
            r.badgeHelp = String(localized: "On one of your keep lists, or holds something that is; it stays")
            r.choiceHelp = r.badgeHelp
        } else if locked.contains(row.id) {
            r.badge = String(localized: "Locked")
            r.badgeTint = .systemOrange
            r.badgeHelp = String(localized: "Locked in Finder: unlocked right before it moves, and locked again if it stays")
        }
        return r
    }

    private var chosenLeftoverBytes: Int64 { (leftovers ?? []).filter { chosen.contains($0.path) }.reduce(0) { $0 + $1.bytes } }

    private func reset() {
        let picked = (leftovers ?? []).filter { chosen.contains($0.path) }
        Task {
            let result: AppsModel.Result
            if let removed { result = await model.cleanRemovedApp(removed, leftovers: picked) }
            else { result = await model.reset(app, leftovers: picked) }
            switch result {
            case .done: dismiss()
            case .refused(let why), .failed(let why):
                problem = why
                running = model.running(app)
            }
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
