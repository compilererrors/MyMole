import AppKit
import StorageKit
import SwiftUI

struct AppCopiesSheet: View {
    let apps: AppsModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: AppCopiesModel
    @State private var query = ""
    @State private var filter = Filter.copies
    @State private var selection = Set<String>()
    @State private var integrationSelection = Set<String>()
    @State private var recordedSelection = Set<String>()
    @State private var review: AppBundle?
    @State private var inspecting: AppCopy?
    @State private var reviewJob: Task<Void, Never>?
    @State private var projected = OffMain<[AppCopy]>([])
    @State private var folderProblem: String?

    init(apps: AppsModel) {
        self.apps = apps
        _model = State(initialValue: AppCopiesModel(folders: apps.folders))
    }

    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, copies, builds, integrations
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: String(localized: "All discovered apps")
            case .copies: String(localized: "Multiple copies")
            case .builds: String(localized: "Possible test builds")
            case .integrations: String(localized: "Declares integrations")
            }
        }
    }

    private struct Search: Equatable {
        let revision: Int
        let query: String
        let filter: Filter
    }

    nonisolated static func project(_ copies: [AppCopy], counts: [String: Int], query: String, filter: Filter) -> [AppCopy] {
        let search = TextQuery(query)
        return copies.filter { copy in
            let included = switch filter {
            case .all: true
            case .copies: (counts[copy.app.bundleID?.lowercased() ?? ""] ?? 0) > 1
            case .builds: copy.hint != nil
            case .integrations: !copy.integrations.items.isEmpty
            }
            return included && search.matches(copy.app.name, copy.app.bundleID ?? "", copy.app.path, copy.app.version ?? "", copy.build ?? "")
        }.sorted {
            let order = $0.app.name.localizedStandardCompare($1.app.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private var visible: [AppCopy] {
        model.report.copies.count > OffMain<[AppCopy]>.inline ? projected.value
            : Self.project(model.report.copies, counts: model.counts, query: query, filter: filter)
    }
    private var selected: AppCopy? { selection.count == 1 ? model.report.copies.first { selection.contains($0.id) } : nil }
    private var canReview: Bool {
        guard let selected else { return false }
        return !model.loading && !model.measuring && model.loadedAt != nil && !apps.uninstalling && !selected.app.isProtected
            && !apps.sharesOwnIdentity(selected.app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    Text("App Copies & Integrations").font(.title2.bold())
                    DSText("Compare versions, build numbers and locations. Copies share an app ID; their contents may differ. Possible test builds are hints to review, never automatic removal choices.", .metadata)
                    DSControlBar("Find copies and menu providers", detail: "Search by app name, ID, version or path. Choose a build folder to include apps missing from the system index.") {
                        DSControlField("Search apps") {
                            DSFilterField(String(localized: "Name, app ID or path"), text: $query).frame(width: 250)
                        }
                        DSControlField("Show") {
                            Picker("Show apps", selection: $filter) {
                                ForEach(Filter.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                        DSControlField("Scan") {
                            HStack {
                                if model.loading || model.measuring { Button("Stop") { model.stop(); reviewJob?.cancel() } }
                                else { Button("Scan Again") { model.load() }.disabled(apps.uninstalling) }
                                Button("Choose Folder…") { chooseFolder() }.disabled(model.measuring || apps.uninstalling)
                            }
                        }
                    }
                    if let why = model.problem ?? folderProblem { DSNotice(.warning, why) }
                    if model.report.indexedUnavailable || model.report.registrationUnavailable {
                        DSNotice(.info, "Some macOS discovery sources were unavailable. Choose a folder to search build outputs directly; the results don't cover every app on the Mac.")
                    }
                    if model.report.limited { DSNotice(.warning, "The search reached its size or depth limit. Choose a smaller folder to inspect the remaining apps.") }
                    if !model.report.unreadable.isEmpty {
                        DSNotice(.warning, "\(model.report.unreadable.count) app or folder locations couldn't be read. Their contents aren't included.")
                    }
                    if model.stopped { DSNotice(.info, "Search stopped. Earlier complete results remain; a first search may show only the apps found before Stop.") }
                    ForEach(model.extraFolders, id: \.self) { path in
                        HStack {
                            DSPath(path, .metadata)
                            Spacer()
                            Button("Remove from Search") { model.removeFolder(path) }.disabled(model.loading || model.measuring)
                        }
                    }
                    HStack {
                        let groups = model.counts.values.filter { $0 > 1 }.count
                        DSText("\(visible.count) shown · \(groups) app ID\(groups == 1 ? "" : "s") with multiple copies", .metadata)
                        Spacer()
                        if model.loading || model.measuring || projected.working { ProgressView().controlSize(.small) }
                    }
                    if visible.isEmpty && model.loading {
                        DSLoading("Finding app copies…").frame(height: 240)
                    } else if visible.isEmpty {
                        ContentUnavailableView("No Matching Apps", systemImage: "square.on.square",
                                               description: Text("Try All discovered apps or choose a folder containing your test builds."))
                            .frame(height: 240)
                    } else {
                        FileTable(rows: visible.map(row), columns: [.name, .kind, .items, .modified, .location],
                                  titles: [.kind: String(localized: "Version / Build"), .items: String(localized: "Copies")],
                                  autosave: "uninstall.copies", defaultSort: .name, selection: $selection, marks: nil,
                                  onOpen: { paths in if let path = paths.first { selection = [path]; openReview() } },
                                  menu: { paths in FileActions.menu(paths, canOpen: false) })
                            .frame(height: 260)
                    }
                    if let selected {
                        DSPath(selected.app.path, .metadata)
                        DSText("Use Integrations to inspect this copy's menu providers, Services and file handlers.", .metadata)
                    }
                    if !model.report.missingRegistered.isEmpty {
                        DisclosureGroup("Recorded paths no longer found (\(model.report.missingRegistered.count))") {
                            DSText("macOS reported these paths, but no app was found there. These records aren't installed copies or removal targets, and don't identify individual Siri entries.", .metadata)
                            FileTable(rows: model.report.missingRegistered.map {
                                FileRow(id: $0, name: ($0 as NSString).lastPathComponent, kind: String(localized: "Missing recorded app"), location: $0, symbol: "questionmark.app.dashed")
                            }, columns: [.name, .kind, .location], autosave: "uninstall.missingCopies", defaultSort: .name, selection: $recordedSelection, marks: nil)
                                .frame(height: 150)
                        }
                    }
                    DSText("Repeated entries in Siri can have several causes. This view finds app bundles and their declared integrations; it doesn't edit Siri's app list. Manage extensions and Services in System Settings.", .metadata)
                    Button("Open System Settings") { StatusActions.openSystemSettings() }
                }
                .padding(DS.Space.xl)
            }
            .frame(maxHeight: DS.Size.reviewBodyMaxHeight)
            DSActionGroup {
                DSText(model.measuring ? String(localized: "Measuring the selected app…")
                       : selected.map { String(localized: "\($0.app.name) selected") } ?? String(localized: "Select one copy to review its removal."), .metadata)
            } trailing: {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(apps.uninstalling)
                Button("Show in Finder") { FileActions.reveal(Array(selection)) }.disabled(selection.isEmpty)
                Button("Integrations…") { inspecting = selected }.disabled(selected == nil)
                Button("Review Uninstall…") { openReview() }.primaryAction().disabled(!canReview)
            }
            .padding([.horizontal, .bottom], DS.Space.xl)
        }
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard(canClose: !apps.uninstalling)
        .task { model.load() }
        .onChange(of: apps.appListRevision) { _, _ in
            if !model.stopped, !model.loading, !model.measuring, review == nil, !apps.uninstalling { model.load() }
        }
        .task(id: Search(revision: model.revision, query: query, filter: filter)) {
            let (copies, counts, query, filter) = (model.report.copies, model.counts, query, filter)
            await projected.update(count: copies.count) { Self.project(copies, counts: counts, query: query, filter: filter) }
        }
        .onChange(of: model.loadedAt) { _, date in
            if date != nil { apps.rememberOtherCopies(model.report.copies.map(\.app), unreadable: model.report.unreadable) }
            selection.formIntersection(Set(model.report.copies.map(\.id)))
        }
        .onChange(of: selection) { _, _ in integrationSelection = [] }
        .sheet(item: $review, onDismiss: { model.load() }) { app in UninstallSheet(model: apps, app: app) }
        .sheet(item: $inspecting) { copy in
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(copy.app.name).font(.title2.bold())
                details(copy)
                DSText("Manage Finder extensions and Services in System Settings. Change Open With defaults in Finder → Get Info. This view doesn't change registrations.", .metadata)
                DSActionGroup {
                    DSText(version(copy), .metadata)
                } trailing: {
                    Button("Close") { inspecting = nil }.keyboardShortcut(.cancelAction)
                    Button("Open System Settings") { StatusActions.openSystemSettings() }
                }
            }
            .padding(DS.Space.xl)
            .frame(width: DS.Size.reviewWidth)
            .dialogKeyboard()
        }
        .onDisappear { model.stop(); reviewJob?.cancel() }
        .overlay(alignment: .bottom) {
            if let notice = apps.notice {
                DSUndoToast(text: notice.text, canUndo: apps.canUndo, undo: { apps.undoLatest() }, dismiss: { apps.dismissNotice() })
                    .padding(.bottom, DS.Space.lg)
            }
        }
    }

    private func row(_ copy: AppCopy) -> FileRow {
        let count = model.counts[copy.app.bundleID?.lowercased() ?? ""] ?? 1
        var row = FileRow(id: copy.id, name: copy.app.name, modified: copy.modified,
                          kind: version(copy), items: count, location: copy.app.path, symbol: "macwindow", subtitle: copy.app.bundleID)
        if copy.hint != nil {
            row.badge = String(localized: "Review build")
            row.badgeTint = .systemOrange
            row.badgeHelp = hint(copy)
        }
        return row
    }

    private func version(_ copy: AppCopy) -> String {
        [copy.app.version, copy.build.map { String(localized: "build \($0)") }].compactMap { $0 }.joined(separator: " · ")
    }

    private func hint(_ copy: AppCopy) -> String {
        copy.hint == .buildFolder
            ? String(localized: "Located in a build-output folder. It may still be a copy you need.")
            : String(localized: "Its name or app ID has a development, preview or test label. This isn't proof it's disposable.")
    }

    @ViewBuilder private func details(_ copy: AppCopy) -> some View {
        DSListHeading("Selected copy", detail: "Declarations identify providers. They don't prove a menu item is currently enabled.")
        DSPath(copy.app.path, .mono)
        DSText(copy.sources.sorted { $0.rawValue < $1.rawValue }.map(sourceTitle).joined(separator: " · "), .metadata)
        if copy.hint != nil { DSText(hint(copy), .metadata) }
        if apps.sharesOwnIdentity(copy.app) { DSText("Use MyMole's main Uninstall pane to remove a copy of MyMole.", .metadata) }
        if copy.integrations.items.isEmpty { DSText("No integrations declared in the inspected bundle locations.", .metadata) }
        else {
            FileTable(rows: copy.integrations.items.map {
                FileRow(id: $0.id, name: $0.name, kind: integrationTitle($0.kind), location: $0.path, symbol: "puzzlepiece.extension", subtitle: $0.detail)
            }, columns: [.name, .kind, .location], titles: [.kind: String(localized: "Integration")],
                      autosave: "uninstall.copyIntegrations", defaultSort: .name, selection: $integrationSelection, marks: nil,
                      onOpen: { paths in FileActions.reveal(copy.integrations.items.filter { paths.contains($0.id) }.map(\.path)) },
                      menu: { ids in FileActions.menu(copy.integrations.items.filter { ids.contains($0.id) }.map(\.path), canOpen: false) },
                      filePaths: { ids in let wanted = Set(ids); return copy.integrations.items.filter { wanted.contains($0.id) }.map(\.path) })
                .frame(height: 170)
        }
        if copy.integrations.items.contains(where: { $0.kind == .finder }) {
            DSText("Finder extensions generate their menu commands while running. Their providers are shown here; the current command labels aren't enumerated.", .metadata)
        }
        if !copy.integrations.unreadable.isEmpty || copy.integrations.limited {
            DSNotice(.warning, "Some integration metadata couldn't be read or exceeded the inspection limit. This isn't a complete list.")
        }
    }

    private func openReview() {
        guard canReview, let selected else { return }
        reviewJob?.cancel()
        reviewJob = Task { review = await model.prepareReview(selected, apps: apps) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Folder with App Builds")
        panel.message = String(localized: "App metadata is read inside this folder, including build outputs. App bundles aren't searched for nested copies; dependency and version-control folders are skipped.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ChosenFolders.shared.keep(url) else {
            folderProblem = String(localized: "Access to the chosen folder couldn't be kept. Choose it again.")
            return
        }
        folderProblem = nil
        model.addFolder(url.resolvingSymlinksInPath().path)
    }

    private func sourceTitle(_ source: AppCopy.Source) -> String {
        switch source {
        case .applications: String(localized: "Applications folders")
        case .registered: String(localized: "Known to macOS")
        case .indexed: String(localized: "System index")
        case .folder: String(localized: "Selected folder")
        }
    }

    private func integrationTitle(_ kind: AppIntegration.Kind) -> String {
        switch kind {
        case .finder: String(localized: "Finder menu provider")
        case .service: String(localized: "Services menu")
        case .documents: String(localized: "Open With declaration")
        case .urls: String(localized: "URL scheme")
        case .extensionProvider: String(localized: "App extension")
        }
    }
}
