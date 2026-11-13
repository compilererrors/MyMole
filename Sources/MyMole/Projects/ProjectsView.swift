import StorageKit
import SwiftUI

/// The Projects pane: every development project with everything it takes
/// on disk, inside its folder (build output, dependencies, local work
/// files) and elsewhere (agent sessions, DerivedData, app containers). The
/// list is marked by heat, so the projects being worked on and the ones
/// gone quiet both stand out; old data of either goes to the Trash.
struct ProjectsView: View {
    let app: AppModel
    @Bindable var model: ProjectsModel

    @State private var confirming = false
    /// Name, type or folder words, and last activity; kept between launches.
    @AppStorage("projects.filter.query") private var query = ""
    @AppStorage("projects.filter.active") private var active: ProjectActivity = .any

    var body: some View {
        VStack(spacing: 0) {
            summary
            if let error = model.rulesError {
                DSNotice(.critical, "Your project rules couldn't be read (\(error.description)). Nothing is moved until they can be.") {
                    Button("Try Again") { model.reloadRules() }
                    CopyErrorCodeButton(error.code)
                }
                .padding(.horizontal, DS.Space.page)
                .padding(.bottom, DS.Space.md)
            }
            InspectorSplit {
                list
            } inspector: {
                detail
            }
        }
        .dsBottom(showing: !model.chosen.isEmpty) {
            actionBar
        } toast: {
            ProjectsNotice(model: model)
        }
        .disabled(model.pendingRule != nil)
        .allowsHitTesting(model.pendingRule == nil)
        .overlay(alignment: .topTrailing) {
            if let change = model.pendingRule { ProjectRuleConfirmation(model: model, change: change) }
        }
        .paneToolbar("Projects", subtitle: "\(subtitle)") { tools }
        .actionConfirmation(
            String(localized: "Move \(model.chosenEntries.count.formatted()) item\(model.chosenEntries.count == 1 ? "" : "s") to the Trash?"),
            isPresented: $confirming, action: .projects,
            message: String(localized: "\(Freeing.phrase(model.chosenBytes, frees: model.chosenFrees)) from \(Set(model.chosenEntries.map(\.project)).count) project(s):\n\(reviewList)\n\nAnything holding a Git repository, key files, files Git tracks or uncommitted work stays. You can undo right after, or put things back from the Trash later.")
        ) { model.trashChosen() }
        .onAppear { model.pins.refresh(); model.scanIfNeeded() }
    }

    /// The paths that go, for a last look before confirming.
    private var reviewList: String {
        let home = Home.path
        let paths = model.chosenEntries.map(\.entry.path).map {
            $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0
        }
        let shown = paths.prefix(8).joined(separator: "\n")
        let list = paths.count > 8 ? shown + "\n" + String(localized: "… and \(paths.count - 8) more") : shown
        let left = model.excluded.count
        guard left > 0 else { return list }
        return list + "\n"
            + (left == 1
                ? String(localized: "1 thing you left out inside them stays.")
                : String(localized: "\(left) things you left out inside them stay."))
    }

    private var subtitle: String {
        if model.scanning {
            return model.footprints.isEmpty
                ? String(localized: "Looking for projects…")
                : String(localized: "Measuring \(model.measuredCount) of \(model.footprints.count) projects…")
        }
        guard !model.footprints.isEmpty else { return String(localized: "Every project and what it leaves on disk") }
        let line = String(localized: "\(model.footprints.count) projects · \(fmt(model.totalBytes)) · \(fmt(model.freeableBytes)) could go")
        return model.incomplete ? line + String(localized: " · some folders couldn't be read") : line
    }

    @PaneToolsBuilder private var tools: [PaneTool] {
            PaneTool.menu("projects.folders", "Project Folders", symbol: "folder.badge.plus", help: "Choose the folders searched for projects") {
                Section("Looking in") {
                    ForEach(model.roots, id: \.self) { root in
                        Menu(Breakable.path(root).replacingOccurrences(of: "\u{200B}", with: "")) {
                            FileMenuItems(paths: [root], canOpen: false)
                            Divider()
                            Button("Stop Looking Here") { model.removeRoot(root) }
                        }
                    }
                }
                Divider()
                Section("Pinned items") {
                    ForEach(model.pins.paths.sorted(), id: \.self) { path in
                        Menu(Breakable.path(path)) {
                            Button("Show in Finder") { FileActions.reveal([path]) }
                            Button("Unpin") { model.pins.set([path], pinned: false) }
                        }
                    }
                    Button("Pin Folder…") { model.pinFolder() }
                }
                Divider()
                Button("Add Folder…") { model.addRoot() }
                Button("Use the Usual Folders") { model.resetRoots() }
            }
            if model.refreshing {
                PaneTool.button("projects.stop", "Stop", symbol: "stop.fill", help: "Stop measuring; the last complete result stays") { model.stop() }
            } else {
                PaneTool.menu("projects.refresh", "\(model.refreshTitle)", symbol: "arrow.clockwise",
                              help: "Refresh the current folder or project (⌘R), or choose Scan All Projects",
                              enabled: !model.trashing, primary: { model.refreshCurrent() }) {
                    Button(model.refreshTitle, action: model.refreshCurrent)
                    Button("Scan All Projects") { model.scan() }
                }
            }
    }

    // MARK: Summary

    /// The heat chips and the total. Never wider than the pane: where the
    /// whole line doesn't fit, the total says less (it's in the title too).
    /// The chips are measured once per width; only the total's wording is
    /// chosen among its fits. A resize measures this on every frame.
    private var summary: some View {
        let counts = model.heatCounts()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.sm) {
                chips(counts)
                Spacer(minLength: DS.Space.sm)
                ViewThatFits(in: .horizontal) {
                    total(full: true)
                    total(full: false)
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            DSFlow(spacing: DS.Space.sm) { chips(counts) }
        }
        .withoutAlignmentGuides()
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.md)
    }

    @ViewBuilder private func chips(_ counts: [Heat: Int]) -> some View {
        ForEach(Heat.allCases, id: \.self) { h in
            let n = counts[h] ?? 0
            Button {
                model.selection = Set(model.footprints.filter { Heat($0.lastActivity) == h }.map(\.id))
            } label: {
                DSCountChip(n, h.title, h.color)
            }
            .buttonStyle(.plain)
            .help(h == .dormant
                ? String(localized: "Select the projects untouched for a month or more")
                : String(localized: "Select the projects \(h.title.lowercased())"))
        }
    }

    private func total(full: Bool) -> some View {
        HStack(spacing: DS.Space.sm) {
            if model.scanning { PulseDot() }
            VStack(alignment: .trailing, spacing: DS.Space.xxs) {
                DSValue(bytes: model.freeableBytes, .heading, weight: .semibold)
                DSText(full ? "could go · \(fmt(model.outsideBytes)) outside project folders" : "could go", .metadata).keepWhole()
            }
        }
        .help("\(fmt(model.outsideBytes)) of it is outside the project folders")
    }

    // MARK: List

    private var shownFootprints: [ProjectFootprint] {
        let now = Date()
        let search = TextQuery(query)
        return model.footprints.filter { f in
            active.matches(f.lastActivity, now: now)
                && search.matches(f.project.name, f.project.kind, f.id)
        }
    }

    private var list: some View {
        let shown = shownFootprints
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.sm) { projectSearch; projectFilterActions }
                    VStack(alignment: .leading, spacing: DS.Space.sm) { projectSearch; projectFilterActions }
                }
                .withoutAlignmentGuides()
                if active != .any {
                    DSFilterChip(title: String(localized: "Last active: \(active.title)")) { active = .any }
                }
                if !query.isEmpty || active != .any {
                    DSText(String(localized: "\(shown.count) of \(model.footprints.count) projects"), .metadata)
                }
            }
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, DS.Space.sm)
            Divider()
            projectTable(shown)
        }
    }

    private var projectSearch: some View {
        DSFilterField(String(localized: "Filter by name, type or folder"), text: $query).frame(minWidth: 140, maxWidth: .infinity)
    }

    private var projectFilterActions: some View {
        HStack(spacing: DS.Space.sm) {
            DSFilterButton("Filter projects", detail: "Narrow the project list by recent activity. The project scans and your removal choices stay the same.",
                           count: (query.isEmpty ? 0 : 1) + (active == .any ? 0 : 1), clear: { query = ""; active = .any }) {
                DSControlField("Last active") {
                    Picker("Last Active", selection: $active) {
                        ForEach(ProjectActivity.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                    DSText("Uses the newest change found in each project, not the last time you opened its app.", .metadata)
                }
            }
            TableColumnsButton(scope: "projects.list.5").fixedSize()
            DSInfoButton(title: String(localized: "Whitelist, blacklist and pins"), detail: String(localized: "Whitelist excludes a folder and its contents, including when a parent is cleaned. Blacklist adds a cleanup suggestion; it doesn't delete or select anything. Pins keep apps and folders easy to reach and don't change protection. Right-click a folder to change these choices."))
        }
    }

    private func projectTable(_ shown: [ProjectFootprint]) -> some View {
        FileTable(
            rows: shown.map(row),
            columns: [.name, .size, .change, .freeable, .modified, .kind, .location],
            hiddenByDefault: [.change, .modified, .kind, .location],
            titles: [.modified: String(localized: "Last Active"), .kind: String(localized: "Type")],
            autosave: "projects.list.5",
            selection: $model.selection,
            onOpen: { ids in FileActions.reveal(ids) },
            menu: menu)
        .dsEmptyOverlay(showing: shown.isEmpty) {
            if !model.footprints.isEmpty, shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if model.footprints.isEmpty {
                if model.scanning {
                    DSLoading("Looking for projects…")
                } else if !model.unreadablePlaces.isEmpty {
                    DSIncompleteEmpty(what: String(localized: "Projects"), unreadable: model.unreadablePlaces) { model.scan() }
                } else {
                    ContentUnavailableView {
                        Label("No Projects Found", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text(model.roots.isEmpty
                            ? String(localized: "MyMole looks for folders with a project file (Package.swift, package.json, .git …) in no folders yet.")
                            : String(localized: "MyMole looks for folders with a project file (Package.swift, package.json, .git …) in \(model.roots.map(Breakable.path).joined(separator: ", ")).")
                        )
                    } actions: {
                        Button("Add Folder…") { model.addRoot() }
                    }
                }
            }
        }
    }

    private func row(_ f: ProjectFootprint) -> FileRow {
        let heat = Heat(f.lastActivity)
        var r = FileRow(
            id: f.id, name: f.project.name, size: f.measured || f.bytes > 0 ? f.bytes : nil,
            freeable: f.removableBytes, modified: f.lastActivity > .distantPast ? f.lastActivity : nil,
            kind: f.project.kind, location: (f.id as NSString).deletingLastPathComponent, symbol: heat.symbol,
            tint: heat.nsColor)
        r.subtitle = [f.lastActivity > .distantPast ? f.lastActivity.listText : nil, f.project.kind.isEmpty ? nil : f.project.kind]
            .compactMap { $0 }.joined(separator: " · ")
        if case let (g, since)? = model.growth(f.id), abs(g) >= 1_048_576 {
            r.change = g
            r.changeHelp = g > 0 ? String(localized: "Grew since \(since.listText)") : String(localized: "Shrank since \(since.listText)")
        }
        r.pinned = model.pins.contains(f.id)
        if r.pinned {
            r.badge = String(localized: "Pinned")
            r.badgeHelp = String(localized: "Pinned for quick access. Pinning doesn't protect files or choose them for cleanup.")
            r.badgeTint = .secondaryLabelColor
        }
        return r
    }

    private func menu(_ ids: [String]) -> [TableMenuEntry] {
        guard !ids.isEmpty else { return [] }
        var out: [TableMenuEntry] = [
            .action(ids.allSatisfy(model.pins.contains) ? String(localized: "Unpin") : String(localized: "Pin")) {
                model.pins.set(ids, pinned: !ids.allSatisfy(model.pins.contains))
            },
            .action(ids.count == 1 ? String(localized: "Choose Rebuildable Data") : String(localized: "Choose Rebuildable Data in \(ids.count) Projects")) {
                model.chooseRebuildable(in: ids)
            }
        ]
        if ids.contains(where: { id in model.footprint(id)?.items.contains { $0.entries.contains { model.chosen.contains($0.path) } } == true }) {
            out.append(.action(String(localized: "Clear Choice")) { model.clearChoice(in: ids) })
        }
        if ids.count == 1 {
            out.append(.action(String(localized: "Refresh Current Project")) { model.refreshProject(ids[0]) })
            out.append(.action(String(localized: "Add Folder for Cleanup…")) { model.addFolderForCleanup(to: ids[0]) })
            out.append(.action(String(localized: "Show in Disk Map")) { showInDiskMap(ids[0]) })
        }
        out.append(.divider)
        out += FileActions.menu(ids, canOpen: false)
        return out
    }

    private func showInDiskMap(_ path: String) {
        let storage = app.storage
        if !storage.scanning, storage.root?.find(path: path) != nil {
            storage.show(folder: path)
        } else {
            storage.scan(path: path)
        }
        app.pane = .diskMap
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if model.selection.count == 1, let id = model.selection.first, let f = model.footprint(id) {
            ProjectDetail(model: model, footprint: f, showInDiskMap: { showInDiskMap(id) })
                .id(id)
        } else {
            ProjectsOverview(model: model)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        DSActionBar {
            DSText("\(model.chosenEntries.count.formatted()) item\(model.chosenEntries.count == 1 ? "" : "s") chosen · \(Freeing.phrase(model.chosenBytes, frees: model.chosenFrees))", .lead)
                .keepWhole()
            Button("Clear") { model.chosen = [] }
                .accessibilityLabel("Clear the choice")
                .controlSize(.small)
        } trailing: {
            Button("Move to Trash…") { confirming = true }
                .primaryAction()
                .disabled(model.trashBlocker != nil)
                .help(model.trashBlocker ?? "")
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

struct ProjectControlsLayout: Layout {
    let spacing: CGFloat

    func makeCache(subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }
    func updateCache(_ cache: inout [CGSize], subviews: Subviews) { cache = makeCache(subviews: subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        guard cache.count == 4 else { return .zero }
        let ideal = cache.reduce(0) { $0 + $1.width } + spacing * 3
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        let first = max(cache[0].height, cache[2].height, cache[3].height)
        return CGSize(width: width, height: ideal <= width ? max(first, cache[1].height) : first + spacing + cache[1].height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        guard cache.count == 4 else { return }
        let ideal = cache.reduce(0) { $0 + $1.width } + spacing * 3
        let wide = ideal <= bounds.width
        let first = max(cache[0].height, cache[2].height, cache[3].height, wide ? cache[1].height : 0)
        let x = [bounds.minX, wide ? bounds.minX + cache[0].width + spacing : bounds.minX,
                 bounds.maxX - cache[3].width - spacing - cache[2].width, bounds.maxX - cache[3].width]
        for index in 0..<4 {
            let y = index == 1 && !wide ? bounds.minY + first + spacing : bounds.minY + (first - cache[index].height) / 2
            subviews[index].place(at: CGPoint(x: x[index], y: y), proposal: ProposedViewSize(cache[index]))
        }
    }
}

// MARK: - Overview

/// With no single project selected: where developer data goes across every
/// project, by category.
struct ProjectsOverview: View {
    let model: ProjectsModel

    var body: some View {
        DSPage(width: .full) {
            if model.footprints.isEmpty {
                EmptyView()
            } else {
                DSSection(
                    "All projects",
                    footer: model.selection.count > 1
                        ? String(localized: "\(model.selection.count) projects selected. Right-click them to choose their rebuildable data.")
                        : String(localized: "Select a project to see where its space goes and choose what to remove.")
                ) {
                    FootprintBar(parts: FootprintCategory.allCases.map { ($0, model.bytes($0)) })
                    ForEach(FootprintCategory.allCases.filter { model.bytes($0) > 0 }, id: \.self) { c in
                        CategoryRow(category: c, bytes: model.bytes(c))
                    }
                }
                if !model.ruleList.isEmpty {
                    DSSection(
                        "Your rules",
                        footer: String(localized: "Whitelist excludes items and their contents from cleanup. Blacklist adds cleanup suggestions. Pinning is quick access only. Right-click a folder to change its rule; saved rules apply on every scan.")
                    ) {
                        ForEach(model.ruleList) { rule in
                            DSRow(title: rule.title) {
                                DSIcon(symbol: rule.isKeep ? FootprintCategory.kept.symbol : FootprintCategory.marked.symbol,
                                       tint: rule.isKeep ? .secondary : FootprintCategory.marked.color)
                            } detail: {
                                if let path = rule.path {
                                    DSPath(path)
                                } else {
                                    DSText("In every project", .metadata)
                                }
                            } trailing: {
                                Button("Remove") { model.remove(rule) }.controlSize(.small)
                            }
                        }
                    }
                }
                if let at = model.scannedAt {
                    DSText("Last complete scan \(at.listText)", .metadata).padding(.horizontal, DS.Space.xs)
                }
            }
        }
    }
}

struct CategoryRow: View {
    let category: FootprintCategory
    let bytes: Int64

    var body: some View {
        DSRow(title: category.title) {
            Circle().fill(category.color).frame(width: 9, height: 9)
        } detail: {
            DSText(category.note, .metadata)
        } trailing: {
            DSValue(bytes: bytes)
        }
    }
}

/// One bar split by category, widest part first.
struct FootprintBar: View {
    let parts: [(FootprintCategory, Int64)]

    var body: some View {
        let shown = parts.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let total = max(shown.reduce(0) { $0 + $1.1 }, 1)
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(shown, id: \.0) { c, b in
                    Rectangle()
                        .fill(c.color)
                        .frame(width: max(2, (g.size.width - CGFloat(shown.count - 1)) * CGFloat(b) / CGFloat(total)))
                        .help("\(c.title): \(fmt(b))")
                }
            }
        }
        .frame(height: 12)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

// MARK: - One project

struct ProjectDetail: View {
    @Bindable var model: ProjectsModel
    let footprint: ProjectFootprint
    let showInDiskMap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DS.Space.page)
                .padding(.top, DS.Space.lg)
                .padding(.bottom, DS.Space.md)
            Divider()
            FootprintOutline(
                model: model, footprint: footprint, chosen: model.chosen, age: model.age,
                measured: Set(model.contents.keys), contentsRevision: model.contentsRevision, menu: menu)
        }
    }

    private var header: some View {
        let heat = Heat(footprint.lastActivity)
        return VStack(alignment: .leading, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: heat.symbol).foregroundStyle(heat.color)
                    DSName(footprint.project.name, .title, lines: 2)
                    Spacer(minLength: DS.Space.sm)
                    DSValue(bytes: footprint.bytes, .title, weight: .semibold)
                }
                DSPath(footprint.id)
                // One line where they fit; the growth goes on a line of its own where not.
                DSFlow(spacing: DS.Space.xs) {
                    heatBadges(heat)
                    growthBadge
                }
            }

            FootprintBar(parts: FootprintCategory.allCases.map { ($0, footprint.bytes($0)) })

            if !footprint.measured {
                DSNotice(
                    model.scanning ? .working : .info,
                    model.scanning
                        ? String(localized: "Measuring the project folder. Sizes inside it are from the last scan until then.")
                        : String(localized: "The project folder hasn't been measured yet. Rescan to see what's inside it."))
            }

            ProjectControlsLayout(spacing: DS.Space.sm) {
                agePicker
                chooseRebuildable
                measuringIndicator
                more
            }
        }
    }

    private var measuringIndicator: some View {
        ZStack {
            if model.rescanning.contains(footprint.id) { PulseDot().help("Measuring again…") }
        }
        .frame(width: 8, height: 8)
    }

    @ViewBuilder private func heatBadges(_ heat: Heat) -> some View {
        DSBadge(heat.title, tint: heat == .dormant ? .secondary : heat.color)
            .help("Last change \(footprint.lastActivity.listText)")
        if !footprint.project.kind.isEmpty { DSBadge(footprint.project.kind, tint: .secondary) }
    }

    @ViewBuilder private var growthBadge: some View {
        if case let (g, since)? = model.growth(footprint.id), abs(g) >= 1_048_576 {
            DSBadge("\(g > 0 ? "+" : "−")\(fmt(abs(g))) since \(since.listText)", tint: g > 0 ? .orange : .green)
        }
    }

    private var agePicker: some View {
        DSControlField("Choose data last changed") {
            Picker("Choose", selection: $model.age) {
                ForEach(ProjectsModel.Age.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Only data last changed before this is chosen")
        }
    }

    private var chooseRebuildable: some View {
        Button("Choose Rebuildable") { model.chooseRebuildable(in: [footprint.id]) }
            .help("Dependencies, build output and caches (tools recreate them), plus folders you added")
            .fixedSize()
    }

    /// The project's less frequent actions, in one menu.
    private var more: some View {
        Menu {
            Button("Refresh Current Project") { model.refreshProject(footprint.id) }
                .disabled(model.refreshing || model.trashing)
            Button("Show in Disk Map", action: showInDiskMap)
            FileMenuItems(paths: [footprint.id], canOpen: false)
            Divider()
            Button("Add Folder for Cleanup…") { model.addFolderForCleanup(to: footprint.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for this project")
    }

    /// A row's menu: choosing, the rules for what's offered, and the usual
    /// file actions.
    private func menu(_ target: FootprintOutline.Target) -> [TableMenuEntry] {
        let project = footprint.id
        switch target {
        case .item(let item):
            var out: [TableMenuEntry] = []
            if item.removable {
                out.append(.action(model.check(item) == .on ? String(localized: "Unchoose") : String(localized: "Choose")) { model.toggle(item) })
                out.append(.divider)
            }
            out.append(.action(item.entries.allSatisfy { model.pins.contains($0.path) } ? String(localized: "Unpin") : String(localized: "Pin")) {
                let paths = item.entries.map(\.path)
                model.pins.set(paths, pinned: !paths.allSatisfy(model.pins.contains))
            })
            out += Self.rules(model, item: item, paths: item.entries.map(\.path), name: item.attribution == .inside ? item.title : nil, project: project)
            out.append(.divider)
            out += FileActions.menu(Array(item.entries.prefix(50).map(\.path)), canOpen: false)
            return out
        case .path(let item, let path):
            var out: [TableMenuEntry] = []
            if item.removable {
                out.append(.action(model.state(of: path) == .on ? String(localized: "Unchoose") : String(localized: "Choose")) { model.toggle(path: path) })
                out.append(.divider)
            }
            let name = item.attribution == .inside && path != project ? (path as NSString).lastPathComponent : nil
            out.append(.action(model.pins.contains(path) ? String(localized: "Unpin") : String(localized: "Pin")) {
                let paths = [path]
                model.pins.set(paths, pinned: !paths.allSatisfy(model.pins.contains))
            })
            out += Self.rules(model, item: item, paths: [path], name: name, project: project)
            out.append(.divider)
            out += FileActions.menu([path], canOpen: false)
            return out
        }
    }

    /// The rule actions for some of an item's paths. `name` is the folder
    /// name a rule for every project would use.
    static func rules(_ model: ProjectsModel, item: FootprintItem, paths: [String], name: String?, project: String) -> [TableMenuEntry] {
        switch item.category {
        case .source:
            var out: [TableMenuEntry] = []
            let cleanable = paths.filter { ProjectRules.canClean($0, project: project) }
            if !cleanable.isEmpty {
                out.append(.action(cleanable.count == 1 ? String(localized: "Blacklist — Suggest for Cleanup") : String(localized: "Blacklist These \(cleanable.count) Folders")) {
                    model.requestRule(.blacklist(cleanable, project: project))
                })
            }
            if paths.count == 1, let name, ProjectRules.canCleanEverywhere(name: name) {
                out.append(.action(String(localized: "Blacklist Folders Named “\(name)” in Every Project")) { model.requestRule(.blacklistName(name)) })
            }
            out.append(.action(String(localized: "Whitelist — Never Clean This")) { model.requestRule(.whitelist(paths, project: project)) })
            return out
        case .kept:
            return [.action(String(localized: "Remove from Whitelist")) { model.forget(paths, in: project) }]
        case .marked:
            return [
                .action(String(localized: "Remove from Blacklist")) { model.forget(paths, in: project) },
                .action(String(localized: "Whitelist — Never Clean This")) { model.requestRule(.whitelist(paths, project: project)) }
            ]
        case .git:
            return []
        default:
            var out: [TableMenuEntry] = [
                .action(paths.count == 1 ? String(localized: "Whitelist — Never Clean This") : String(localized: "Whitelist These \(paths.count) Items")) { model.requestRule(.whitelist(paths, project: project)) }
            ]
            if let name, item.category != .worktrees {
                out.append(.action(String(localized: "Whitelist “\(name)” in Every Project")) { model.requestRule(.whitelistName(name)) })
            }
            return out
        }
    }
}

/// Result of the last move, with Undo while it's still possible.
struct ProjectsNotice: View {
    let model: ProjectsModel

    var body: some View {
        if let n = model.notice {
            DSUndoToast(text: n.text, canUndo: n.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
        }
    }
}

/// When a project was last worked on, to filter a long list by.
enum ProjectActivity: String, CaseIterable, Identifiable {
    case any, week, month, olderQuarter, olderYear
    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: String(localized: "Any Time")
        case .week: String(localized: "Active This Week")
        case .month: String(localized: "Active This Month")
        case .olderQuarter: String(localized: "Untouched for 3 Months")
        case .olderYear: String(localized: "Untouched for a Year")
        }
    }

    func matches(_ last: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(last)
        let day: TimeInterval = 86_400
        return switch self {
        case .any: true
        case .week: age <= 7 * day
        case .month: age <= 30 * day
        case .olderQuarter: age > 91 * day
        case .olderYear: age > 365 * day
        }
    }
}
