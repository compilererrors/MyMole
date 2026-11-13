import StorageKit
import SwiftUI

/// The Disk Map pane: chart and list side by side, plus Large Files,
/// Changes since the last scan, and the folders that couldn't be read.
struct StorageView: View {
    @AppStorage("diskMap.listWidth") private var listWidth = 0.0
    @AppStorage("diskMap.chartHidden") private var chartHidden = false
    @Bindable var model: StorageModel
    @State private var places = PlacesModel()

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model)
            Group {
                switch model.tab {
                case .browse: browse
                case .largeFiles: LargeFilesView(model: model)
                case .changes: ChangesView(model: model)
                case .skipped: SkippedView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .dsBottom(showing: !model.marked.isEmpty || model.trashing) {
            BasketBar(model: model)
        } toast: {
            NoticeToast(model: model)
        }
        .sheet(isPresented: $model.showReview) { ReviewSheet(model: model) }
        .task(id: model.removalHintKey) { await model.warmRemovalHints() }
        .liveRefresh(every: .seconds(2), events: [.applications, .protections]) { await model.warmRemovalHints() }
        .onReceive(NotificationCenter.default.publisher(for: KeepChanges.name)) { _ in model.invalidateRemovalHints() }
        .paneToolbar("Disk Map", subtitle: "\(subtitle)") { tools }
        .onAppear {
            places.refresh()
            if model.root == nil && !model.scanning {
                model.scan(path: model.mapsOnOpen)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in places.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in places.refresh() }
    }

    private var subtitle: String {
        if let opened = model.opened {
            return String(localized: "Saved scan \(opened.file), made \(opened.date.formatted(date: .abbreviated, time: .shortened)) · only to look at")
        }
        if model.scanning {
            return String(localized: "Scanning… \(model.liveFiles.formatted()) files · \(ByteCountFormatter.string(fromByteCount: model.liveBytes, countStyle: .file))")
        }
        guard let r = model.root else { return String(localized: "Where your space went") }
        let size = ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
        let files = r.fileCount.formatted()
        if model.incomplete { return String(localized: "Partial map · \(size) in \(files) files") }
        return model.lastDuration.map { String(localized: "\(size) in \(files) files in \(Int($0.rounded())) s") }
            ?? String(localized: "\(size) in \(files) files")
    }

    @PaneToolsBuilder private var tools: [PaneTool] {
        PaneTool.choice("disk-map.section", "Section", selection: $model.tab, options: [
            (StorageModel.Tab.browse, String(localized: "Browse")),
            (.largeFiles, String(localized: "Large Files")),
            (.changes, String(localized: "Changes")),
        ] + (model.denied.isEmpty ? [] : [(.skipped, String(localized: "Skipped (\(model.denied.count))"))]))
        if model.tab == .browse {
            PaneTool.menu("disk-map.chart", "\(model.chart.title)", symbol: model.chart.symbol, help: "How to draw the disk map") {
                Picker("View", selection: $model.chart) {
                    ForEach(StorageModel.Chart.allCases) { c in
                        Label {
                            Text(c.title)
                            Text(c.detail)
                        } icon: {
                            Image(systemName: c.symbol)
                        }
                        .tag(c)
                    }
                }
                .pickerStyle(.inline)
            }
            PaneTool.toggle("disk-map.hide-chart", "Hide Chart", symbol: "sidebar.leading",
                            help: chartHidden ? "Show the chart beside the list" : "Hide the chart and give the list the whole pane",
                            isOn: $chartHidden)
            PaneTool.toggle("disk-map.kind-colors", "Color by Kind", symbol: "paintpalette",
                            help: "Color by file kind instead of by folder", isOn: $model.colorByKind)
        }
        if model.scanning {
            PaneTool.button("disk-map.stop", "Stop Scan", symbol: "stop.fill", help: "Stop scanning") { model.cancelScan() }
        } else {
            PaneTool.menu("disk-map.refresh", "\(model.refreshTitle)", symbol: "arrow.clockwise",
                          help: "Refresh the open folder (⌘R), or choose Rescan Entire Map",
                          enabled: !model.trashing && model.opened == nil, primary: { model.refreshCurrent() }) {
                Button(model.refreshTitle, action: model.refreshCurrent)
                    .disabled(model.opened != nil)
                Button("Rescan Entire Map", action: model.rescan)
            }
        }
        PaneTool.menu("disk-map.places", "Places", symbol: "externaldrive", help: "Map a common folder or a disk") {
            PlacesMenuItems(model: model, places: places)
        }
        PaneTool.button("disk-map.choose", "Choose Folder", symbol: "folder.badge.plus", help: "Map another folder or disk (⌘O)") {
            model.chooseFolder()
        }
    }

    /// The chart takes what the list leaves. The user drags the divider to
    /// set the list's width, which is kept, or hides the chart for a list as
    /// wide as the pane. Neither ever runs past the window, whatever its size.
    private var browse: some View {
        Group {
            if chartHidden {
                InspectorList(model: model)
            } else {
                ListSplit(width: $listWidth) { chart } list: { InspectorList(model: model) }
            }
        }
    }

    /// The list's width: as saved, kept between the narrowest readable list
    /// and the narrowest chart; nil (never dragged) is 44 % of the pane.
    static func listWidth(saved: Double, total: CGFloat) -> CGFloat {
        let narrowest = DS.Size.inspectorWidth
        let widest = max(narrowest, total - DS.Size.chartMinWidth - DS.Size.splitHandle)
        let wanted = saved > 0 ? CGFloat(saved) : min(max(narrowest, total * 0.44), 500)
        return min(max(wanted, narrowest), widest)
    }

    private var chart: some View {
        ZStack {
            if model.root == nil {
                CenterCard(symbol: nil, title: "Scanning…", subtitle: "\(model.liveFiles.formatted()) files so far") {}
            } else if model.currentIsEmpty {
                ContentUnavailableView("No Mapped Contents", systemImage: "folder",
                    description: Text("This folder has no files or folders in the current map."))
                    .transition(.opacity)
            } else {
                Group {
                    switch model.chart {
                    case .rings: SunburstChart(model: model)
                    case .wheel: SliceChart(model: model, style: .wheel)
                    case .pie: SliceChart(model: model, style: .pie)
                    case .boxes: TreemapChart(model: model)
                    case .columns: ColumnsChart(model: model)
                    case .bars: BarsChart(model: model)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.content, value: model.currentIsEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if model.colorByKind { KindLegend().padding(Theme.pad) }
        }
        .contextMenu { ChartMenu(model: model) }
        // The chart is drawn, not built from views: VoiceOver gets its
        // folders here, the same ones the list beside it shows.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            model.current.map { String(localized: "\(model.chart.title) of \($0.name)") }
                ?? String(localized: "\(model.chart.title) of the disk"))
        .accessibilityChildren {
            if model.currentIsEmpty {
                Text("No Mapped Contents")
                    .accessibilityValue(Text("This folder has no files or folders in the current map."))
            } else {
                ForEach((model.current?.subfolders ?? []).sorted { $0.size > $1.size }.prefix(30), id: \.path) { f in
                    Text(f.name)
                        .accessibilityValue(Self.share(f, of: model.current))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.open(f) }
                }
            }
        }
    }
}

extension StorageView {
    /// "1,2 GB, 14 % of Library", for VoiceOver.
    static func share(_ f: Folder, of parent: Folder?) -> String {
        let size = ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file)
        guard let parent, parent.size > 0 else { return size }
        return String(localized: "\(size), \(Int((Double(f.size) / Double(parent.size) * 100).rounded())) % of \(parent.name)")
    }
}

/// Right-click on the chart: acts on the segment under the pointer.
struct ChartMenu: View {
    let model: StorageModel

    var body: some View {
        switch model.hovered {
        case .folder(let f)?:
            let path = f.path
            Button("Open") { model.open(f) }
            Button("Select in List") { model.selection = [path] }
            Divider()
            Button(model.isMarked(path) ? String(localized: "Unchoose") : String(localized: "Choose for Removal")) {
                model.toggle(Marked(path: path, name: f.name, size: f.size, isFolder: true))
            }
            Divider()
            FileMenuItems(paths: [path])
        case .files(let f)?:
            if f !== model.current {
                Button("Open \(f.name)") { model.open(f) }
                Divider()
            }
            FileMenuItems(paths: [f.path], canOpen: false)
        case nil:
            if let cur = model.current {
                if cur.parent != nil { Button("Enclosing Folder") { model.back() } }
                FileMenuItems(paths: [cur.path], canOpen: false)
            }
        }
    }
}

/// Finder-style path bar: one line, scrolls sideways when deep, every
/// level clickable, the current folder emphasized.
struct PathBar: View {
    let model: StorageModel

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Button(action: model.back) {
                Label("Back", systemImage: "chevron.backward")
                    .labelStyle(.titleAndIcon).fixedSize()
            }
            .buttonStyle(.bordered)
            .disabled(model.current?.parent == nil)
            .help(model.current?.parent.map { String(localized: "Back to \($0.name) (⌘↑)") } ?? String(localized: "You're at the top"))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        let lineage = model.lineage
                        ForEach(Array(lineage.enumerated()), id: \.offset) { i, f in
                            if i > 0 {
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            let last = i == lineage.count - 1
                            Group {
                                if last { segment(f, first: i == 0, current: true) }
                                else { Button { model.open(f) } label: { segment(f, first: i == 0, current: false) } }
                            }
                            .buttonStyle(.plain)
                            .contextMenu { FileMenuItems(paths: [f.path], canOpen: false) }
                            .help(f.path)
                            .id(i)
                        }
                    }
                }
                .accessibilityIdentifier("diskMap.breadcrumbs")
                .onChange(of: model.lineage.count) { _, n in
                    if n > 1 { proxy.scrollTo(n - 1, anchor: .trailing) }
                }
            }
            if let space = model.diskSpace, let root = model.root, !model.scanning {
                OutsideTheMap(space: space, mapped: root.size)
                    .fixedSize()
            }
        }
        .padding(.horizontal, DS.Space.page)
        .frame(minHeight: 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func segment(_ folder: Folder, first: Bool, current: Bool) -> some View {
        Label(first ? displayRoot(folder) : folder.name, systemImage: first ? "internaldrive" : "folder")
            .lineLimit(1).fixedSize()
            .font(.callout.weight(current ? .semibold : .regular))
            .foregroundStyle(current ? .primary : .secondary)
    }

    private func displayRoot(_ f: Folder) -> String {
        f.path == Home.path ? String(localized: "Home") : f.path
    }
}

/// What's used on the disk but isn't in the map, and why: the system, apps
/// and other users outside the mapped folder, and space macOS frees by itself.
struct OutsideTheMap: View {
    let space: DiskSpace
    let mapped: Int64
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            Label("\(ByteSize.format(space.outside(mapped: mapped))) not in the map", systemImage: "questionmark.circle")
                .labelStyle(.titleAndIcon)
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("What's on the disk but isn't in this map")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Not in the Map").font(.headline)
                row(String(localized: "Used on the disk"), space.used)
                row(String(localized: "In this map"), mapped)
                row(String(localized: "Not in the map"), space.outside(mapped: mapped))
                DSText("macOS itself, apps and other users' folders outside the mapped folder, and folders MyMole couldn't read.", .metadata)
                Divider()
                row(String(localized: "Purgeable"), space.purgeable)
                DSText(purgeableText, .metadata)
            }
            .padding(DS.Space.lg)
            .frame(width: 340)
            .dialogKeyboard()
        }
    }

    private var purgeableText: String {
        let count = space.snapshots?.count ?? 0
        let snapshots = count == 0 ? "" : String(localized: " \(count) local Time Machine snapshot\(count == 1 ? " is" : "s are") on this disk.")
        return String(localized: "Counted as free, as Finder does: macOS frees it by itself when space is needed, mostly caches it manages and local Time Machine snapshots.") + snapshots
    }

    private func row(_ title: String, _ bytes: Int64) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(ByteSize.format(bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

struct KindLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(FileKind.allCases, id: \.self) { k in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(ChartColors.kind(k)).frame(width: 10, height: 10)
                    Text(k.title).font(.caption)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

/// Folders the scan couldn't open, so a gap in the numbers is never silent.
struct SkippedView: View {
    let model: StorageModel

    var body: some View {
        if model.denied.isEmpty {
            ContentUnavailableView(
                model.scanning ? String(localized: "Scan Still Running") : String(localized: "No Unreadable Folders"),
                systemImage: model.scanning ? "hourglass" : "checkmark.circle",
                description: Text(
                    model.scanning
                        ? "Folders the scan can't read appear here. The result is complete when scanning finishes."
                        : "This scan reported no folders it couldn't read."))
        } else {
            List {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.denied.count) folder\(model.denied.count == 1 ? "" : "s") couldn't be read").font(.headline)
                    Text(
                        "Their contents aren't counted above. Most are protected by macOS; Full Disk Access lets MyMole see inside the ones that belong to you."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Button("Open Full Disk Access Settings") { FullDiskAccess.openSettings() }
                        .buttonStyle(.bordered)
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
                ForEach(model.denied, id: \.self) { p in
                    Label {
                        DSPath(p, .body)
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    .contextMenu { FileMenuItems(paths: [p], canOpen: false) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

/// What's marked, and the way to remove it.
struct BasketBar: View {
    @Bindable var model: StorageModel

    var body: some View {
        DSActionBar {
            if model.trashing {
                PulseDot()
                DSText(activity, .body)
            } else {
                DSIcon(symbol: "checklist")
                DSText("\(model.marked.count) chosen · \(Freeing.phrase(model.markedBytes, frees: model.markedFrees))", .body)
            }
        } trailing: {
            if model.trashing {
                if model.removalPhase != .restoring {
                    Button(model.removalStopping ? "Stopping…" : "Stop", action: model.stopRemoval)
                        .controlSize(.large)
                        .disabled(!model.canStopRemoval)
                        .help("Stops before the next item. Anything already moved can be undone.")
                }
            } else {
            Button("Clear") { model.marked.removeAll() }
                .accessibilityLabel("Clear the choice")
                .controlSize(.large)
                .disabled(model.trashing)
            Button("Move to Trash…", action: model.beginTrashReview)
                .primaryAction()
                .disabled(!model.canTrash)
            }
        }
    }

    private var activity: String {
        if model.removalStopping { return String(localized: "Stopping after the current item…") }
        return switch model.removalPhase {
        case .preparing: String(localized: "Preparing to move…")
        case .stoppingScan: String(localized: "Stopping the scan before moving…")
        case .waiting: String(localized: "Waiting for another operation…")
        case .moving: String(localized: "Moving to the Trash…")
        case .restoring: String(localized: "Restoring…")
        case nil: String(localized: "Finishing…")
        }
    }
}

/// The last chance to look before anything moves. Flags protected paths
/// (skipped) and risky ones (your files, backups), and notes rebuildable ones.
/// Uses scan metadata and advisory details warmed while choosing. Fresh
/// protection and identity checks belong to the worker immediately before moving.
struct ReviewSheet: View {
    @Environment(\.palette) private var palette
    @Bindable var model: StorageModel
    @Environment(\.dismiss) private var dismiss
    private var items: [Marked] { model.marked.values.sorted { $0.size > $1.size } }
    private var hints: RemovalHints.Value? { model.currentRemovalHints }
    private var keepsUnreadable: Bool { hints?.keepsUnreadable == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("Move \(items.count) item\(items.count == 1 ? "" : "s") to the Trash?").font(.title2.bold())
            Text(
                "\(Freeing.phrase(model.markedBytes, frees: model.markedFrees)). Everything goes to the Trash, so you can undo right after or put things back from the Trash later."
            )
            .foregroundStyle(.secondary)
            if keepsUnreadable {
                DSNotice(
                    .critical,
                    "Your keep lists couldn't be read, so nothing is moved until they can be. Look at Deep Clean's list in Settings and your rules in Projects."
                )
            }
            List(items, id: \.path) { m in
                HStack(spacing: 8) {
                    Image(systemName: m.isFolder ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        DSName(m.name)
                        DSPath(m.path)
                        warning(m)
                    }
                    Spacer()
                    Text(Freeing.phrase(m.size, frees: hints?.itemFrees[m.path])).monospacedDigit()
                    Button {
                        model.marked[m.path] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from the list")
                    .accessibilityLabel("Unchoose \(m.name)")
                }
            }
            .frame(height: min(360, max(80, CGFloat(items.count) * 64)))
            DSActionGroup {
                EmptyView()
            } trailing: {
                Button("Cancel") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Move to Trash") {
                    dismiss()
                    model.trashMarked()
                }
                .primaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canTrash || keepsUnreadable)
            }
        }
        .padding(Theme.pad)
        .frame(width: DS.Size.reviewWidth)
        .dialogControls()
        .dialogKeyboard()
        .tint(palette.accent.color)  // sheets don't inherit the window's tint
        .onAppear { model.confirmationPresented() }
    }

    @ViewBuilder private func warning(_ m: Marked) -> some View {
        if Trasher.isProtected(m.path) {
            Label("Protected location — will be skipped", systemImage: "hand.raised.fill")
                .font(.caption).foregroundStyle(.red)
        } else if hints?.kept.contains(m.path) == true {
            Label("On one of your keep lists, or holds something that is — will be skipped", systemImage: "lock.shield.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if let open = hints?.openIn[m.path], !open.isEmpty {
            Label("Open in \(open.joined(separator: ", ")) — quit it first, or it goes on writing to the file in the Trash", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if let risk = PathRisk.of(m.path) {
            riskLabel(risk)
        } else if let n = hints?.links[m.path], n > 0 {
            Label("Has \(n) other name\(n == 1 ? "" : "s") (hard link\(n == 1 ? "" : "s")) — its space stays in use until every name goes", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)
        } else if let risk = model.scannedRisk(for: m) {
            riskLabel(risk)
        } else if let r = model.root?.find(path: m.path)?.rebuildable {
            Label("\(r.label) — \(r.reason)", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private func riskLabel(_ risk: PathRisk) -> some View {
        Label(risk.reason, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(risk.level == .caution ? .red : .orange)
    }
}

/// Result of the last move, with Undo while it's still possible.
struct NoticeToast: View {
    let model: StorageModel

    var body: some View {
        if let n = model.notice {
            DSUndoToast(text: n.text, canUndo: n.canUndo && model.canUndo, undo: { model.undoTrash() }, dismiss: { model.dismissNotice() })
        }
    }
}

/// Common folders and the disks mounted now, to map with one choice.
private struct PlacesMenuItems: View {
    let model: StorageModel
    let places: PlacesModel

    private var folders: [(String, String)] {
        let home = Home.path
        return [
            (String(localized: "Home"), home), (String(localized: "Desktop"), home + "/Desktop"),
            (String(localized: "Documents"), home + "/Documents"), (String(localized: "Downloads"), home + "/Downloads"),
            (String(localized: "Applications"), "/Applications"),
        ]
    }

    var body: some View {
        Group {
            Section("Folders") {
                ForEach(folders, id: \.1) { name, path in
                    Button(name) { model.map(place: path) }
                }
            }
            Section("Disks") {
                if places.volumes.isEmpty, places.job != nil { Text("Reading disks…") }
                ForEach(places.volumes) { v in
                    Button(v.available.map { String(localized: "\(v.name) · \(ByteSize.format($0)) free") } ?? v.name) {
                        model.map(place: v.path)
                    }
                }
            }
        }
    }
}
