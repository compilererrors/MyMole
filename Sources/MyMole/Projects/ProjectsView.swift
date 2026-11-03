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

    var body: some View {
        VStack(spacing: 0) {
            summary
            if let error = model.rulesError {
                DSNotice(.critical, "Your project rules couldn't be read (\(error)). Nothing is moved until they can be.") {
                    Button("Try Again") { model.reloadRules() }
                }
                .padding(.horizontal, DS.Space.page)
                .padding(.bottom, DS.Space.md)
            }
            HSplitView {
                // The list takes what the detail leaves; the detail stays a
                // readable column, as an inspector does.
                list.frame(minWidth: 380, idealWidth: 560, maxWidth: .infinity)
                detail.frame(minWidth: 340, idealWidth: 440, maxWidth: 520)
            }
            if !model.chosen.isEmpty { actionBar }
        }
        .overlay(alignment: .bottom) {
            ProjectsNotice(model: model).padding(.bottom, model.chosen.isEmpty ? 16 : 70)
        }
        .paneToolbar("Projects", subtitle: subtitle) { tools }
        .confirmationDialog(
            "Move \(model.chosenEntries.count.formatted()) item\(model.chosenEntries.count == 1 ? "" : "s") to the Trash?",
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) { model.trashChosen() }
        } message: {
            Text("\(ByteCountFormatter.string(fromByteCount: model.chosenBytes, countStyle: .file)) from \(Set(model.chosenEntries.map(\.project)).count) project(s):\n\(reviewList)\n\nAnything holding a Git repository, key files, files Git tracks or uncommitted work stays. You can undo right after, or put things back from the Trash later.")
        }
        .onAppear { model.scanIfNeeded() }
    }

    /// The paths that go, for a last look before confirming.
    private var reviewList: String {
        let home = Home.path
        let paths = model.chosenEntries.map(\.entry.path).map {
            $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0
        }
        let shown = paths.prefix(8).joined(separator: "\n")
        let list = paths.count > 8 ? shown + "\n… and \(paths.count - 8) more" : shown
        let left = model.excluded.count
        return left == 0 ? list : list + "\n\(left == 1 ? "1 thing" : "\(left) things") you left out inside them stay\(left == 1 ? "s" : "")."
    }

    private var subtitle: String {
        if model.scanning {
            return model.footprints.isEmpty
                ? "Looking for projects…"
                : "Measuring \(model.measuredCount) of \(model.footprints.count) projects…"
        }
        guard !model.footprints.isEmpty else { return "Every project and what it leaves on disk" }
        let line = "\(model.footprints.count) projects · \(fmt(model.totalBytes)) · \(fmt(model.freeableBytes)) could go"
        return model.incomplete ? line + " · some folders couldn't be read" : line
    }

    @ToolbarContentBuilder private var tools: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Looking in") {
                    ForEach(model.roots, id: \.self) { root in
                        Menu(Breakable.path(root).replacingOccurrences(of: "\u{200B}", with: "")) {
                            Button("Reveal in Finder") { FileActions.reveal([root]) }
                            Button("Stop Looking Here") { model.removeRoot(root) }
                        }
                    }
                }
                Divider()
                Button("Add Folder…") { model.addRoot() }
                Button("Use the Usual Folders") { model.resetRoots() }
            } label: {
                Label("Project Folders", systemImage: "folder.badge.plus")
            }
            .help("Choose the folders searched for projects")
            if model.scanning {
                Button {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop measuring; the last complete result stays")
            } else {
                Button {
                    model.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Measure every project again")
            }
        }
    }

    // MARK: Summary

    /// The heat chips and the total. Never wider than the pane: where the
    /// whole line doesn't fit, the total says less (it's in the title too).
    private var summary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.sm) {
                chips
                Spacer(minLength: DS.Space.sm)
                total(full: true)
            }
            HStack(spacing: DS.Space.sm) {
                chips
                Spacer(minLength: DS.Space.sm)
                total(full: false)
            }
            HStack(spacing: DS.Space.sm) {
                chips
                Spacer(minLength: 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.sm) { chips }
            }
        }
        .padding(.horizontal, DS.Space.page)
        .padding(.vertical, DS.Space.md)
    }

    @ViewBuilder private var chips: some View {
        ForEach(Heat.allCases, id: \.self) { h in
            let n = model.count(h)
            Button {
                model.selection = Set(model.footprints.filter { Heat($0.lastActivity) == h }.map(\.id))
            } label: {
                DSCountChip(n, h.title, h.color)
            }
            .buttonStyle(.plain)
            .help("Select the projects \(h == .dormant ? "untouched for a month or more" : h.title.lowercased())")
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

    private var list: some View {
        FileTable(
            rows: model.footprints.map(row),
            columns: [.name, .size, .change, .freeable, .modified, .kind, .location],
            hiddenByDefault: [.change, .modified, .kind, .location],
            titles: [.modified: "Last Active", .kind: "Type"],
            autosave: "projects.list.5",
            selection: $model.selection,
            onOpen: { ids in FileActions.reveal(ids) },
            menu: menu)
        .overlay {
            if model.footprints.isEmpty {
                if model.scanning {
                    DSLoading("Looking for projects…")
                } else {
                    ContentUnavailableView {
                        Label("No Projects Found", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("MyMole looks for folders with a project file (Package.swift, package.json, .git …) in \(model.roots.isEmpty ? "no folders yet" : model.roots.map(Breakable.path).joined(separator: ", ")).")
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
            r.changeHelp = "\(g > 0 ? "Grew" : "Shrank") since \(since.listText)"
        }
        return r
    }

    private func menu(_ ids: [String]) -> [TableMenuEntry] {
        guard !ids.isEmpty else { return [] }
        var out: [TableMenuEntry] = [
            .action(ids.count == 1 ? "Choose Rebuildable Data" : "Choose Rebuildable Data in \(ids.count) Projects") {
                model.chooseRebuildable(in: ids)
            }
        ]
        if ids.contains(where: { id in model.footprint(id)?.items.contains { $0.entries.contains { model.chosen.contains($0.path) } } == true }) {
            out.append(.action("Clear Choice") { model.clearChoice(in: ids) })
        }
        if ids.count == 1 {
            out.append(.action("Add Folder for Cleanup…") { model.addFolderForCleanup(to: ids[0]) })
            out.append(.action("Show in Disk Map") { showInDiskMap(ids[0]) })
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
            DSText("\(model.chosenEntries.count.formatted()) item\(model.chosenEntries.count == 1 ? "" : "s") chosen · \(fmt(model.chosenBytes))", .lead)
                .keepWhole()
            Button("Clear") { model.chosen = [] }
                .controlSize(.small)
        } trailing: {
            Button("Move to Trash…") { confirming = true }
                .primaryAction()
                .disabled(model.trashing || model.rulesError != nil)
                .help(model.rulesError != nil ? "Your project rules couldn't be read" : model.trashing ? "Moving to the Trash…" : "")
        }
    }
}

private func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

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
                        ? "\(model.selection.count) projects selected. Right-click them to choose their rebuildable data."
                        : "Select a project to see where its space goes and choose what to remove."
                ) {
                    FootprintBar(parts: FootprintCategory.allCases.map { ($0, model.bytes($0)) })
                    ForEach(FootprintCategory.allCases.filter { model.bytes($0) > 0 }, id: \.self) { c in
                        CategoryRow(category: c, bytes: model.bytes(c))
                    }
                }
                if !model.ruleList.isEmpty {
                    DSSection(
                        "Your rules",
                        footer: "Right-click anything in a project to add a rule. Rules apply on every scan."
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
                measured: Set(model.contents.keys), menu: menu)
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.xs) { heatBadges(heat); growthBadge }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(spacing: DS.Space.xs) { heatBadges(heat) }
                        growthBadge
                    }
                }
            }

            FootprintBar(parts: FootprintCategory.allCases.map { ($0, footprint.bytes($0)) })

            if !footprint.measured {
                DSNotice(
                    model.scanning ? .working : .info,
                    model.scanning
                        ? "Measuring the project folder. Sizes inside it are from the last scan until then."
                        : "The project folder hasn't been measured yet. Rescan to see what's inside it.")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.sm) {
                    agePicker
                    chooseRebuildable
                    Spacer(minLength: DS.Space.sm)
                    if model.rescanning.contains(footprint.id) { PulseDot().help("Measuring again…") }
                    more
                }
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.sm) {
                        agePicker
                        Spacer(minLength: DS.Space.sm)
                        more
                    }
                    chooseRebuildable
                }
            }
        }
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
        Picker("Choose", selection: $model.age) {
            ForEach(ProjectsModel.Age.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .help("Only data last changed before this is chosen")
    }

    private var chooseRebuildable: some View {
        Button("Choose Rebuildable") { model.chooseRebuildable(in: [footprint.id]) }
            .help("Dependencies, build output and caches (tools recreate them), plus folders you added")
            .fixedSize()
    }

    /// The project's less frequent actions, in one menu.
    private var more: some View {
        Menu {
            Button("Show in Disk Map", action: showInDiskMap)
            Button("Reveal in Finder") { FileActions.reveal([footprint.id]) }
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
                out.append(.action(model.check(item) == .on ? "Unchoose" : "Choose") { model.toggle(item) })
                out.append(.divider)
            }
            out += Self.rules(model, item: item, paths: item.entries.map(\.path), name: item.attribution == .inside ? item.title : nil, project: project)
            out.append(.divider)
            out += FileActions.menu(Array(item.entries.prefix(50).map(\.path)), canOpen: false)
            return out
        case .path(let item, let path):
            var out: [TableMenuEntry] = []
            if item.removable {
                out.append(.action(model.state(of: path) == .on ? "Unchoose" : "Choose") { model.toggle(path: path) })
                out.append(.divider)
            }
            let name = item.attribution == .inside && path != project ? (path as NSString).lastPathComponent : nil
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
                out.append(.action(cleanable.count == 1 ? "Clean This Folder" : "Clean These \(cleanable.count) Folders") {
                    model.clean(cleanable, in: project)
                })
            }
            if paths.count == 1, let name, ProjectRules.canCleanEverywhere(name: name) {
                out.append(.action("Clean Folders Named “\(name)” in Every Project") { model.cleanEverywhere(named: name) })
            }
            return out
        case .kept:
            return [.action("Allow Cleaning Again") { model.forget(paths, in: project) }]
        case .marked:
            return [.action("Stop Cleaning \(paths.count == 1 ? "This" : "These")") { model.forget(paths, in: project) }]
        case .git:
            return []
        default:
            var out: [TableMenuEntry] = [
                .action(paths.count == 1 ? "Never Clean This" : "Never Clean These \(paths.count)") { model.keep(paths, in: project) }
            ]
            if let name, item.category != .worktrees {
                out.append(.action("Never Clean “\(name)” in Any Project") { model.keepEverywhere(named: name) })
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
